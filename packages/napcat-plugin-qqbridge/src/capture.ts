import fs from 'node:fs/promises';
import path from 'node:path';

/**
 * 按天切分的 JSONL 采样写入器。
 * 写入串行化（单个 Promise 链），保证同一文件内行的顺序与调用顺序一致；写失败只记日志，不影响 QQ。
 */
export class CaptureWriter {
  private chain: Promise<void> = Promise.resolve();
  private readonly dir: string;

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
        await fs.appendFile(file, line, { mode: 0o600 });
      })
      .catch(this.onError);
  }

  async flush(): Promise<void> {
    await this.chain;
  }
}

function bigintReplacer(_key: string, value: unknown): unknown {
  return typeof value === 'bigint' ? value.toString() : value;
}
