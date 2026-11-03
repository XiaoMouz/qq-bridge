import { randomUUID } from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { sql } from 'drizzle-orm';
import type { Logger } from 'pino';
import { maybeOne, rows, type Db } from '../db/client.ts';
import type { WriterRegistry } from '../sync/writer.ts';
import { BackupMatcher, MATCHER_VERSION } from './matcher.ts';
import { prepareNative, readReport, ReaderProcess } from './process.ts';

export class ImportError extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}
interface Job {
  id: string; account_id: number; qq_account_id: number; source_path: string; keys_path: string;
  batch_size: number; state: string; desired_state: string; summary: Record<string, any>; error: string | null;
}
export interface ImportOptions { root: string; allowedRoots: string[]; python: string }
const views = new Set(['state', 'details', 'statistics', 'chats', 'media', 'media_summary', 'media_occurrences', 'media_links', 'bindings', 'native_resources']);

export class BackupImportService {
  private stopping = false;
  private running = false;
  private busy = false;
  private again = false;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private active: { id: string; reader: ReaderProcess | null; paused: boolean } | null = null;
  private work: Promise<void> = Promise.resolve();
  private readonly matcher: BackupMatcher;
  private readonly reports = new Map<string, Promise<unknown>>();
  constructor(private readonly db: Db, private readonly writers: WriterRegistry,
    private readonly opts: ImportOptions, private readonly logger: Logger) {
    this.matcher = new BackupMatcher(db);
  }

  start(): void {
    if (this.running) return;
    this.running = true; this.stopping = false;
    this.wake();
  }
  private wake(): void {
    if (!this.running || this.stopping) return;
    // 执行中的新任务由本轮结束后的复查接上；不能丢掉这次唤醒，否则空轮次之后不会再看。
    if (this.active || this.busy) { this.again = true; return; }
    clearTimeout(this.timer);
    this.busy = true;
    this.again = false;
    // 只在还有任务或拿不到锁时再看；没有任务就等 create / resume 唤醒，不常驻轮询数据库。
    let retry: number | null = null;
    this.work = this.tick().then(delay => { retry = delay; }, error => {
      this.logger.error({ err: error }, 'backup import worker failed');
      retry = 30_000;
    }).finally(() => {
      this.busy = false;
      if (this.again) retry = 0;
      if (!this.stopping && retry !== null) { this.timer = setTimeout(() => this.wake(), retry); this.timer.unref(); }
    });
  }
  async stop(): Promise<void> {
    this.stopping = true; clearTimeout(this.timer);
    if (this.active) {
      this.active.paused = true;
      await this.active.reader?.stop();
    }
    await this.work;
    this.running = false;
  }

  private async localPath(input: string): Promise<string> {
    if (!this.opts.allowedRoots.length) throw new ImportError(503, '未配置 BACKUP_IMPORT_ALLOWED_ROOTS');
    const actual = await fs.realpath(input).catch(() => { throw new ImportError(400, '本地路径不存在'); });
    let allowed = false;
    for (const root of this.opts.allowedRoots) {
      // 允许目录是部署配置；它不存在是配置错误，不能变成接口 500。
      const realRoot = await fs.realpath(root).catch(() => { throw new ImportError(503, 'BACKUP_IMPORT_ALLOWED_ROOTS 中的目录不存在'); });
      const relative = path.relative(realRoot, actual);
      if (relative === '' || (!relative.startsWith('..' + path.sep) && relative !== '..' && !path.isAbsolute(relative))) allowed = true;
    }
    if (!allowed) throw new ImportError(403, '路径不在允许的本地导入目录内');
    return actual;
  }
  private statePath(id: string): string { return path.join(this.opts.root, id, 'scan.sqlite'); }

  async create(accountId: number, input: { qqAccountId: number; backupPath: string; keysPath: string; batchSize?: number }): Promise<unknown> {
    const qq = await maybeOne<{ id: number }>(this.db, sql`select id from qq_accounts where id=${input.qqAccountId} and account_id=${accountId}`);
    if (!qq) throw new ImportError(404, 'QQ 账号不存在');
    const [backupPath, keysPath] = await Promise.all([this.localPath(input.backupPath), this.localPath(input.keysPath)]);
    const [source, key] = await Promise.all([fs.stat(backupPath), fs.stat(keysPath)]);
    if (!source.isDirectory() || !key.isFile() || key.size > 1024 * 1024) throw new ImportError(400, '需要本地备份目录与密钥清单文件');
    const batchSize = input.batchSize ?? 200;
    if (!Number.isInteger(batchSize) || batchSize < 1 || batchSize > 500) throw new ImportError(400, 'batchSize 应在 1–500 之间');
    const id = randomUUID();
    await fs.mkdir(path.dirname(this.statePath(id)), { recursive: true, mode: 0o700 });
    await this.writers.forAccount(accountId).run(async w => {
      await w.tx.execute(sql`insert into backup_import_jobs(id,account_id,qq_account_id,source_path,keys_path,batch_size)
        values(${id},${accountId},${qq.id},${backupPath},${keysPath},${batchSize})`);
    });
    this.wake();
    return this.status(accountId, id);
  }

