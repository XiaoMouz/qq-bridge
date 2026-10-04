// 服务端命令行：
//   pnpm cli migrate                       执行数据库迁移
//   pnpm cli create-owner <用户名>          创建所有者账号（密码从环境变量 OWNER_PASSWORD 读取，避免留在 shell 历史里）
//   pnpm cli serve                         启动 API 服务
//   pnpm cli media:reprocess               补处理已存档的媒体（纠正类型、补缩略图 / 语音可播放版本 / 视频封面）
//   pnpm cli inbox:reprocess <ignored|failed>  重新处理收件箱里被忽略 / 失败的上游事件（映射新增支持后用）
import { createDeps, startServer } from './app.ts';
import { AuthService } from './auth/service.ts';
import { loadConfig } from './config.ts';
import { sql } from 'drizzle-orm';
import { createDb, rows, runMigrations } from './db/client.ts';
import { reprocessMedia } from './media/reprocess.ts';
import { InboxProcessor } from './upstream/inbox.ts';

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
    default:
      throw new Error('usage: cli <migrate|create-owner|serve|media:reprocess|inbox:reprocess>');
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
