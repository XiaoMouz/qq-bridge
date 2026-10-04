// 认证：单所有者账号（argon2id 密码）+ 每台设备一个随机令牌（库里只存 sha256）。见 docs/design.md 4.10。
import { createHash, randomBytes } from 'node:crypto';
import { hash, verify } from '@node-rs/argon2';
import { sql } from 'drizzle-orm';
import { maybeOne, one, rows, toDate, type Db } from '../db/client.ts';

export interface AuthContext {
  accountId: number;
  deviceId: number;
}

export interface DeviceInfo {
  id: number;
  name: string;
  platform: string;
  createdAt: Date;
  lastSeenAt: Date | null;
  current: boolean;
}

export class InvalidCredentialsError extends Error {}

const TOKEN_PREFIX = 'qqb_';
/** last_seen_at 最多每分钟写一次，避免每个请求都写库。 */
const LAST_SEEN_THROTTLE_MS = 60_000;

export function hashToken(token: string): Buffer {
  return createHash('sha256').update(token, 'utf8').digest();
}

export class AuthService {
  private readonly lastSeenWrites = new Map<number, number>();
  private dummy: Promise<string> | null = null;

  constructor(private readonly db: Db) {}

  private dummyHash(): Promise<string> {
    this.dummy ??= hash(randomBytes(16).toString('hex'));
    return this.dummy;
  }

  async createAccount(username: string, password: string): Promise<number> {
    if (password.length < 8) throw new Error('password must be at least 8 characters');
    const passwordHash = await hash(password);
    return this.db.transaction(async (tx) => {
      const row = await one<{ id: number }>(
        tx,
        sql`insert into accounts (username, password_hash) values (${username}, ${passwordHash}) returning id`,
      );
      await tx.execute(sql`insert into sync_state (account_id) values (${row.id})`);
      return row.id;
    });
  }

  async login(username: string, password: string, device: { name: string; platform: string }): Promise<{ token: string } & AuthContext> {
    const account = await maybeOne<{ id: number; password_hash: string }>(
      this.db,
      sql`select id, password_hash from accounts where username = ${username}`,
    );
    // 账号不存在时也做一次同等代价的哈希校验，避免通过响应时间探测用户名。
    const ok = await verify(account?.password_hash ?? (await this.dummyHash()), password).catch(() => false);
    if (!account || !ok) throw new InvalidCredentialsError('invalid username or password');
    const token = TOKEN_PREFIX + randomBytes(32).toString('base64url');
    const row = await one<{ id: number }>(
      this.db,
      sql`insert into devices (account_id, name, platform, token_hash) values (${account.id}, ${device.name}, ${device.platform}, ${hashToken(token)})
          returning id`,
    );
    return { token, accountId: account.id, deviceId: row.id };
  }

  async authenticate(token: string): Promise<AuthContext | null> {
    if (!token.startsWith(TOKEN_PREFIX)) return null;
    const row = await maybeOne<{ id: number; account_id: number }>(
      this.db,
      sql`select id, account_id from devices where token_hash = ${hashToken(token)} and revoked_at is null`,
    );
    if (!row) return null;
    const now = Date.now();
    if (now - (this.lastSeenWrites.get(row.id) ?? 0) > LAST_SEEN_THROTTLE_MS) {
      this.lastSeenWrites.set(row.id, now);
      await this.db.execute(sql`update devices set last_seen_at = now() where id = ${row.id}`);
    }
    return { accountId: row.account_id, deviceId: row.id };
  }

  async listDevices(ctx: AuthContext): Promise<DeviceInfo[]> {
    const list = await rows(
      this.db,
      sql`select id, name, platform, created_at, last_seen_at from devices
           where account_id = ${ctx.accountId} and revoked_at is null order by created_at`,
    );
    return list.map((r) => ({
      id: r.id as number,
      name: r.name as string,
      platform: r.platform as string,
      createdAt: toDate(r.created_at)!,
      lastSeenAt: toDate(r.last_seen_at),
      current: r.id === ctx.deviceId,
    }));
  }

  async revokeDevice(ctx: AuthContext, deviceId: number): Promise<boolean> {
    const list = await rows(
      this.db,
      sql`update devices set revoked_at = now() where id = ${deviceId} and account_id = ${ctx.accountId} and revoked_at is null returning id`,
    );
    return list.length > 0;
  }
}
