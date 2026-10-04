import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { dialogToProto } from '../src/api/convert.ts';
import { DialogPrefs, DialogPrefsError } from '../src/dialogs/prefs.ts';
import { getDifference, getState } from '../src/sync/difference.ts';
import { startTestDb, type TestDb } from './helpers/db.ts';
import { createTestAccount, services, textMessage } from './helpers/fixtures.ts';

let t: TestDb;
beforeAll(async () => {
  t = await startTestDb();
});
afterAll(async () => {
  await t?.stop();
});

async function setup() {
  const { ingest, writers } = services(t.db);
  const acc = await createTestAccount(t.db, ingest);
  const { chatId } = await ingest.ingestMessage(acc.qqAccountId, textMessage('group', 800001, 5, 20002));
  return { acc, chatId, prefs: new DialogPrefs(writers) };
}

describe('dialog preferences', () => {
  it('syncs pin and notification changes to other devices, and ignores no-op changes', async () => {
    const { acc, chatId, prefs } = await setup();
    const before = (await getState(t.db, acc.accountId)).pts;
    expect(await prefs.setPinned(acc.accountId, chatId, true)).toBe(true);
    expect(await prefs.setNotifyPolicy(acc.accountId, chatId, 'mentions')).toBe(true);
    const diff = await getDifference(t.db, acc.accountId, before);
    expect(diff.dialogs).toHaveLength(1);
    expect(diff.dialogs[0]).toMatchObject({ chatId, pinned: true, notifyPolicy: 'mentions' });

    const after = (await getState(t.db, acc.accountId)).pts;
    expect(await prefs.setPinned(acc.accountId, chatId, true)).toBe(false);
    expect(await prefs.setNotifyPolicy(acc.accountId, chatId, 'mentions')).toBe(false);
    expect((await getState(t.db, acc.accountId)).pts).toBe(after); // 没变化就不推送

    await expect(prefs.setNotifyPolicy(acc.accountId, chatId, 'loud')).rejects.toBeInstanceOf(DialogPrefsError);
    const other = await createTestAccount(t.db, services(t.db).ingest);
    await expect(prefs.setPinned(other.accountId, chatId, true)).rejects.toMatchObject({ code: 'not_found' });
  });

  it('keeps drafts in sync across devices, without re-pushing unchanged drafts', async () => {
    const { acc, chatId, prefs } = await setup();
    const segments = [
      { type: 'mention' as const, userId: 20002 },
      { type: 'text' as const, text: ' 晚上一起' },
    ];
    expect(await prefs.saveDraft(acc.accountId, chatId, segments, 5, 1_700_000_000)).toBe(true);
    const [dialog] = (await getDifference(t.db, acc.accountId, 0)).dialogs;
    expect(dialog!.draft).toEqual({ segments, replyToSeq: 5, updatedAt: 1_700_000_000 });
    expect(dialogToProto(dialog!).draft).toMatchObject({ replyToSeq: 5n, updatedAt: 1_700_000_000n });
    expect(dialogToProto(dialog!).draft!.segments.map((s) => s.kind.case)).toEqual(['mentionUserId', 'text']);

    expect(await prefs.saveDraft(acc.accountId, chatId, segments, 5, 1_700_000_100)).toBe(false); // 内容没变
    expect(await prefs.saveDraft(acc.accountId, chatId, [])).toBe(true); // 清除
    const [cleared] = (await getDifference(t.db, acc.accountId, 0)).dialogs;
    expect(cleared!.draft).toBeNull();
    expect(dialogToProto(cleared!).draft).toBeUndefined();

    await expect(prefs.saveDraft(acc.accountId, chatId, [{ type: 'image', sha256: 'a'.repeat(64) }])).rejects.toMatchObject({
      code: 'invalid',
    });
  });
});
