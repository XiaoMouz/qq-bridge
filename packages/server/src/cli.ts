// 服务端命令行：
//   pnpm cli migrate                       执行数据库迁移
//   pnpm cli create-owner <用户名>          创建所有者账号（密码从环境变量 OWNER_PASSWORD 读取，避免留在 shell 历史里）
//   pnpm cli set-password <用户名>          重设密码（同样从 OWNER_PASSWORD 读取）
//   pnpm cli serve                         启动 API 服务
//   pnpm cli media:reprocess               补处理已存档的媒体（纠正类型、补缩略图 / 语音可播放版本 / 视频封面）
//   pnpm cli media:drop-playable-copies    删掉以前给视频另存的 faststart 副本（现在直接播原件）
//   pnpm cli media:apply-on-demand         按下载规则整理已有的媒体（改为按需 / 排进下载队列，去掉自动清理标记）
//   pnpm cli media:tier                    立即执行一次冷热分层（平时服务端每天自动跑）
//   pnpm cli inbox:reprocess <ignored|failed>  重新处理收件箱里被忽略 / 失败的上游事件（映射新增支持后用）
//   pnpm cli messages:remap-gray-tips      把以前存成未知元素的 QQ 灰色提示（撤回、拍一拍、文件已接收……）改成系统提示
//   pnpm cli import:backup --backup <目录> --keys <密钥清单> --scan <预检 scan.sqlite> --state <导入状态库> --qq <qq_account_id>
//                          [--table msg_1_群号 ...] [--batches N] [--apply]
//                                          把手机备份里生产没有的消息导入（默认只统计不写；--apply 才写库、拷媒体）。
//                                          可中断续跑；明细写在 <导入状态库>.report.jsonl。见 imports/apply.ts。
import { createDeps, startServer } from './app.ts';
import { AuthService } from './auth/service.ts';
import { loadConfig } from './config.ts';
import { sql } from 'drizzle-orm';
import { createDb, rows, runMigrations } from './db/client.ts';
import { dropPlayableCopies, reprocessMedia } from './media/reprocess.ts';
import { remapGrayTips } from './messages/remap-gray-tips.ts';
import { InboxProcessor } from './upstream/inbox.ts';
import { BackupApplier } from './imports/apply.ts';
import { importPython, prepareNative } from './imports/process.ts';
import path from 'node:path';

