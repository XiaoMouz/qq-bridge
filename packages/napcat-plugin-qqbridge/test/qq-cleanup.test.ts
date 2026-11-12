import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { cleanupDirs, runCleanup } from '../src/qq-cleanup.js';

const ACCOUNT = 'nt_qq_40ce03f34ff1d2a3a55cc6ff040e112a';
const DAY = 86_400_000;
let root: string | null = null;
afterEach(() => {
  if (root) fs.rmSync(root, { recursive: true, force: true });
  root = null;
});

function file(rel: string, ageDays: number, bytes = 10): string {
  const p = path.join(root!, rel);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, Buffer.alloc(bytes));
  const t = new Date(Date.now() - ageDays * DAY);
  fs.utimesSync(p, t, t);
  return p;
}

function setup() {
  root = fs.mkdtempSync(path.join(os.tmpdir(), 'qqbridge-cleanup-'));
  return {
    oldThumb: file(`${ACCOUNT}/nt_data/Video/2026-10/Thumb/a_0.png`, 30, 100),
    newThumb: file(`${ACCOUNT}/nt_data/Video/2026-11/Thumb/b_0.png`, 1),
    oldPtt: file(`${ACCOUNT}/nt_data/Ptt/2026-10/Ori/c.amr`, 8, 20),
    oldLog: file(`${ACCOUNT}/nt_data/log/qq-log_2026-10-01-01.qqxlog`, 40, 1000),
    oldGlobalLog: file('nt_qq/global/nt_data/Log/log/prelogin-log.qqxlog', 20, 5),
    oldTemp: file('NapCat/temp/x.mp4', 13, 7),
    // 这些不管多旧都不能删
    msgDb: file(`${ACCOUNT}/nt_db/nt_msg.db`, 60),
    avatar: file(`${ACCOUNT}/nt_data/avatar/user/a.jpg`, 60),
    emoji: file('nt_qq/global/nt_data/Emoji/emoji-resource/x.png', 60),
    login: file('nt_qq/global/nt_db/login.db', 60),
    otherAccount: file('nt_qq_notanaccount/nt_data/Pic/x.jpg', 60),
  };
}

describe('qq cleanup', () => {
  it('only lists media cache, logs and NapCat temp', async () => {
    setup();
    const dirs = (await cleanupDirs(root!)).map((d) => path.relative(root!, d)).sort();
    expect(dirs).toEqual(
      [`${ACCOUNT}/nt_data/Ptt`, `${ACCOUNT}/nt_data/Video`, `${ACCOUNT}/nt_data/log`, 'NapCat/temp', 'nt_qq/global/nt_data/Log/log'].sort(),
    );
  });

  it('dry run counts but deletes nothing', async () => {
    const f = setup();
    const r = await runCleanup(root!, 7, true);
    expect(r).toMatchObject({ dryRun: true, files: 5, bytes: 100 + 20 + 1000 + 5 + 7, errors: 0 });
    for (const p of Object.values(f)) expect(fs.existsSync(p)).toBe(true);
  });

  it('deletes files older than the cutoff and keeps everything else', async () => {
    const f = setup();
    const r = await runCleanup(root!, 7, false);
    expect(r.files).toBe(5);
    for (const p of [f.oldThumb, f.oldPtt, f.oldLog, f.oldGlobalLog, f.oldTemp]) expect(fs.existsSync(p)).toBe(false);
    for (const p of [f.newThumb, f.msgDb, f.avatar, f.emoji, f.login, f.otherAccount]) expect(fs.existsSync(p)).toBe(true);
    // 目录留着（QQ 按月份目录写缓存）
    expect(fs.existsSync(path.dirname(f.oldThumb))).toBe(true);
  });

  it('does not follow symlinks out of the cache dirs', async () => {
    const f = setup();
    fs.symlinkSync(path.dirname(f.msgDb), path.join(root!, ACCOUNT, 'nt_data/Video/db-link'));
    await runCleanup(root!, 7, false);
    expect(fs.existsSync(f.msgDb)).toBe(true);
  });
});
