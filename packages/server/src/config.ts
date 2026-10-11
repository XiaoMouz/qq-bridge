import { z } from 'zod';

const ConfigSchema = z.object({
  DATABASE_URL: z.string().min(1),
  HOST: z.string().default('127.0.0.1'),
  PORT: z.coerce.number().int().min(1).max(65535).default(8080),
  /** 媒体内容寻址存储的根目录。 */
  MEDIA_ROOT: z.string().default('./data/media'),
  /** 冷存储根目录（廉价大硬盘等）。不设置则不分层，所有原件都在 MEDIA_ROOT。 */
  MEDIA_COLD_ROOT: optionalString(z.string().min(1)),
  /** 媒体签名链接的密钥（至少 32 字节）。 */
  MEDIA_URL_SECRET: z.string().min(32),
  LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace']).default('info'),
  /** 同时下载的媒体数。0 = 不启动下载任务。 */
  MEDIA_FETCH_CONCURRENCY: z.coerce.number().int().min(0).max(32).default(3),
  /** 没有配置存储策略时的自动下载大小上限（字节）。 */
  MEDIA_AUTO_FETCH_MAX_BYTES: z.coerce.number().int().positive().default(200 * 1024 * 1024),
  /** 上游（NapCat 插件）接入口令，至少 32 字节，插件侧配同一个值；不设置则不开放上游接入点。 */
  UPSTREAM_TOKEN: optionalString(z.string().min(32)),
  /** QQ 号归属的服务端账号（用户名）；只有一个账号时可以不填。 */
  UPSTREAM_ACCOUNT: optionalString(z.string().min(1)),
  /** 对账时，服务端没见过的会话预热多少条。 */
  UPSTREAM_WARM_MESSAGES: z.coerce.number().int().min(0).max(5000).default(200),
  /** 对账回填时两次请求的最小间隔（毫秒，防风控）。 */
  UPSTREAM_BACKFILL_INTERVAL_MS: z.coerce.number().int().min(200).default(1000),
  /** 已入库的原始事件在收件箱里保留多少天。 */
  UPSTREAM_INBOX_RETENTION_DAYS: z.coerce.number().int().min(1).default(30),
  /** 插件（QQ 容器）访问服务端媒体的地址前缀，发送媒体时 NapCat 从这里下载；默认 http://host.internal:<PORT>。 */
  UPSTREAM_MEDIA_BASE_URL: optionalString(z.string().url()),
  /** ffmpeg 路径（语音转码、视频封面）；默认从 PATH 找，找不到时这两项跳过。 */
  FFMPEG_PATH: optionalString(z.string().min(1)),
  /** 单个上传的大小上限（字节）。 */
  UPLOAD_MAX_BYTES: z.coerce.number().int().positive().default(1024 * 1024 * 1024),
  /** 通话（docs/design.md 5.2）：LiveKit 密钥与客户端连 LiveKit 的地址；四项都配了才开放 CallService 的接听。 */
  LIVEKIT_API_KEY: optionalString(z.string().min(1)),
  LIVEKIT_API_SECRET: optionalString(z.string().min(32)),
  /** 客户端（iPhone / 测试页）连 LiveKit 的地址，例如 wss://<mac>.<tailnet>.ts.net:7443。 */
  LIVEKIT_PUBLIC_URL: optionalString(z.string().regex(/^wss?:\/\//)),
  /** 通话网关控制接口（call-gateway serve）。 */
  CALL_GATEWAY_URL: z.string().url().default('http://127.0.0.1:6120'),
  CALL_GATEWAY_TOKEN: optionalString(z.string().min(32)),
  /** NapCat WebUI（扫码登录中转、登录状态）：地址与口令，与 deploy/.env 里给 QQ 容器的 NAPCAT_WEBUI_TOKEN 相同。 */
  NAPCAT_WEBUI_URL: z.string().url().default('http://127.0.0.1:6099'),
  NAPCAT_WEBUI_TOKEN: optionalString(z.string().min(8)),
  /** APNs 推送（令牌认证）：.p8 密钥文件路径、Key ID、Team ID；三项都配了才推送。 */
  APNS_KEY_PATH: optionalString(z.string().min(1)),
  APNS_KEY_ID: optionalString(z.string().length(10)),
  APNS_TEAM_ID: optionalString(z.string().length(10)),
  /** App 的 bundle id（APNs 的 topic）。 */
  APNS_TOPIC: z.string().default('com.xiaomouz.qqbridge'),
  /** 0：通知里不写消息内容，只写"新消息"（内容不经过 Apple 的服务器）。 */
  APNS_PREVIEW: z.preprocess((v) => !(v === '0' || v === 'false'), z.boolean()).default(true),
  /** 开放 /lab/call 通话测试页（iOS 客户端完成前代替 iPhone 接听）。 */
  CALL_LAB: z.preprocess((v) => v === '1' || v === 'true', z.boolean()).default(false),
});

/** .env 里写了 KEY= 但没填值时按"未设置"处理。 */
function optionalString<T extends z.ZodType>(schema: T) {
  return z.preprocess((v) => (v === '' ? undefined : v), schema.optional());
}

export type Config = z.infer<typeof ConfigSchema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const parsed = ConfigSchema.safeParse(env);
  if (!parsed.success) {
    const issues = parsed.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join('; ');
    throw new Error(`invalid configuration: ${issues}`);
  }
  return parsed.data;
}
