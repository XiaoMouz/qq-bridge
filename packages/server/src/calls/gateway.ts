// 通话网关（packages/call-gateway 的 serve 模式）的控制接口客户端：让网关以"QQ 端"身份进出 LiveKit 房间。
export interface CallGateway {
  join(room: string, token: string): Promise<void>;
  leave(room: string): Promise<void>;
  /** 网关健康状态（管理页用）：连不上时抛错。 */
  status?(): Promise<{ room: string | null }>;
}

export class HttpCallGateway implements CallGateway {
  constructor(
    private readonly baseUrl: string,
    private readonly token: string,
    private readonly timeoutMs = 10_000,
  ) {}

  async join(room: string, token: string): Promise<void> {
    await this.request('POST', '/bridges', { room, token });
  }

  async leave(room: string): Promise<void> {
    await this.request('DELETE', `/bridges/${encodeURIComponent(room)}`);
  }

  async status(): Promise<{ room: string | null }> {
    const res = await fetch(new URL('/status', this.baseUrl), {
      headers: { authorization: `Bearer ${this.token}` },
      signal: AbortSignal.timeout(3000),
    });
    if (!res.ok) throw new Error(`call gateway status ${res.status}`);
    const body = (await res.json()) as { room?: string | null };
    return { room: body.room ?? null };
  }

  private async request(method: string, path: string, body?: unknown): Promise<void> {
    const res = await fetch(new URL(path, this.baseUrl), {
      method,
      headers: { authorization: `Bearer ${this.token}`, ...(body ? { 'content-type': 'application/json' } : {}) },
      ...(body ? { body: JSON.stringify(body) } : {}),
      signal: AbortSignal.timeout(this.timeoutMs),
    });
    if (!res.ok && !(method === 'DELETE' && res.status === 404)) {
      throw new Error(`call gateway ${method} ${path} failed: ${res.status} ${await res.text().catch(() => '')}`);
    }
  }
}