  private async job(accountId: number, id: string): Promise<Job> {
    const result = await maybeOne<Job>(this.db, sql`select * from backup_import_jobs where id=${id}::uuid and account_id=${accountId}`);
    if (!result) throw new ImportError(404, '任务不存在');
    return result;
  }
  private publicJob(job: Job): unknown {
    const { keys_path: _keys, account_id: _account, source_path: source, ...value } = job;
    const counts = job.summary.messageKinds ?? {};
    const total = (job.summary.processed ?? 0) - (job.summary.parseErrors ?? 0);
    return { ...value, source, mode: 'dry-run', scanComplete: job.state === 'completed', statisticsComplete: job.state === 'completed' && (job.summary.parseErrors ?? 0) === 0,
      proportions: Object.fromEntries(Object.entries(counts).map(([k, n]) => [k, total ? Number(n) / total : 0])),
      accountVerification: { evidenceCount: job.summary.accountEvidence ?? 0, conflictCount: job.summary.accountEvidenceConflicts ?? 0, verified: (job.summary.accountEvidence ?? 0) > 0 && (job.summary.accountEvidenceConflicts ?? 0) === 0, basis: '备份内本机成功发送记录的发送者号码与所选 QQ 账号一致' },
      proportionDenominator: '已解析的顶层消息（同消息可含多种交互，占比不可相加）',
      targetConsistency: '按批读取现有库；在线消息可继续变化，正式合入前须重新核验目标版本' };
  }
  async list(accountId: number): Promise<unknown> {
    const jobs = await rows<Job>(this.db, sql`select * from backup_import_jobs where account_id=${accountId} order by created_at desc limit 100`);
    return jobs.map(j => this.publicJob(j));
  }
  async status(accountId: number, id: string): Promise<unknown> { return this.publicJob(await this.job(accountId, id)); }

  async pause(accountId: number, id: string): Promise<unknown> {
    const current = await this.job(accountId, id);
    if (['completed','failed'].includes(current.state)) throw new ImportError(409, '任务已经结束');
    await this.writers.forAccount(accountId).run(async w => {
      await w.tx.execute(sql`update backup_import_jobs set desired_state='paused',
        state=case when state='running' then 'pausing' when state='queued' then 'paused' else state end,
        updated_at=now() where id=${id}::uuid and account_id=${accountId}`);
    });
    if (this.active?.id === id) {
      this.active.paused = true;
      void this.active.reader?.stop();
    }
    return this.status(accountId, id);
  }
  async resume(accountId: number, id: string): Promise<unknown> {
    const job = await this.job(accountId, id);
    if (!['paused', 'failed'].includes(job.state)) throw new ImportError(409, '任务尚未暂停或无需继续');
    await this.writers.forAccount(accountId).run(async w => {
      await w.tx.execute(sql`update backup_import_jobs set desired_state='running',state='queued',error=null,updated_at=now() where id=${id}::uuid`);
    });
    this.wake();
    return this.status(accountId, id);
  }
  async report(accountId: number, id: string, view: string, cursor = 0, limit = 100, kind = '', status = ''): Promise<unknown> {
    await this.job(accountId, id);
    if (!views.has(view)) throw new ImportError(400, '未知明细类型');
    if (!Number.isSafeInteger(cursor) || cursor < 0 || !Number.isInteger(limit) || limit < 1 || limit > 500) throw new ImportError(400, '分页参数无效');
    try { await fs.access(this.statePath(id)); } catch { return { items: [], ready: false }; }
    if (this.reports.size >= 2) throw new ImportError(429, '明细查询繁忙，请稍后重试');
    const key = randomUUID();
    const pending = readReport(this.opts.python, this.statePath(id), view, cursor, limit, kind, status);
    this.reports.set(key, pending);
    try { const items = await pending; return { items, nextCursor: Array.isArray(items) && items.length ? items.at(-1)?.id ?? null : null, ready: true }; }
    finally { this.reports.delete(key); }
  }

