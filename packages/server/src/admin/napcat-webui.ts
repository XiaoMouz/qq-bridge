// NapCat WebUI 客户端（只在本机回环访问）：QQ 登录状态、扫码登录二维码。
// 登录方式与 WebUI 前端相同：sha256(token + ".napcat") 换一个 Credential，有效期 1 小时，这里提前 10 分钟换新。
import { createHash } from 'node:crypto';

export interface QqLoginState {
  loggedIn: boolean;
  offline: boolean;
  phase: string;
  qrcodeUrl: string;
  error: string;
}

export class NapcatWebUi {
  private credential: { value: string; expiresAt: number } | null = null;

  constructor(
    private readonly baseUrl: string,
    private readonly token: string,
    private readonly timeoutMs = 10_000,
  ) {}

  async loginState(): Promise<QqLoginState> {
    const d = await this.post<{
      isLogin?: boolean;
      isOffline?: boolean;
      loginPhase?: string;
      qrcodeurl?: string;
      loginError?: string;
    }>('/QQLogin/CheckLoginStatus');
    return {
      loggedIn: Boolean(d?.isLogin),
      offline: Boolean(d?.isOffline),
      phase: d?.loginPhase ?? '',
      qrcodeUrl: d?.isLogin ? '' : (d?.qrcodeurl ?? ''),
      error: d?.loginError ?? '',
    };
  }

  async refreshQrcode(): Promise<string> {
    await this.post('/QQLogin/RefreshQRcode');
    // 新二维码要等 NapCat 向 QQ 要回来，稍等片刻再取。
    for (let i = 0; i < 10; i++) {
      await new Promise((resolve) => setTimeout(resolve, 500));
      const state = await this.loginState();
      if (state.qrcodeUrl) return state.qrcodeUrl;
    }
    return '';
  }

  private async post<T>(path: string, body: unknown = {}, retry = true): Promise<T> {
    const credential = await this.login();
    const res = await fetch(`${this.baseUrl}/api${path}`, {
      method: 'POST',
      headers: { authorization: `Bearer ${credential}`, 'content-type': 'application/json' },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(this.timeoutMs),
    });
    const json = (await res.json().catch(() => ({}))) as { code?: number; message?: string; data?: T };
    if (res.status === 401 || json.message === 'Unauthorized') {
      this.credential = null;
      if (retry) return this.post(path, body, false);
    }
    if (!res.ok || json.code !== 0) throw new Error(`NapCat WebUI ${path}: ${json.message ?? res.status}`);
    return json.data as T;
  }

  private async login(): Promise<string> {
    if (this.credential && this.credential.expiresAt > Date.now()) return this.credential.value;
    const hash = createHash('sha256').update(`${this.token}.napcat`).digest('hex');
    const res = await fetch(`${this.baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ hash }),
      signal: AbortSignal.timeout(this.timeoutMs),
    });
    const json = (await res.json().catch(() => ({}))) as { code?: number; message?: string; data?: { Credential?: string } };
    const value = json.data?.Credential;
    if (!value) throw new Error(`NapCat WebUI login failed: ${json.message ?? res.status}`);
    this.credential = { value, expiresAt: Date.now() + 50 * 60_000 };
    return value;
  }
}