async function main(argv: string[]): Promise<void> {
  const [command, ...args] = argv;
  switch (command) {
    case 'migrate': {
      const db = createDb(requireEnv('DATABASE_URL'));
      await runMigrations(db);
      await db.$client.end();
      console.log('migrations applied');
      return;
    }
    case 'create-owner': {
      const username = args[0];
      const password = process.env.OWNER_PASSWORD;
      if (!username || !password) throw new Error('usage: OWNER_PASSWORD=... pnpm cli create-owner <username>');
      const db = createDb(requireEnv('DATABASE_URL'));
      await runMigrations(db);
      const id = await new AuthService(db).createAccount(username, password);
      await db.$client.end();
      console.log(`owner account created: id=${id}`);
      return;
    }
    case 'set-password': {
      const username = args[0];
      const password = process.env.OWNER_PASSWORD;
      if (!username || !password) throw new Error('usage: OWNER_PASSWORD=... pnpm cli set-password <username>');
      const db = createDb(requireEnv('DATABASE_URL'));
      const ok = await new AuthService(db).setPassword(username, password);
      await db.$client.end();
      if (!ok) throw new Error(`account ${username} does not exist`);
      console.log(`password of ${username} updated`);
      return;
    }
    case 'serve': {
      const server = await startServer(loadConfig());
      const shutdown = () => {
        void server.close().finally(() => process.exit(0));
      };
      process.once('SIGINT', shutdown);
      process.once('SIGTERM', shutdown);
      return;
    }
    case 'media:reprocess': {
      const config = loadConfig();
      const db = createDb(config.DATABASE_URL);
      await runMigrations(db);
      const deps = createDeps(db, {
        mediaRoot: config.MEDIA_ROOT,
        mediaUrlSecret: config.MEDIA_URL_SECRET,
        logLevel: config.LOG_LEVEL,
        ...(config.FFMPEG_PATH ? { ffmpegPath: config.FFMPEG_PATH } : {}),
      });
      const report = await reprocessMedia(deps);
      await db.$client.end();
      console.log(JSON.stringify(report));
      return;
    }
    case 'media:drop-playable-copies': {
      const config = loadConfig();
      const db = createDb(config.DATABASE_URL);
      await runMigrations(db);
      const deps = createDeps(db, {
        mediaRoot: config.MEDIA_ROOT,
        mediaUrlSecret: config.MEDIA_URL_SECRET,
        logLevel: config.LOG_LEVEL,
        ...(config.MEDIA_COLD_ROOT ? { mediaColdRoot: config.MEDIA_COLD_ROOT } : {}),
      });
      const report = await dropPlayableCopies(deps);
      await db.$client.end();
      console.log(JSON.stringify(report));
      return;
    }
    case 'media:apply-on-demand': {
      const config = loadConfig();
      const db = createDb(config.DATABASE_URL);
      await runMigrations(db);
      const deps = createDeps(db, {
        mediaRoot: config.MEDIA_ROOT,
        mediaUrlSecret: config.MEDIA_URL_SECRET,
        logLevel: config.LOG_LEVEL,
        ...(config.MEDIA_COLD_ROOT ? { mediaColdRoot: config.MEDIA_COLD_ROOT } : {}),
      });
      const applied = await deps.ingest.applyOnDemandToExisting();
      await db.$client.end();
      console.log(JSON.stringify(applied));
      return;
    }
    case 'media:tier': {
      const config = loadConfig();
      const db = createDb(config.DATABASE_URL);
      await runMigrations(db);
      const deps = createDeps(db, {
        mediaRoot: config.MEDIA_ROOT,
        mediaUrlSecret: config.MEDIA_URL_SECRET,
        logLevel: config.LOG_LEVEL,
        ...(config.MEDIA_COLD_ROOT ? { mediaColdRoot: config.MEDIA_COLD_ROOT } : {}),
      });
      const reports = await deps.tiering.runAll();
      await db.$client.end();
      console.log(JSON.stringify(reports));
      return;
    }
    case 'inbox:reprocess': {
      const state = args[0];
      if (state !== 'ignored' && state !== 'failed') throw new Error('usage: pnpm cli inbox:reprocess <ignored|failed>');
      const config = loadConfig();
      const db = createDb(config.DATABASE_URL);
      await runMigrations(db);
      const deps = createDeps(db, { mediaRoot: config.MEDIA_ROOT, mediaUrlSecret: config.MEDIA_URL_SECRET, logLevel: config.LOG_LEVEL });
      const inbox = new InboxProcessor(db, deps.ingest);
      const count = await inbox.reprocess(state);
      await inbox.idle();
      const summary = await rows<{ state: string; n: number }>(db, sql`select state, count(*)::int as n from upstream_events group by state`);
      await db.$client.end();
      console.log(JSON.stringify({ requeued: count, states: Object.fromEntries(summary.map((r) => [r.state, r.n])) }));
      return;
    }
    case 'messages:remap-gray-tips': {
      const config = loadConfig();
      const db = createDb(config.DATABASE_URL);
      await runMigrations(db);
      const deps = createDeps(db, { mediaRoot: config.MEDIA_ROOT, mediaUrlSecret: config.MEDIA_URL_SECRET, logLevel: config.LOG_LEVEL });
      const result = await remapGrayTips(db, deps.ingest);
      await db.$client.end();
      console.log(JSON.stringify(result));
      return;
    }
    case 'import:backup': {
      const flag = (name: string) => { const i = args.indexOf(`--${name}`); return i >= 0 ? args[i + 1] : undefined; };
      const tables = args.flatMap((a, i) => (a === '--table' && args[i + 1] ? [args[i + 1]!] : []));
      const [backup, keys, scan, state, qq] = ['backup', 'keys', 'scan', 'state', 'qq'].map(flag);
      if (!backup || !keys || !scan || !state || !qq) throw new Error('usage: pnpm cli import:backup --backup <dir> --keys <file> --scan <scan.sqlite> --state <state.sqlite> --qq <id> [--table t] [--batches n] [--apply]');
      const apply = args.includes('--apply');
      const config = loadConfig();
      const db = createDb(config.DATABASE_URL);
      await runMigrations(db);
      const deps = createDeps(db, {
        mediaRoot: config.MEDIA_ROOT,
        mediaUrlSecret: config.MEDIA_URL_SECRET,
        logLevel: config.LOG_LEVEL,
        ...(config.MEDIA_COLD_ROOT ? { mediaColdRoot: config.MEDIA_COLD_ROOT } : {}),
        ...(config.FFMPEG_PATH ? { ffmpegPath: config.FFMPEG_PATH } : {}),
      });
      // 试跑用单独的游标库，不推进正式导入的进度。
      const statePath = apply ? state : `${state}.dry-run`;
      const work = path.dirname(path.resolve(state));
      const applier = new BackupApplier(db, deps.ingest, deps.media, deps.processor, importPython(), await prepareNative(work), deps.logger.child({ component: 'backup-import' }));
      let last = 0;
      const summary = await applier.run({
        backupPath: backup, keysPath: keys, scanPath: scan, statePath, reportPath: `${statePath}.report.jsonl`,
        stagingDir: path.join(work, 'staging'), qqAccountId: Number(qq), dryRun: !apply,
        ...(tables.length ? { tables } : {}), ...(flag('batches') ? { maxBatches: Number(flag('batches')) } : {}),
        onProgress: (s, table) => {
          if (Date.now() - last < 30_000) return;
          last = Date.now();
          console.error(JSON.stringify({ table, ...s }));
        },
      });
      await db.$client.end();
      console.log(JSON.stringify({ mode: apply ? 'apply' : 'dry-run', ...summary }));
      return;
    }
    case 'import:backup-media-repair': {
      // 补图：按 reader/media_names.py 生成的对照表，把备份里有、生产记为 expired 的媒体拷入并挂上（见 BackupApplier.repairMedia）。
      const flag = (name: string) => { const i = args.indexOf(`--${name}`); return i >= 0 ? args[i + 1] : undefined; };
      const [backup, keys, scan, state, map] = ['backup', 'keys', 'scan', 'state', 'map'].map(flag);
      if (!backup || !keys || !scan || !state || !map) throw new Error('usage: pnpm cli import:backup-media-repair --backup <dir> --keys <file> --scan <scan.sqlite> --state <state.sqlite> --map <md5-map.jsonl> [--limit n]');
      const config = loadConfig();
      const db = createDb(config.DATABASE_URL);
      const deps = createDeps(db, {
        mediaRoot: config.MEDIA_ROOT,
        mediaUrlSecret: config.MEDIA_URL_SECRET,
        logLevel: config.LOG_LEVEL,
        ...(config.MEDIA_COLD_ROOT ? { mediaColdRoot: config.MEDIA_COLD_ROOT } : {}),
        ...(config.FFMPEG_PATH ? { ffmpegPath: config.FFMPEG_PATH } : {}),
      });
      const work = path.dirname(path.resolve(state));
      const applier = new BackupApplier(db, deps.ingest, deps.media, deps.processor, importPython(), await prepareNative(work), deps.logger.child({ component: 'backup-repair' }));
      let last = 0;
      const summary = await applier.repairMedia({
        backupPath: backup, keysPath: keys, scanPath: scan, statePath: state, stagingDir: path.join(work, 'staging'), mapPath: map,
        ...(flag('limit') ? { limit: Number(flag('limit')) } : {}),
        onProgress: (s, after) => { if (Date.now() - last < 30_000) return; last = Date.now(); console.error(JSON.stringify({ after, ...s })); },
      });
      await db.$client.end();
      console.log(JSON.stringify({ mode: 'repair', ...summary }));
      return;
    }
    default:
      throw new Error('usage: cli <migrate|create-owner|serve|media:reprocess|media:drop-playable-copies|media:apply-on-demand|media:tier|inbox:reprocess|messages:remap-gray-tips|import:backup|import:backup-media-repair>');
  }
}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

main(process.argv.slice(2)).catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
