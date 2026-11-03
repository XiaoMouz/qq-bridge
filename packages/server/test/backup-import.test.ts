import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { expect, it } from 'vitest';
import { sql } from 'drizzle-orm';
import { prepareNative, ReaderProcess, importPython } from '../src/imports/process.ts';
import { BackupMatcher, type BackupRecord } from '../src/imports/matcher.ts';
import { startTestDb } from './helpers/db.ts';

const exec = promisify(execFile);

it('解密加密页并无损解析 @、回复、表情、图片、卡片与嵌套上下文', async () => {
  const temp = await fs.mkdtemp(path.join(os.tmpdir(), 'qq-import-parser-'));
  try {
    const native = await prepareNative(temp);
    const { stdout } = await exec(importPython(), [fileURLToPath(new URL('./helpers/backup-fixture.py', import.meta.url)), temp], {
      env: { ...process.env, QQ_IMPORT_NATIVE: native, PYTHONDONTWRITEBYTECODE: '1', PYTHONPATH: fileURLToPath(new URL('../src/imports/reader/', import.meta.url)) },
    });
    const { record: r, writeBlocked } = JSON.parse(stdout);
    expect(writeBlocked).toBe(true);
    expect(r.localId).toBe('18446744073709551601');
    expect(r.identityDisagreement).toBe(true);
    expect(r.elements.map((e: any) => e.kind)).toEqual(['mention', 'mention_all', 'text', 'reply', 'face', 'super_face', 'image', 'miniapp', 'poke', 'voice', 'video', 'dynamic']);
    expect(r.elements[0].targetUid).toBe('u_target');
    expect(r.elements[3].reference).toMatchObject({ sequence: '8', senderUid: 'u_target', time: '1700000000', protocolMessageId: '18446744073709551600' });
    expect(r.elements[3].snapshot[0].text).toBe('原消息\u2028换行\u2029继续');
    expect(r.elements[6].identifiers).toContainEqual(expect.objectContaining({ algorithm: 'md5', value: createHash('md5').update(Buffer.from('\x89PNG\r\n\x1a\nfixture-original','latin1')).digest('hex'), role: 'main' }));
    expect(JSON.parse(r.elements[7].payload).meta.detail.title).toBe('测试小程序');
    expect(r.nodes[0]).toMatchObject({ time: 1699999999, senderUin: '9', path: [0] });
    expect(r.nodes[0].elements[0].kind).toBe('image');
    expect(r.elements[11].dynamic).toMatchObject({ type: 22, relatedUins: ['9', '10'], descriptions: [{ text: '密友绑定提醒' }, {}] });
    expect(r.elements[8].grayTip).toMatchObject({ subElementType: 12, xmlElement: { content: expect.stringContaining('u_author') } });
    const reader = new ReaderProcess(importPython(), native);
    try {
      await reader.request({ command: 'open', config: { backupPath: temp, keysPath: path.join(temp,'keys.json'),
        statePath: path.join(temp,'scan.sqlite'), physicalCatalogRoot: path.join(temp,'catalogs'), accountUin: '7', batchSize: 1 } });
      for (let i=0;i<30;i++) {
        const batch = await reader.request({ command: 'next' });
        if (batch.records.length) {
          expect(batch.records[0].elements[3].snapshot[0].text).toBe('原消息\u2028换行\u2029继续');
          await reader.request({ command: 'commit', matches: [], objects: [] });
          break;
        }
        await reader.request({ command: 'commit', matches: [], objects: [] });
        if (i===29) throw new Error('未读到夹具消息');
      }
      let done=false;
      for(let i=0;i<50;i++){
        const batch=await reader.request({command:'next'});
        const result=await reader.request({command:'commit',matches:[],objects:batch.objects.map((object:any)=>({object,target:{status:'new_payload'}}))});
        if(result.state.phase==='done'){done=true;break;}
      }
      expect(done).toBe(true);
      const {readReport}=await import('../src/imports/process.ts');
      const links=await readReport(importPython(),path.join(temp,'scan.sqlite'),'media_links',0,100,'') as any[];
      const image=links.find(x=>x.scope==='root'&&x.kind==='image');
      expect(image.resolution.status).toBe('resolved');
      const versions=image.resolution.candidates;
      expect(new Set(versions.filter((x:any)=>x.role==='original').map((x:any)=>x.sha256)).size).toBe(1);
      expect(versions.some((x:any)=>x.role==='preview')).toBe(true);
      const video=links.find(x=>x.scope==='root'&&x.kind==='video');
      expect(video.resolution.status).toBe('resolved');
      expect(video.resolution.candidates.some((x:any)=>x.role==='poster')).toBe(true);
      const file=links.find(x=>x.scope==='root'&&x.kind==='file');
      expect(file.resolution.status).toBe('resolved');
      expect(file.resolution.candidates.some((x:any)=>x.evidence.some((p:any)=>p.method==='native_message_single_typed_element'))).toBe(true);
      expect((await readReport(importPython(),path.join(temp,'scan.sqlite'),'media_links',0,100,'file','resolved') as any[]).length).toBe(1);
      const pointer=links.find(x=>x.resolution.status==='pointer_only');
      expect(pointer.resolution.reason).toBe('external_pointer_without_backed_payload');
      const recalled=links.find(x=>x.scope==='recalled_original');
      expect(recalled.source.historicalOnly).toBe(true);
      expect(recalled.sender_uid).toBe('u_original');
      expect(recalled.resolution.evidence.historicalOnly).toBe(true);
      expect((await readReport(importPython(),path.join(temp,'scan.sqlite'),'native_resources',0,100,'','recalled_message') as any[]).length).toBe(1);
      const repeat=new ReaderProcess(importPython(),native);
      try {
        await repeat.request({command:'open',config:{backupPath:temp,keysPath:path.join(temp,'keys.json'),
          statePath:path.join(temp,'repeat.sqlite'),physicalCatalogRoot:path.join(temp,'catalogs'),accountUin:'7',batchSize:10}});
        let complete:any;
        for(let i=0;i<30;i++){
          const batch=await repeat.request({command:'next'});
          complete=await repeat.request({command:'commit',matches:[],objects:batch.objects.map((object:any)=>({object,target:{status:'new_payload'}}))});
          if(complete.state.phase==='done')break;
        }
        expect(complete.state.phase).toBe('done');
        expect(complete.state.physicalCacheHits).toBe(6);
        expect(complete.state.resourcesHashed).toBe(1);
      } finally {await repeat.stop();}

    } finally { await reader.stop(); }

  } finally { await fs.rm(temp, { recursive: true, force: true }); }
});

