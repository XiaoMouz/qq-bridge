// 群公告、群精华、群文件：字段映射、精华关联存档消息、群文件下载一次后记住。
import fs from 'node:fs/promises';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { decodeEntities, GroupContentService } from '../src/contacts/group-content.ts';
import { MediaService } from '../src/media/service.ts';
import { LocalFsBackend } from '../src/media/store.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, services, textMessage, type TestAccount } from './helpers/fixtures.ts';

let t: TestDb;
let root: string;
let server: http.Server;
let base: string;
let downloads = 0;

beforeAll(async () => {
  t = await startTestDb();
  root = await fs.mkdtemp(path.join(os.tmpdir(), 'qqbridge-gc-'));
  server = http.createServer((_req, res) => {
    downloads += 1;
    res.end('PDF bytes');
  });
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});
afterAll(async () => {
  server?.close();
  await t?.stop();
  await fs.rm(root, { recursive: true, force: true });
});

function hub(responses: Record<string, unknown>) {
  return {
    isConnected: () => true,
    call: async <T,>(_qq: number, _action: string, p: { name: string }): Promise<T> => responses[p.name] as T,
  };
}

describe('group content', () => {
  let acc: TestAccount;
  it('maps notices and essence, linking essence to archived messages', async () => {
    const { ingest } = services(t.db);
    acc = await createTestAccount(t.db, ingest);
    await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 950001, 248151, 20002, { text: '孙子说' }));
    const svc = new GroupContentService(
      t.db,
      new MediaService(t.db, new LocalFsBackend(root)),
      () =>
        hub({
          _get_group_notice: [
            { notice_id: 'n1', sender_id: 20002, publish_time: 1700000000, message: { text: '第一行&#10;第二行', images: [{ id: 'IMG' }] }, settings: { confirm_required: 1 }, read_num: 3 },
          ],
          get_essence_msg_list: [
            { msg_seq: 248151, sender_id: 20002, sender_nick: 'A', operator_nick: 'B', operator_time: 1700000100, content: [{ type: 'text', data: { text: '孙子说' } }] },
            { msg_seq: 1, sender_id: 30003, sender_nick: 'C', operator_nick: 'B', operator_time: 1700000200, content: [{ type: 'image', data: { url: 'https://x/y.jpg' } }] },
          ],
        }),
    );
    const [notice] = await svc.notices(acc.accountId, 950001);
    expect(notice).toMatchObject({ id: 'n1', text: '第一行\n第二行', imageUrls: ['https://gdynamic.qpic.cn/gdynamic/IMG/628'], confirmRequired: true, readCount: 3 });
    const essence = await svc.essence(acc.accountId, 950001);
    expect(essence.map((e) => e.seq)).toEqual([1, 248151]);
    expect(essence[0]).toMatchObject({ message: null, imageUrls: ['https://x/y.jpg'] });
    expect(essence[1]!.message?.text).toBe('孙子说');
  });

  it('downloads a group file once, then lists it as stored', async () => {
    const svc = new GroupContentService(
      t.db,
      new MediaService(t.db, new LocalFsBackend(root)),
      () =>
        hub({
          get_group_file_url: { url: `${base}/f?fname=` },
          get_group_root_files: { files: [{ file_id: 'F1', busid: 102, file_name: 'a.pdf', file_size: 9, modify_time: 5, uploader: 20002 }], folders: [{ folder_id: '/d', folder_name: '资料', total_file_count: 2 }] },
        }),
    );
    const first = await svc.fetchFile(acc.accountId, 950001, 'F1', 102, 'a.pdf');
    const again = await svc.fetchFile(acc.accountId, 950001, 'F1', 102, 'a.pdf');
    expect(again.sha256).toBe(first.sha256);
    expect(downloads).toBe(1);
    const list = await svc.files(acc.accountId, 950001, '');
    expect(list.folders).toEqual([{ id: '/d', name: '资料', fileCount: 2, modifyTime: 0, creatorName: '' }]);
    expect(list.files[0]).toMatchObject({ id: 'F1', name: 'a.pdf', size: 9, sha256: first.sha256 });
  });

  it('decodes entities in notice text', () => {
    expect(decodeEntities('a&#10;b &amp; &quot;c&quot;')).toBe('a\nb & "c"');
  });
});
