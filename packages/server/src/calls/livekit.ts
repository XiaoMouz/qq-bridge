import { AccessToken } from 'livekit-server-sdk';

/** 签发 LiveKit 入会令牌：只能进指定房间，有效期默认 2 小时（够一通长电话）。 */
export async function mintLiveKitToken(
  cfg: { livekitApiKey: string; livekitApiSecret: string },
  room: string,
  identity: string,
  ttlSec = 2 * 3600,
): Promise<string> {
  const token = new AccessToken(cfg.livekitApiKey, cfg.livekitApiSecret, { identity, ttl: ttlSec });
  token.addGrant({ room, roomJoin: true, canPublish: true, canSubscribe: true });
  return token.toJwt();
}