it('在实际数据库中匹配重复消息/媒体并绑定账号、用户与群聊，拒绝同 seq 误合并', async () => {
  const test = await startTestDb();
  try {
    const db = test.db;
    await db.execute(sql`insert into accounts(id,username,password_hash) values(1,'fixture','unused');
      insert into sync_state(account_id) values(1);
      insert into qq_accounts(id,account_id,uin,uid) values(1,1,10,'u_self');
      insert into peers(qq_account_id,kind,peer_id,uid,pts) values(1,'user',7,'u_author',1),(1,'group',42,null,1);
      insert into group_members(qq_account_id,group_id,user_id) values(1,42,7);
      insert into chats(id,qq_account_id,scene,peer_id,dialog_pts) values(1,1,'group',42,1)`);
    const raw = { msgRandom: '53', senderUid: 'u_author', clientSeq: '88', sendStatus: 2,
      elements: [{ elementType: 1, textElement: { content: '@测试', atType: 2, atNtUid: 'u_target' } }] };
    await db.execute(sql`insert into messages(chat_id,seq,random,sender_uin,time,version,segments,source,raw)
      values(1,12,53,7,to_timestamp(1700000010),1,'[]','live',${JSON.stringify(raw)}::jsonb)`);
    const r: BackupRecord = { table: 'msg_1_42', sourceKey: ['msg_1_42', 1700000010, '12', '53'], scene: 'group', peer: '42',
      seq: '12', clientSeq: '88', random: '53', time: 1700000010, senderUid: 'u_author', senderUin: '7', sendStatus: 2,
      identityDisagreement: false, elements: [{ type: 1, kind: 'mention', text: '@测试', targetUid: 'u_target' }], nodes: [] };
    const matcher = new BackupMatcher(db);
    const first = await matcher.matchBatch(1, [r]);
    expect(first[0]).toMatchObject({ status: 'same', chatId: 1, sender: { status: 'bound', userId: '7' } });
    expect(await matcher.matchBatch(1, [r])).toEqual(first);
    expect((await matcher.matchBatch(1, [{ ...r, time: r.time+1 }]))[0]).toMatchObject({
      status: 'same_identity_time_variant', timeEvidence: { deltaSeconds: -1 }, messageId: first[0]!.messageId,
    });
    expect((await matcher.matchBatch(1, [{ ...r, time: r.time+2 }]))[0]?.status).toBe('seq_conflict');
    expect((await matcher.matchBatch(1, [{ ...r, time: r.time+1, elements: [{ type: 1, kind: 'text', text: '另一条消息' }] }]))[0]?.status).toBe('seq_conflict');

    expect((await matcher.matchBatch(1, [{ ...r, random: '999' }]))[0]?.status).toBe('seq_conflict');
    const service = (await matcher.matchBatch(1, [{ ...r, senderUid: null, senderUin: null,
      elements: [{ type: 8, kind: 'poke', grayTip: { subElementType: 12, xmlElement: {
        content: '<gtip><qq uin="u_author"/><nor txt="拍了拍"/><qq uin="u_missing" jp="9"/></gtip>',
      } } }],
    }]))[0]!;
    expect(service.sender.status).toBe('not_applicable');
    expect(service.serviceElements?.[0]?.participants).toMatchObject([
      { userId: '7', displayName: '7', binding: { status: 'bound' } },
      { userId: '9', displayName: '9', binding: { status: 'unbound' } },
    ]);

    expect((await matcher.matchBatch(1, [{ ...r, senderUin: '8' }]))[0]?.sender.status).toBe('conflict');
    expect((await matcher.matchBatch(1, [{ ...r, peer: '999' }]))[0]?.status).toBe('chat_unbound');
    expect((await matcher.matchBatch(1, [{ ...r, elements: [{ type: 1, kind: 'mention', text: '@测试', targetUid: 'u_other' }] }]))[0]?.status).toBe('same_identity_content_variant');
    const ark = { ...raw, elements: [{elementType: 10, arkElement: {bytesData: '{"app":"fixture","id":9007199254740992}'}}] };
    await db.execute(sql`update messages set raw=${JSON.stringify(ark)}::jsonb where chat_id=1 and seq=12`);
    expect((await matcher.matchBatch(1, [{...r,elements:[{type:10,kind:'card',payload:'{"app":"fixture","id":9007199254740993}'}]}]))[0]?.status).toBe('same_identity_content_variant');
    await db.execute(sql`update messages set raw=${JSON.stringify(raw)}::jsonb where chat_id=1 and seq=12`);


    const stickerRaw={...raw,elements:[{elementType:11,marketFaceElement:{emojiId:'af'.repeat(16),emojiPackageId:'8'}}]};
    await db.execute(sql`update messages set raw=${JSON.stringify(stickerRaw)}::jsonb where chat_id=1 and seq=12`);
    const sticker={type:11,kind:'sticker',packageId:'8',identifiers:[{algorithm:'emoji_id',value:'af'.repeat(16),role:'main'}]};
    expect((await matcher.matchBatch(1,[{...r,elements:[sticker]}]))[0]?.status).toBe('same');
    expect((await matcher.matchBatch(1,[{...r,elements:[{...sticker,packageId:'9'}]}]))[0]?.status).toBe('same_identity_content_variant');
    await db.execute(sql`update messages set raw=${JSON.stringify(raw)}::jsonb where chat_id=1 and seq=12`);
    const sha = 'ab'.repeat(32);
    await db.execute(sql`insert into blobs(sha256,md5,md5_head,size,storage_key,state) values(${sha},'x','x',64,'x','present')`);
    const objects = await matcher.matchObjects([{ resourceId: '1', status: 'available', sha256: sha, size: 64 }, { resourceId: '2', status: 'available', sha256: sha, size: 64 }]);
    expect(objects.map(x => x.target.status)).toEqual(['reusable', 'reusable']);
    await db.execute(sql`update messages set state='recalled' where chat_id=1 and seq=12`);
    expect((await matcher.matchBatch(1, [r]))[0]?.status).toBe('same_identity_preserve_recalled');
    expect((await db.execute(sql`select count(*)::int as n from messages`)).rows[0]?.n).toBe(1);
  } finally { await test.stop(); }
});

