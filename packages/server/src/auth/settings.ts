// 账号级设置：存在 accounts 表，改动时分配全局 pts 并发一条 settings 更新，
// 已连着 Subscribe 的设备马上收到，离线的设备下次补差量时从 Difference.settings 拿到。
// - phone_notifications_off：手动的「通知手机」开关（客户端写）。
// - phone_auto_off：「本机在线时自动停用」算出来的状态（只由 push/phone-auto-mute.ts 写）。
import { sql } from 'drizzle-orm';
import { maybeOne, one } from '../db/client.ts';
import type { AccountSettingsRow } from '../sync/rows.ts';
import type { WriterRegistry } from '../sync/writer.ts';

interface SettingsDbRow {
  phone_notifications_off: boolean;
  phone_auto_off: boolean;
}

function toRow(r: SettingsDbRow): AccountSettingsRow {
  return { phoneNotificationsOff: r.phone_notifications_off, phoneAutoOff: r.phone_auto_off };
}

/** 改手动开关；返回改前、改后的设置（调用方据此判断是不是刚关掉）。 */
export async function setAccountSettings(
  writers: WriterRegistry,
  accountId: number,
  settings: Pick<AccountSettingsRow, 'phoneNotificationsOff'>,
): Promise<{ pts: number; settings: AccountSettingsRow; previous: AccountSettingsRow }> {
  return writers.forAccount(accountId).run(async (w) => {
    const before = await one<SettingsDbRow>(w.tx, sql`select phone_notifications_off, phone_auto_off from accounts where id = ${accountId}`);
    const pts = await w.allocPts();
    const row = await one<SettingsDbRow>(
      w.tx,
      sql`update accounts set phone_notifications_off = ${settings.phoneNotificationsOff}, settings_pts = ${pts}
           where id = ${accountId} returning phone_notifications_off, phone_auto_off`,
    );
    const saved = toRow(row);
    w.emit({ type: 'settings', pts, settings: saved });
    return { pts, settings: saved, previous: toRow(before) };
  });
}

/** 写自动停用状态；没变化时不分配 pts、不广播，返回 null。 */
export async function setPhoneAutoOff(writers: WriterRegistry, accountId: number, on: boolean): Promise<AccountSettingsRow | null> {
  return writers.forAccount(accountId).run(async (w) => {
    const current = await maybeOne<SettingsDbRow>(w.tx, sql`select phone_notifications_off, phone_auto_off from accounts where id = ${accountId}`);
    if (!current || current.phone_auto_off === on) return null;
    const pts = await w.allocPts();
    const row = await one<SettingsDbRow>(
      w.tx,
      sql`update accounts set phone_auto_off = ${on}, settings_pts = ${pts}
           where id = ${accountId} returning phone_notifications_off, phone_auto_off`,
    );
    const saved = toRow(row);
    w.emit({ type: 'settings', pts, settings: saved });
    return saved;
  });
}
