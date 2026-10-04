import fs from 'node:fs';
import path from 'node:path';

const LOOPBACK_HOSTS = new Set(['127.0.0.1', '::1', 'localhost']);

export interface BridgeConfig {
  /** 插件控制接口（只监听回环地址），供服务端适配器、AV Host 和调试脚本访问。 */
  controlHost: string;
  controlPort: number;
  /** AV Host 控制接口地址（同容器内的第二个 QQ/Electron 进程）。 */
  avHost: string;
  avPort: number;
  token: string;
  /** 采样：把事件写成 JSONL，供 P0 分析。 */
  captureEnabled: boolean;
  /** 通话桥总开关（默认关闭，做通话验证时再打开）：关闭时插件不接管通话引擎，AV Host 也不启动。 */
  calls: boolean;
  /** 研究用：收到来电后自动接听（只用于 G1 验证，生产必须由 iPhone 端接听）。 */
  autoAccept: boolean;
  /** 研究用：AVSDK 负载做键级脱敏后完整落盘（默认只记录结构摘要）。 */
  captureAvsdkValues: boolean;
  /** 研究用：对消息里的媒体链接做有效期探测。 */
  probeMediaUrls: boolean;
  /** 研究模式：开放向 AVSDK 发送任意指令的接口（G2 指令重放）。 */
  lab: boolean;
  /** 上游服务端地址（ws:// 或 wss://），例如 ws://host.internal:8080/upstream/napcat；为空时只做本地采样。 */
  upstreamUrl: string | null;
  /** 与服务端 UPSTREAM_TOKEN 相同；缺失或短于 32 字节时不连服务端。 */
  upstreamToken: string | null;
}

function port(value: string | undefined, fallback: number, name: string): number {
  if (value === undefined || value === '') return fallback;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 65535) {
    throw new Error(`${name} must be an integer TCP port`);
  }
  return parsed;
}

function flag(value: string | undefined, fallback: boolean): boolean {
  if (value === undefined || value === '') return fallback;
  return value === '1' || value.toLowerCase() === 'true';
}

function loopback(value: string | undefined, name: string): string {
  const host = value || '127.0.0.1';
  if (!LOOPBACK_HOSTS.has(host)) throw new Error(`${name} must be a loopback address`);
  return host;
}

/**
 * 运行时开关文件（KEY=VALUE，每行一个，# 开头是注释）：放在挂载卷上，覆盖同名环境变量。
 * 改了之后重载插件（tools/qq-plugin.sh reload）即可生效，不用重建容器、不用重新登录 QQ。
 * 只接受通话和研究相关的开关，连接地址和口令仍以环境变量为准。
 */
export const OVERRIDABLE = ['QQBRIDGE_CALLS', 'QQBRIDGE_CALL_AUTO_ACCEPT', 'QQBRIDGE_CAPTURE_AVSDK_VALUES', 'QQBRIDGE_LAB'] as const;

export function readOverrides(file: string): Record<string, string> {
  const text = readIfExists(file);
  const out: Record<string, string> = {};
  if (!text) return out;
  for (const line of text.split('\n')) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/.exec(line);
    if (m && (OVERRIDABLE as readonly string[]).includes(m[1]!)) out[m[1]!] = m[2]!;
  }
  return out;
}

export function loadConfig(processEnv: NodeJS.ProcessEnv = process.env): BridgeConfig {
  const env = { ...processEnv, ...readOverrides(processEnv.QQBRIDGE_OVERRIDES_FILE || '/app/napcat/config/qqbridge.env') };
  const tokenFile = env.QQBRIDGE_CONTROL_TOKEN_FILE || '/run/qqbridge/control.token';
  const token = (env.QQBRIDGE_CONTROL_TOKEN || readIfExists(tokenFile) || '').trim();
  if (Buffer.byteLength(token, 'utf8') < 32) {
    throw new Error(`control token is missing or shorter than 32 bytes (looked at ${tokenFile})`);
  }
  return {
    controlHost: loopback(env.QQBRIDGE_CONTROL_HOST, 'QQBRIDGE_CONTROL_HOST'),
    controlPort: port(env.QQBRIDGE_CONTROL_PORT, 6110, 'QQBRIDGE_CONTROL_PORT'),
    avHost: loopback(env.QQBRIDGE_AV_HOST_HOST, 'QQBRIDGE_AV_HOST_HOST'),
    avPort: port(env.QQBRIDGE_AV_HOST_PORT, 6111, 'QQBRIDGE_AV_HOST_PORT'),
    token,
    captureEnabled: flag(env.QQBRIDGE_CAPTURE, true),
    calls: flag(env.QQBRIDGE_CALLS, false),
    autoAccept: flag(env.QQBRIDGE_CALL_AUTO_ACCEPT, false),
    captureAvsdkValues: flag(env.QQBRIDGE_CAPTURE_AVSDK_VALUES, false),
    probeMediaUrls: flag(env.QQBRIDGE_PROBE_MEDIA_URLS, true),
    lab: flag(env.QQBRIDGE_LAB, false),
    upstreamUrl: upstreamUrl(env.QQBRIDGE_UPSTREAM_URL),
    upstreamToken: upstreamToken(env),
  };
}

function upstreamUrl(value: string | undefined): string | null {
  if (!value) return null;
  if (!/^wss?:\/\//.test(value)) throw new Error('QQBRIDGE_UPSTREAM_URL must start with ws:// or wss://');
  return value;
}

function upstreamToken(env: NodeJS.ProcessEnv): string | null {
  const file = env.QQBRIDGE_UPSTREAM_TOKEN_FILE || '/run/qqbridge/upstream.token';
  const token = (env.QQBRIDGE_UPSTREAM_TOKEN || readIfExists(file) || '').trim();
  return Buffer.byteLength(token, 'utf8') >= 32 ? token : null;
}

function readIfExists(file: string): string | null {
  try {
    return fs.readFileSync(path.resolve(file), 'utf8');
  } catch {
    return null;
  }
}
