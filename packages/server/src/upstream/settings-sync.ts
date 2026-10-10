// 从 QQ 同步会话设置（一次请求拿全，不逐个查）：
// - 置顶：群用 isTop / toppedTimestamp，好友用最近会话的 topFlag / topFlagTime；
// - 通知：群的 cmdUinMsgMask（1 接收并提醒 → all；2 收进群助手 → archived；3 屏蔽、4 接收不提醒 → muted），
//   好友的免打扰（isMsgDisturb → muted，否则 default）；
// - 已读：未读数与 QQ 最近会话里的未读数对齐（在手机 QQ 等其他设备上看过的不再算未读）。
// 用户在本 App 里改过的置顶 / 通知设置不覆盖（见 DialogPrefs.applyFromQq）。只处理服务端已有的会话。
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import { maybeOne, rows, type Db } from '../db/client.ts';
import type { DialogPrefs, NotifyPolicy } from '../dialogs/prefs.ts';
import type { IngestService } from '../ingest/service.ts';
import { SourceUnavailableError } from '../media/source.ts';
import type { UpstreamHub } from './hub.ts';
import { NtChatType } from './napcat/types.ts';

interface QqChatSettings {
  groups: { groupCode: string; msgMask: number; isTop: boolean; toppedAtMs: string }[];
  recent: { chatType: number; peerUin: string; topFlag: number; topFlagTime: string; isMsgDisturb: boolean; unreadCnt: string; msgSeq: string }[];
}

export const GROUP_MASK_POLICY: Record<number, NotifyPolicy> = { 1: 'all', 2: 'archived', 3: 'muted', 4: 'muted' };

export interface SettingsSyncReport {
  chats: number;
  changed: number;
  markedRead: number;
}

export class QqSettingsSync {
  private running = new Map<number, Promise<SettingsSyncReport>>();
  private timer: NodeJS.Timeout | null = null;

  constructor(
    private readonly db: Db,
    private readonly hub: Pick<UpstreamHub, 'call' | 'isConnected'>,
    private readonly prefs: Pick<DialogPrefs, 'applyFromQq'>,
    private readonly ingest: Pick<IngestService, 'markRead'>,
    private readonly logger?: Logger,
  ) {}

  /** 每 5 分钟同步一次（上游连上后另外立即触发一次，见 app.ts）。 */
  start(accounts: () => Promise<number[]>, intervalMs = 5 * 60_000): void {
    this.timer = setInterval(() => {
      void accounts().then((ids) => ids.forEach((id) => void this.schedule(id)));
    }, intervalMs);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
  }

  schedule(qqAccountId: number): Promise<SettingsSyncReport> {
    const running = this.running.get(qqAccountId);
    if (running) return running;
    const task = this.run(qqAccountId)
      .then((report) => {
        if (report.changed || report.markedRead) this.logger?.info({ qqAccountId, ...report }, 'QQ chat settings synced');
        return report;
      })
      .catch((error: unknown) => {
        if (!(error instanceof SourceUnavailableError)) this.logger?.warn({ err: error, qqAccountId }, 'QQ chat settings sync failed');
        return { chats: 0, changed: 0, markedRead: 0 };
      })
      .finally(() => this.running.delete(qqAccountId));
    this.running.set(qqAccountId, task);
    return task;
  }

  async run(qqAccountId: number): Promise<SettingsSyncReport> {
    if (!this.hub.isConnected(qqAccountId)) return { chats: 0, changed: 0, markedRead: 0 };
    const settings = await this.hub.call<QqChatSettings>(qqAccountId, 'x.chat_settings', {}, 30_000);
    const chats = await rows<{ id: number; account_id: number; scene: string; peer_id: number; unread_count: number; top_seq: number | null; read_inbox_max_seq: number }>(
      this.db,
      sql`select c.id, q.account_id, c.scene, c.peer_id, c.unread_count, c.top_seq, c.read_inbox_max_seq
            from chats c join qq_accounts q on q.id = c.qq_account_id where c.qq_account_id = ${qqAccountId}`,
    );
    const byKey = new Map(chats.map((c) => [`${c.scene}:${Number(c.peer_id)}`, c]));
    const report: SettingsSyncReport = { chats: 0, changed: 0, markedRead: 0 };
    const seen = new Set<number>();

    for (const g of settings.groups ?? []) {
      const chat = byKey.get(`group:${Number(g.groupCode)}`);
      if (!chat) continue;
      seen.add(chat.id);
      report.chats += 1;
      const toppedMs = Number(g.toppedAtMs);
      const changed = await this.prefs.applyFromQq(chat.account_id, chat.id, {
        pinned: g.isTop,
        pinnedAt: g.isTop && toppedMs > 0 ? new Date(toppedMs) : null,
        ...(GROUP_MASK_POLICY[g.msgMask] ? { notifyPolicy: GROUP_MASK_POLICY[g.msgMask] } : {}),
      });
      if (changed) report.changed += 1;
    }

    for (const c of settings.recent ?? []) {
      const scene = c.chatType === NtChatType.group ? 'group' : c.chatType === NtChatType.friend ? 'friend' : null;
      if (!scene) continue;
      const chat = byKey.get(`${scene}:${Number(c.peerUin)}`);
      if (!chat) continue;
      if (scene === 'friend' && !seen.has(chat.id)) {
        report.chats += 1;
        const topSec = Number(c.topFlagTime);
        const changed = await this.prefs.applyFromQq(chat.account_id, chat.id, {
          pinned: c.topFlag === 1,
          pinnedAt: c.topFlag === 1 && topSec > 0 ? new Date(topSec * 1000) : null,
          notifyPolicy: c.isMsgDisturb ? 'muted' : 'default',
        });
        if (changed) report.changed += 1;
      }
      // 未读数与 QQ 对齐（在手机 QQ 等其他设备上看过的、补历史时进来的旧消息都不该算未读）：
      // QQ 说还有 N 条未读，就把已读位置挪到"别人发的倒数第 N+1 条"（只往前挪，不会把已读变回未读）。
      const qqUnread = Number(c.unreadCnt);
      if (Number.isFinite(qqUnread) && chat.unread_count > qqUnread) {
        const target = await maybeOne<{ seq: number }>(
          this.db,
          sql`select m.seq from messages m join chats c on c.id = m.chat_id join qq_accounts q on q.id = c.qq_account_id
               where m.chat_id = ${chat.id} and m.sender_uin <> q.uin and m.state = 'normal'
               order by m.seq desc offset ${qqUnread} limit 1`,
        );
        const upTo = target ? Number(target.seq) : (chat.top_seq ?? 0);
        if (upTo > chat.read_inbox_max_seq && (await this.ingest.markRead(chat.account_id, chat.id, upTo))) report.markedRead += 1;
      }
    }
    return report;
  }
}
