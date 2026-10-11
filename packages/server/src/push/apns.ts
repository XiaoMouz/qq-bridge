// APNs 客户端：HTTP/2 + 令牌认证（.p8 密钥签 ES256 JWT）。不依赖第三方库。
// 每个环境（sandbox / production）一条长连接，断了下次发送时重连；JWT 50 分钟换一次（Apple 要求 20–60 分钟）。
import { createPrivateKey, sign, type KeyObject } from 'node:crypto';
import http2 from 'node:http2';
import type { Logger } from 'pino';

export type ApnsEnv = 'sandbox' | 'production';

export interface ApnsOptions {
  /** .p8 文件内容（PEM）。 */
  key: string;
  keyId: string;
  teamId: string;
  /** App 的 bundle id。 */
  topic: string;
  /** 测试时换成本地的 h2c 服务。 */
  origins?: Partial<Record<ApnsEnv, string>>;
  logger?: Logger;
}

export interface ApnsMessage {
  token: string;
  env: ApnsEnv;
  payload: unknown;
  pushType?: 'alert' | 'background' | 'voip';
  /** 10 = 立即，5 = 省电。 */
  priority?: 5 | 10;
  collapseId?: string;
  /** 设备离线时 APNs 保留多久（秒，0 = 不保留）。 */
  ttlSec?: number;
}

export type ApnsResult =
  | { ok: true }
  /** 令牌已失效（卸载、换了环境等），应从设备记录里清掉。 */
  | { ok: false; status: number; reason: string; invalidToken: boolean };

const DEFAULT_ORIGINS: Record<ApnsEnv, string> = {
  sandbox: 'https://api.sandbox.push.apple.com',
  production: 'https://api.push.apple.com',
};
const INVALID_TOKEN_REASONS = new Set(['BadDeviceToken', 'Unregistered', 'DeviceTokenNotForTopic', 'ExpiredToken']);
const JWT_TTL_MS = 50 * 60_000;

export interface PushSender {
  send(message: ApnsMessage): Promise<ApnsResult>;
  close(): void;
}

export class ApnsClient implements PushSender {
  private readonly key: KeyObject;
  private readonly sessions = new Map<ApnsEnv, http2.ClientHttp2Session>();
  private jwt: { token: string; at: number } | null = null;

  constructor(private readonly opts: ApnsOptions) {
    this.key = createPrivateKey(opts.key);
  }

  async send(message: ApnsMessage): Promise<ApnsResult> {
    let result = await this.post(message);
    // 认证令牌过期（比如机器睡了很久）：换一个重试一次。
    if (!result.ok && result.status === 403 && result.reason === 'ExpiredProviderToken') {
      this.jwt = null;
      result = await this.post(message);
    }
    if (!result.ok) this.opts.logger?.warn({ status: result.status, reason: result.reason, env: message.env }, 'apns push rejected');
    return result;
  }

  close(): void {
    for (const s of this.sessions.values()) s.close();
    this.sessions.clear();
  }

  private post(message: ApnsMessage): Promise<ApnsResult> {
    const body = Buffer.from(JSON.stringify(message.payload));
    const headers: http2.OutgoingHttpHeaders = {
      ':method': 'POST',
      ':path': `/3/device/${message.token}`,
      authorization: `bearer ${this.providerToken()}`,
      'apns-topic': message.pushType === 'voip' ? `${this.opts.topic}.voip` : this.opts.topic,
      'apns-push-type': message.pushType ?? 'alert',
      'apns-priority': String(message.priority ?? 10),
      'apns-expiration': String(message.ttlSec ? Math.floor(Date.now() / 1000) + message.ttlSec : 0),
      'content-type': 'application/json',
      'content-length': body.length,
    };
    if (message.collapseId) headers['apns-collapse-id'] = message.collapseId;
    return new Promise((resolve, reject) => {
      let req: http2.ClientHttp2Stream;
      try {
        req = this.session(message.env).request(headers);
      } catch (error) {
        reject(error);
        return;
      }
      req.setTimeout(30_000, () => req.close(http2.constants.NGHTTP2_CANCEL));
      let status = 0;
      const chunks: Buffer[] = [];
      req.on('response', (h) => (status = Number(h[':status'])));
      req.on('data', (c: Buffer) => chunks.push(c));
      req.on('error', reject);
      req.on('close', () => {
        if (status === 200) return resolve({ ok: true });
        if (status === 0) return reject(new Error('apns request closed without a response'));
        let reason = '';
        try {
          reason = String((JSON.parse(Buffer.concat(chunks).toString('utf8')) as { reason?: string }).reason ?? '');
        } catch {
          // 没有正文
        }
        resolve({ ok: false, status, reason, invalidToken: status === 410 || INVALID_TOKEN_REASONS.has(reason) });
      });
      req.end(body);
    });
  }

  private session(env: ApnsEnv): http2.ClientHttp2Session {
    const existing = this.sessions.get(env);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const session = http2.connect(this.opts.origins?.[env] ?? DEFAULT_ORIGINS[env]);
    session.on('error', (error) => this.opts.logger?.warn({ err: error, env }, 'apns connection error'));
    session.on('close', () => {
      if (this.sessions.get(env) === session) this.sessions.delete(env);
    });
    session.on('goaway', () => {
      if (this.sessions.get(env) === session) this.sessions.delete(env);
    });
    // 空闲时不让这条连接拖住进程退出。
    session.unref();
    this.sessions.set(env, session);
    return session;
  }

  private providerToken(): string {
    if (this.jwt && Date.now() - this.jwt.at < JWT_TTL_MS) return this.jwt.token;
    const enc = (v: object) => Buffer.from(JSON.stringify(v)).toString('base64url');
    const input = `${enc({ alg: 'ES256', kid: this.opts.keyId })}.${enc({ iss: this.opts.teamId, iat: Math.floor(Date.now() / 1000) })}`;
    const signature = sign('sha256', Buffer.from(input), { key: this.key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
    this.jwt = { token: `${input}.${signature}`, at: Date.now() };
    return this.jwt.token;
  }
}
