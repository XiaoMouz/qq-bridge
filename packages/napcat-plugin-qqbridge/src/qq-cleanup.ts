// 定时清理 QQ 本地的旧缓存（媒体缓存、日志、NapCat 临时文件），按文件修改时间删 N 天前的。
//
// 2026-11-12 实测的依据：
// - 服务端下载媒体全走 QQ 的下载链接（x.media_url 换 rkey 链接），不读 QQ 本地文件；
// - 视频封面（x.media_url thumb）本地文件删掉后 QQ 会重新下载，内容一致；
// - 语音转文字（x.ptt_text）本地 .amr 删掉后照常出结果。
// 不碰 nt_db（消息库）：QQ 运行中一直打开着它（SQLCipher），补历史、合并转发、回应、视频换链接都按
// msgId 从里面取原消息；也不碰头像、表情资源、登录态和配置。
import fs from 'node:fs/promises';
import path from 'node:path';

export interface CleanupResult {
  dryRun: boolean;
  cutoff: string;
  files: number;
  bytes: number;
  /** 每个目录删了（或 dryRun 时会删）多少。 */
  byDir: Record<string, { files: number; bytes: number }>;
  errors: number;
}

/** 账号目录 nt_qq_<32 位十六进制> 下可清的子目录；nt_qq（无后缀）是全局目录，单独列。 */
const ACCOUNT_SUBDIRS = ['nt_data/Pic', 'nt_data/Video', 'nt_data/Ptt', 'nt_data/File', 'nt_data/log'];
const GLOBAL_SUBDIRS = ['nt_qq/global/nt_data/Log/log', 'NapCat/temp'];

/** qqRoot 是容器里的 /app/.config/QQ。只返回存在的目录。 */
export async function cleanupDirs(qqRoot: string): Promise<string[]> {
  const dirs: string[] = [];
  const entries = await fs.readdir(qqRoot, { withFileTypes: true }).catch(() => []);
  for (const e of entries) {
    if (e.isDirectory() && /^nt_qq_[0-9a-f]{32}$/.test(e.name)) {
      for (const sub of ACCOUNT_SUBDIRS) dirs.push(path.join(qqRoot, e.name, sub));
    }
  }
  for (const sub of GLOBAL_SUBDIRS) dirs.push(path.join(qqRoot, sub));
  const out: string[] = [];
  for (const d of dirs) {
    const st = await fs.lstat(d).catch(() => null);
    if (st?.isDirectory()) out.push(d);
  }
  return out;
}

/** 删 dirs 下（递归）修改时间早于 cutoff 的普通文件；不跟符号链接，不删目录。 */
export async function sweep(dirs: string[], cutoff: Date, dryRun: boolean): Promise<CleanupResult> {
  const result: CleanupResult = { dryRun, cutoff: cutoff.toISOString(), files: 0, bytes: 0, byDir: {}, errors: 0 };
  const limit = cutoff.getTime();
  for (const root of dirs) {
    const stat = { files: 0, bytes: 0 };
    const walk = async (dir: string): Promise<void> => {
      const entries = await fs.readdir(dir, { withFileTypes: true }).catch(() => {
        result.errors++;
        return [];
      });
      for (const e of entries) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) {
          await walk(p);
          continue;
        }
        if (!e.isFile()) continue;
        const st = await fs.lstat(p).catch(() => null);
        if (!st || !st.isFile() || st.mtimeMs >= limit) continue;
        if (!dryRun) {
          try {
            await fs.unlink(p);
          } catch {
            result.errors++;
            continue;
          }
        }
        stat.files++;
        stat.bytes += st.size;
      }
    };
    await walk(root);
    result.byDir[root] = stat;
    result.files += stat.files;
    result.bytes += stat.bytes;
  }
  return result;
}

export async function runCleanup(qqRoot: string, days: number, dryRun: boolean, now = Date.now()): Promise<CleanupResult> {
  const cutoff = new Date(now - days * 86_400_000);
  return sweep(await cleanupDirs(qqRoot), cutoff, dryRun);
}

interface Logger {
  info(...args: unknown[]): void;
  warn(...args: unknown[]): void;
}

interface SchedulerState {
  timer: ReturnType<typeof setTimeout> | null;
  lastRunAt: number;
  running: boolean;
}

// 插件热重载时 QQ 进程不重启：定时器和上次运行时间挂在进程级，新实例接手时先清掉旧定时器，
// 并按上次运行时间续排，避免反复重载把清理一直往后推或叠出多个定时器。
const STATE_KEY = Symbol.for('qqbridge.qqCleanup');
function state(): SchedulerState {
  const g = globalThis as Record<symbol, SchedulerState | undefined>;
  return (g[STATE_KEY] ??= { timer: null, lastRunAt: 0, running: false });
}

const INTERVAL_MS = 6 * 3_600_000;
const FIRST_DELAY_MS = 10 * 60_000;
const MIN_DELAY_MS = 60_000;

/** days <= 0 时只清掉旧定时器、不再排。 */
export function scheduleCleanup(qqRoot: string, days: number, logger: Logger): void {
  const s = state();
  if (s.timer) clearTimeout(s.timer);
  s.timer = null;
  if (days <= 0) return;
  const tick = async (): Promise<void> => {
    s.timer = null;
    if (!s.running) {
      s.running = true;
      try {
        const r = await runCleanup(qqRoot, days, false);
        if (r.files > 0 || r.errors > 0) {
          logger.info(`[qqbridge] qq cleanup: removed ${r.files} files, ${(r.bytes / 1048576).toFixed(1)} MB older than ${days}d (errors ${r.errors})`);
        }
      } catch (error) {
        logger.warn('[qqbridge] qq cleanup failed:', error);
      } finally {
        s.running = false;
        s.lastRunAt = Date.now();
      }
    }
    s.timer = setTimeout(tick, INTERVAL_MS);
    s.timer.unref?.();
  };
  const delay = s.lastRunAt ? Math.max(s.lastRunAt + INTERVAL_MS - Date.now(), MIN_DELAY_MS) : FIRST_DELAY_MS;
  s.timer = setTimeout(tick, delay);
  s.timer.unref?.();
}

export function stopCleanup(): void {
  const s = state();
  if (s.timer) clearTimeout(s.timer);
  s.timer = null;
}
