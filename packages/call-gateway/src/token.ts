import { AccessToken } from 'livekit-server-sdk';

/** 签发 LiveKit 入会令牌（生产中由服务端的 CallService 签发，这里供网关自测与 CLI 使用）。 */
export async function mintRoomToken(opts: {
  apiKey: string;
  apiSecret: string;
  room: string;
  identity: string;
  ttlSec?: number;
}): Promise<string> {
  const token = new AccessToken(opts.apiKey, opts.apiSecret, { identity: opts.identity, ttl: opts.ttlSec ?? 3600 });
  token.addGrant({ room: opts.room, roomJoin: true, canPublish: true, canSubscribe: true });
  return token.toJwt();
}
