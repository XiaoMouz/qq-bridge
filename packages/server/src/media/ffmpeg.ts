// 调用 ffmpeg（语音转码、取视频封面）。输入可以是文件路径或通过 stdin 给的内容，输出走 stdout 或调用方指定的文件。
import { spawn } from 'node:child_process';

export interface FfmpegOptions {
  ffmpegPath?: string;
  /** 通过 stdin 输入的内容（参数里对应 -i pipe:0）。 */
  input?: Buffer;
  timeoutMs?: number;
}

export class FfmpegError extends Error {}

/** 运行 ffmpeg，返回 stdout。失败时抛 FfmpegError（带 stderr 的最后一段）。 */
export function runFfmpeg(args: string[], opts: FfmpegOptions = {}): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const child = spawn(opts.ffmpegPath ?? 'ffmpeg', ['-hide_banner', '-loglevel', 'error', '-nostdin', ...args], {
      stdio: [opts.input ? 'pipe' : 'ignore', 'pipe', 'pipe'],
    });
    if (opts.input) {
      // -nostdin 只关掉交互；"-i pipe:0" 仍然会读 stdin。
      child.stdin!.on('error', () => undefined);
      child.stdin!.end(opts.input);
    }
    const out: Buffer[] = [];
    let err = '';
    child.stdout!.on('data', (chunk: Buffer) => out.push(chunk));
    child.stderr!.on('data', (chunk: Buffer) => {
      err = (err + chunk.toString()).slice(-8000);
    });
    const timer = setTimeout(() => child.kill('SIGKILL'), opts.timeoutMs ?? 60_000);
    child.on('error', (error) => {
      clearTimeout(timer);
      reject(new FfmpegError(`cannot run ffmpeg: ${error.message}`));
    });
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      if (code === 0) resolve(Buffer.concat(out));
      else reject(new FfmpegError(`ffmpeg exited with ${signal ?? code}: ${err.trim()}`));
    });
  });
}

/** 本机有没有可用的 ffmpeg（没有时语音转码 / 视频封面跳过，不影响存档）。 */
export async function ffmpegAvailable(ffmpegPath?: string): Promise<boolean> {
  try {
    await runFfmpeg(['-version'], { ...(ffmpegPath ? { ffmpegPath } : {}), timeoutMs: 10_000 });
    return true;
  } catch {
    return false;
  }
}

export interface StreamInfo {
  index: number;
  type: 'video' | 'audio' | 'data' | 'subtitle' | 'attachment';
  /** ffmpeg 认不出的编码是 "none"（比如 iPhone 空间音频 apac、mebx 元数据轨）。 */
  codec: string;
}

/** 解析 "ffmpeg -i 文件" 打印的流列表（不依赖 ffprobe）。 */
export function parseStreams(stderr: string): StreamInfo[] {
  const out: StreamInfo[] = [];
  for (const m of stderr.matchAll(/Stream #0:(\d+)[^:]*: (Video|Audio|Data|Subtitle|Attachment): (\S+)/g)) {
    out.push({ index: Number(m[1]), type: m[2]!.toLowerCase() as StreamInfo['type'], codec: m[3]!.replace(/,$/, '') });
  }
  return out;
}

/** 列出文件里的流。 */
export async function probeStreams(file: string, opts: FfmpegOptions = {}): Promise<StreamInfo[]> {
  // 只给输入不给输出，ffmpeg 打完流信息后以非零码退出，这是预期的。
  const err = await runFfmpeg(['-loglevel', 'info', '-i', file], opts).then(
    () => '',
    (error: unknown) => (error instanceof FfmpegError ? error.message : ''),
  );
  return parseStreams(err);
}
