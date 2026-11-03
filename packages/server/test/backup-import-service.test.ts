import { execFile } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { sql } from 'drizzle-orm';
import pino from 'pino';
import { expect, it, vi } from 'vitest';
import { BackupImportService } from '../src/imports/service.ts';
import { importPython, prepareNative } from '../src/imports/process.ts';
import { UpdateBus } from '../src/sync/bus.ts';
import { WriterRegistry } from '../src/sync/writer.ts';
import { startTestDb } from './helpers/db.ts';

const exec = promisify(execFile);
const settle = (service: BackupImportService) => (service as unknown as { work: Promise<void> }).work;
const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

it('没有任务时不轮询，任务跑完后停下；进度不走账号单写者', async () => {
  const test = await startTestDb();
  const temp = await fs.mkdtemp(path.join(os.tmpdir(), 'qq-import-service-'));
  const backup = path.join(temp, 'backup');
  let service: BackupImportService | undefined;
  try {
    await fs.mkdir(backup);
    const native = await prepareNative(temp);
    await exec(importPython(), [fileURLToPath(new URL('./helpers/backup-fixture.py', import.meta.url)), backup], {
      env: { ...process.env, QQ_IMPORT_NATIVE: native, PYTHONDONTWRITEBYTECODE: '1', PYTHONPATH: fileURLToPath(new URL('../src/imports/reader/', import.meta.url)) },
    });
    const db = test.db;
    await db.execute(sql`insert into accounts(id,username,password_hash) values(1,'fixture','unused');
      insert into sync_state(account_id) values(1);
      insert into qq_accounts(id,account_id,uin,uid) values(1,1,7,'u_self')`);
    const writers = new WriterRegistry(db, new UpdateBus());
    const forAccount = vi.spyOn(writers, 'forAccount');
    const connect = vi.spyOn(db.$client, 'connect');
    service = new BackupImportService(db, writers, { root: path.join(temp, 'state'), allowedRoots: [temp], python: importPython() }, pino({ level: 'silent' }));

    // 原实现每 3 秒取一次连接查任务表；空闲时启动那轮之后不应再取连接。
    service.start();
    await settle(service);
    const idle = connect.mock.calls.length;
    expect(idle).toBeGreaterThan(0);
    await sleep(3500);
    expect(connect).toHaveBeenCalledTimes(idle);

    const job = await service.create(1, { qqAccountId: 1, backupPath: backup, keysPath: path.join(backup, 'keys.json'), batchSize: 10 }) as { id: string };
    expect(forAccount).toHaveBeenCalledTimes(1);
    let state = '';
    for (let i = 0; i < 600 && state !== 'completed' && state !== 'failed'; i++) {
      await sleep(100);
      state = ((await service.status(1, job.id)) as { state: string }).state;
    }
    expect(state).toBe('completed');
    // 每批进度直接写任务表；账号单写者只用于用户操作。
    expect(forAccount).toHaveBeenCalledTimes(1);

    // 跑完 3 秒后复查一次确认没有剩余任务，之后不再取连接。
    await sleep(4000);
    await settle(service);
    const leases = connect.mock.calls.length;
    await sleep(3500);
    expect(connect).toHaveBeenCalledTimes(leases);
  } finally {
    await service?.stop();
    await fs.rm(temp, { recursive: true, force: true });
    await test.stop();
  }
}, 120_000);