  private async update(job: Job, state: string, summary: unknown, error: string | null = null): Promise<void> {
    // 任务表不参与同步、不发推送，不走账号单写者：每批进度不能排进实时消息入库的队列。
    await this.db.execute(sql`update backup_import_jobs set state=${state},summary=${JSON.stringify(summary)}::jsonb,error=${error},updated_at=now() where id=${job.id}::uuid`);
  }
  /** 返回下次检查的延迟；null 表示没有待跑任务。 */
  private async tick(): Promise<number | null> {
    // 单会话 advisory lock 随连接释放，崩溃后可接管；不能靠进程内布尔变量防双 worker。
    const lease = await this.db.$client.connect();
    let locked = false;
    const lostLease = () => {
      if (this.active) { this.active.paused = true; void this.active.reader?.stop(); }
    };
    lease.on('error', lostLease);
    try {
      const result = await lease.query<{ locked: boolean }>('select pg_try_advisory_lock(718220261103::bigint) as locked');
      locked = result.rows[0]?.locked ?? false;
      if (this.stopping) return null;
      if (!locked) return 30_000;
      const job = await maybeOne<Job>(this.db, sql`select * from backup_import_jobs
        where state in ('queued','running','pausing') order by created_at limit 1`);
      if (!job) return null;
      if (job.desired_state === 'paused') await this.update(job, 'paused', job.summary);
      else await this.execute(job);
      return 3000;
    } finally {
      if (locked) await lease.query('select pg_advisory_unlock(718220261103::bigint)').catch(() => undefined);
      lease.off('error', lostLease);
      lease.release();
    }
  }
  private async execute(job: Job): Promise<void> {
    this.active = { id: job.id, reader: null, paused: false };
    let summary = job.summary;
    try {
      const native = await prepareNative(this.opts.root);
      if (this.stopping || this.active.paused) return;
      const qq = await maybeOne<{ uin: number }>(this.db, sql`select uin from qq_accounts where id=${job.qq_account_id}`);
      if (!qq) throw new Error('QQ 账号不存在');
      // 重启继续时再次检查 realpath 白名单，防路径被替换成越界符号链接。
      await this.localPath(job.source_path); await this.localPath(job.keys_path);
      const reader = new ReaderProcess(this.opts.python, native);
      this.active.reader = reader;
      summary = (await reader.request({ command: 'open', config: {
        backupPath: job.source_path, keysPath: job.keys_path, accountUin: String(qq.uin),
        physicalCatalogRoot: path.join(this.opts.root,'physical-catalogs'),
        statePath: this.statePath(job.id), batchSize: job.batch_size, matchingVersion: MATCHER_VERSION,
      } })).state;
      await this.update(job, 'running', summary);
      // 进度权威在 scan.sqlite；Postgres 只是展示副本，运行中最多 5 秒写一次，阶段变化、结束和暂停时立即写。
      let written = { at: Date.now(), phase: summary.phase };
      while (!this.stopping && !this.active.paused) {
        const control = await this.job(job.account_id, job.id);
        if (control.desired_state === 'paused') { this.active.paused = true; break; }
        const batch = await reader.request({ command: 'next' });
        const matches = await this.matcher.matchBatch(job.qq_account_id, batch.records);
        const objects = await this.matcher.matchObjects(batch.objects);
        summary = (await reader.request({ command: 'commit', matches, objects })).state;
        if (summary.phase === 'done') { await this.update(job, 'completed', summary); return; }
        if (summary.phase !== written.phase || Date.now() - written.at >= 5000) {
          await this.update(job, 'running', summary);
          written = { at: Date.now(), phase: summary.phase };
        }
        // 每批主动让出事件循环与数据库 writer；解密和 hash 始终在子进程。
        await new Promise<void>(resolve => setTimeout(resolve, 10));
      }
      await this.update(job, this.stopping ? 'queued' : 'paused', summary);
    } catch (error) {
      const paused = this.stopping || this.active?.paused;
      await this.update(job, this.stopping ? 'queued' : paused ? 'paused' : 'failed', summary, paused ? null : (error instanceof Error ? error.message.slice(0, 300) : '备份任务失败'));
      if (!paused) this.logger.warn({ jobId: job.id, err: error }, 'backup dry-run failed');
    } finally {
      await this.active?.reader?.stop();
      this.active = null;
    }
  }
}
