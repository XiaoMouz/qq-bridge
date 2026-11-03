import { spawn, execFile, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';
import { promisify } from 'node:util';

const exec = promisify(execFile);
const managedPython = fileURLToPath(new URL('../../.backup-import-venv/bin/python', import.meta.url));
export const importPython = (): string => process.env.BACKUP_IMPORT_PYTHON || (existsSync(managedPython) ? managedPython : 'python3');

const readerRoot = fileURLToPath(new URL('./reader/', import.meta.url));

export async function prepareNative(root: string): Promise<string> {
  const files = ['msg0codec.c', 'pendingbyte_fix.c'];
  const digest = createHash('sha256').update(process.platform + ':' + process.arch);
  for (const name of files) digest.update(await fs.readFile(path.join(readerRoot, name)));
  const destination = path.join(root, 'native', digest.digest('hex').slice(0, 16));
  await fs.mkdir(destination, { recursive: true, mode: 0o700 });
  for (const name of files) {
    const output = path.join(destination, name.replace('.c', '.so'));
    try { await fs.access(output); } catch {
      await exec('cc', ['-O2', '-shared', '-fPIC', path.join(readerRoot, name), '-o', output + '.partial'], { timeout: 60_000 });
      await fs.rename(output + '.partial', output);
    }
  }
  return destination;
}

/** 每次只容纳一批 IPC；Python 等待 commit，stdout 背压不会无限预取。 */
export class ReaderProcess {
  readonly child: ChildProcessWithoutNullStreams;
  private waiting: { resolve: (v: any) => void; reject: (e: Error) => void } | null = null;
  private ended = false;
  private readonly done: Promise<void>;
  /** script：预检用 worker.py，导入用 importer.py（同样的逐行 JSON 协议）。 */
  constructor(python: string, native: string, script: 'worker.py' | 'importer.py' = 'worker.py') {
    this.child = spawn(python, ['-u', path.join(readerRoot, script)], {
      stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, QQ_IMPORT_NATIVE: native, PYTHONDONTWRITEBYTECODE: '1' },
    });
    // 不把 stderr 当协议，避免环境诊断泄漏密钥路径；失败在任务状态中显示受控代码。
    this.child.stderr.resume();
    this.child.stdin.on('error', () => undefined);
    const lines = createInterface({ input: this.child.stdout });
    lines.on('line', line => {
      const pending = this.waiting;
      if (!pending) return;
      this.waiting = null;
      try {
        const data = JSON.parse(line);
        if (data.error) pending.reject(new Error(`备份解析失败：${data.error} (${data.reason})`));
        else pending.resolve(data);
      } catch (error) { pending.reject(error as Error); }
    });
    this.done = new Promise(resolve => {
      const finish = () => {
        this.ended = true;
        this.waiting?.reject(new Error('备份解析进程已停止'));
        this.waiting = null;
        resolve();
      };
      this.child.once('error', finish);
      this.child.once('close', finish);
    });
  }
  request(value: unknown): Promise<any> {
    if (this.ended) return Promise.reject(new Error('备份解析进程不可用；请检查 Python/APSW 配置'));
    if (this.waiting) throw new Error('reader request already pending');
    return new Promise((resolve, reject) => {
      this.waiting = { resolve, reject };
      this.child.stdin.write(JSON.stringify(value) + '\n', error => {
        if (error) { this.waiting = null; reject(error); }
      });
    });
  }
  async stop(): Promise<void> {
    this.child.stdin.end();
    this.child.kill('SIGTERM');
    const timeout = setTimeout(() => this.child.kill('SIGKILL'), 5000);
    try { await this.done; } finally { clearTimeout(timeout); }
  }
}

export async function readReport(python: string, statePath: string, view: string, cursor: number, limit: number, kind: string, status = ''): Promise<unknown> {
  const { stdout } = await exec(python, [path.join(readerRoot, 'worker.py'), 'report', statePath, view, String(cursor), String(limit), kind, status], {
    timeout: 60_000, maxBuffer: 8 * 1024 * 1024, env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' },
  });
  return JSON.parse(stdout);
}