it('松散媒体只遍历一次目录，重名、缺失和符号链接的判断不变', async () => {
  const temp = await fs.mkdtemp(path.join(os.tmpdir(), 'qq-import-loose-'));
  try {
    const native = await prepareNative(temp);
    const root = path.join(temp, 'backup');
    const script = `
import json, os, sys
from pathlib import Path
import media
root = Path(sys.argv[1])
for d in ('a', 'b'): (root / d).mkdir(parents=True)
(root / 'a' / 'one.bin').write_bytes(b'1')
(root / 'a' / 'dup.bin').write_bytes(b'1')
(root / 'b' / 'dup.bin').write_bytes(b'2')
(root / 'b' / 'link.bin').symlink_to(root / 'a' / 'one.bin')
walks = [0]
real = os.walk
def counting(*args, **kwargs):
    walks[0] += 1
    return real(*args, **kwargs)
media.os.walk = counting
reader = media.MediaReader(root, {}, lambda: None)
result = {'one': [str(p.relative_to(root)) for p in reader.loose('one.bin')], 'dup': len(reader.loose('dup.bin')),
  'missing': reader.loose('none.bin'), 'link': reader.loose('link.bin'), 'again': len(reader.loose('one.bin')), 'walks': walks[0]}
reader.close()
print(json.dumps(result))`;
    const { stdout } = await exec(importPython(), ['-c', script, root], {
      env: { ...process.env, QQ_IMPORT_NATIVE: native, PYTHONDONTWRITEBYTECODE: '1', PYTHONPATH: fileURLToPath(new URL('../src/imports/reader/', import.meta.url)) },
    });
    expect(JSON.parse(stdout)).toEqual({ one: ['a/one.bin'], dup: 2, missing: [], link: [], again: 1, walks: 1 });
  } finally { await fs.rm(temp, { recursive: true, force: true }); }
});
