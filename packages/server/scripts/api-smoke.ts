// 开发用：用服务端 API 做冒烟测试（发送、撤回、搜索）。账号密码从环境变量读，不落盘。
//   QQBRIDGE_URL=http://127.0.0.1:8080 QQBRIDGE_USER=owner QQBRIDGE_PASSWORD=... \
//     node --import tsx scripts/api-smoke.ts <命令> ...
// 命令：
//   send-text  <chatId> <文本> [回复的 seq]
//   send-image <chatId>                 生成一张测试图，走 PrepareUpload + tus 上传后发送
//   recall     <chatId> <seq>
//   search     <关键词>
import { createHash, randomInt } from 'node:crypto';
import { Code, ConnectError, createClient, type Interceptor } from '@connectrpc/connect';
import { createConnectTransport } from '@connectrpc/connect-node';
import { AuthService, MediaService, MessageService } from '@qqbridge/protocol';
import sharp from 'sharp';

const baseUrl = process.env.QQBRIDGE_URL ?? 'http://127.0.0.1:8080';

async function login(): Promise<string> {
  const username = process.env.QQBRIDGE_USER ?? 'owner';
  const password = process.env.QQBRIDGE_PASSWORD;
  if (!password) throw new Error('QQBRIDGE_PASSWORD is required');
  const auth = createClient(AuthService, createConnectTransport({ baseUrl, httpVersion: '1.1' }));
  const res = await auth.login({ username, password, deviceName: 'api-smoke', platform: 'cli' });
  return res.token;
}

function clients(token: string) {
  const bearer: Interceptor = (next) => async (req) => {
    req.header.set('authorization', `Bearer ${token}`);
    return next(req);
  };
  const transport = createConnectTransport({ baseUrl, httpVersion: '1.1', interceptors: [bearer] });
  return { messages: createClient(MessageService, transport), media: createClient(MediaService, transport) };
}

const randomId = () => BigInt(Date.now()) * 1000n + BigInt(randomInt(1000));

async function main() {
  const [command, ...args] = process.argv.slice(2);
  const token = await login();
  const { messages, media } = clients(token);
  switch (command) {
    case 'send-text': {
      const [chatId, text, replyTo] = args;
      const res = await messages.sendMessage({
        chatId: BigInt(chatId!),
        clientRandomId: randomId(),
        segments: [{ kind: { case: 'text', value: text! } }],
        replyToSeq: replyTo ? BigInt(replyTo) : 0n,
      });
      console.log(JSON.stringify({ clientRandomId: String(res.entry?.clientRandomId), state: res.entry?.state }));
      return;
    }
    case 'send-image': {
      const [chatId] = args;
      const color = { r: randomInt(256), g: randomInt(256), b: randomInt(256) };
      const png = await sharp({ create: { width: 96, height: 96, channels: 3, background: color } }).png().toBuffer();
      const sha256 = createHash('sha256').update(png).digest('hex');
      const prepared = await media.prepareUpload({ sha256, size: BigInt(png.length), mime: 'image/png', name: 'test.png' });
      if (!prepared.exists) {
        const offset = Number(prepared.offset);
        const res = await fetch(baseUrl + prepared.uploadUrl, {
          method: 'PATCH',
          headers: {
            authorization: `Bearer ${token}`,
            'tus-resumable': '1.0.0',
            'upload-offset': String(offset),
            'content-type': 'application/offset+octet-stream',
          },
          body: png.subarray(offset),
        });
        if (res.status !== 204) throw new Error(`upload failed: HTTP ${res.status}`);
      }
      const res = await messages.sendMessage({
        chatId: BigInt(chatId!),
        clientRandomId: randomId(),
        segments: [{ kind: { case: 'image', value: { sha256, name: '', durationSec: 0, sticker: false, summary: '' } } }],
        replyToSeq: 0n,
      });
      console.log(
        JSON.stringify({
          clientRandomId: String(res.entry?.clientRandomId),
          state: res.entry?.state,
          sha256,
          md5: createHash('md5').update(png).digest('hex'),
          uploaded: !prepared.exists,
        }),
      );
      return;
    }
    case 'recall': {
      const [chatId, seq] = args;
      await messages.recallMessage({ chatId: BigInt(chatId!), seq: BigInt(seq!) });
      console.log(JSON.stringify({ recalled: true }));
      return;
    }
    case 'search': {
      const res = await messages.searchMessages({ query: args.join(' '), limit: 10 });
      for (const m of res.messages) console.log(`${m.chatId}/${m.seq} ${m.text.slice(0, 60)}`);
      return;
    }
    default:
      throw new Error('commands: send-text | send-image | recall | search');
  }
}

main().catch((error: unknown) => {
  if (error instanceof ConnectError) console.error(`${Code[error.code]}: ${error.rawMessage}`);
  else console.error(error);
  process.exit(1);
});
