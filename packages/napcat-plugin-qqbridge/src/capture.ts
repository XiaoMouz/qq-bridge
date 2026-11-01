import fs from 'node:fs/promises';
import path from 'node:path';

/** 采样文件名末尾的日期：`events-2026-11-01.jsonl` → `2026-11-01`。 */
const DAY_SUFFIX = /-(\d{4}-\d{2}-\d{2})\.jsonl$/;

/**
 * 按天切分的 JSONL 采样写入器。
 * 写入串行化（单个 Promise 链），保证同一文件内行的顺序与调用顺序一致；写失败只记日志，不影响 QQ。
 * 只保留当天的文件：每天第一次写入（含重载后的第一次）前删掉其他日期的采样文件，免得磁盘被撑满。
 */
export class CaptureWriter {
  private chain: Promise<void> = Promise.resolve();
  private readonly dir: string;
  private prunedDay: string | null = null;

  constructor(
    baseDir: string,
    private readonly enabled: boolean,
    private readonly onError: (error: unknown) => void,
  ) {
    this.dir = path.join(baseDir, 'capture');
  }

  write(stream: string, record: Record<string, unknown>): void {
    if (!this.enabled) return;
    const line = JSON.stringify({ capturedAt: new Date().toISOString(), ...record }, bigintReplacer) + '\n';
    const day = new Date().toISOString().slice(0, 10);
    const file = path.join(this.dir, `${stream}-${day}.jsonl`);
    this.chain = this.chain
      .then(async () => {
        await fs.mkdir(this.dir, { recursive: true });
        if (this.prunedDay !== day) {
          this.prunedDay = day;
          await this.pruneOtherDays(day).catch(this.onError);
        }
        await fs.appendFile(file, line, { mode: 0o600 });
      })
      .catch(this.onError);
  }

  private async pruneOtherDays(day: string): Promise<void> {
    for (const name of await fs.readdir(this.dir)) {
      const match = DAY_SUFFIX.exec(name);
      if (match && match[1] !== day) await fs.rm(path.join(this.dir, name), { force: true });
    }
  }

  async flush(): Promise<void> {
    await this.chain;
  }
}

function bigintReplacer(_key: string, value: unknown): unknown {
  return typeof value === 'bigint' ? value.toString() : value;
}
