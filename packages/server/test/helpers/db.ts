import { PostgreSqlContainer, type StartedPostgreSqlContainer } from '@testcontainers/postgresql';
import { createDb, runMigrations, type Db } from '../../src/db/client.ts';

export const PGROONGA_IMAGE = 'groonga/pgroonga:4.0.9-debian-17';

export interface TestDb {
  db: Db;
  container: StartedPostgreSqlContainer;
  stop(): Promise<void>;
}

/** 每个测试文件起一个带 PGroonga 的 PostgreSQL 容器并执行全部迁移。 */
export async function startTestDb(): Promise<TestDb> {
  const container = await new PostgreSqlContainer(PGROONGA_IMAGE)
    .withDatabase('qqbridge')
    .withUsername('qqbridge')
    .withPassword('qqbridge')
    .start();
  const db = createDb(container.getConnectionUri(), 8);
  await runMigrations(db);
  return {
    db,
    container,
    async stop() {
      await db.$client.end();
      await container.stop();
    },
  };
}
