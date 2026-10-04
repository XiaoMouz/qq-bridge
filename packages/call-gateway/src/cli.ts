// 通话网关命令行（在 call-gateway 容器里运行，PulseAudio 通过共享卷访问）：
//   pulse-selftest                 验证 QQ 容器里虚拟声卡的两条声音通路（不需要登录 QQ）
//   bridge --room <名字>           以"QQ 端"身份加入 LiveKit 房间，桥接 PulseAudio，Ctrl+C 结束
//   serve                          常驻：由服务端的 CallService 经控制接口指挥进出房间（见 serve.ts）
import { parseArgs } from 'node:util';
import { dispose } from '@livekit/rtc-node';
import { PulseCapture, PulsePlayback } from './audio-io.ts';
import { CallAudioBridge } from './bridge.ts';
import { measurePhoneRtt } from './phone-rtt.ts';
import { pulseSelftest } from './selftest.ts';
import { startGatewayServer } from './serve.ts';
import { mintRoomToken } from './token.ts';

const PULSE_SERVER = process.env.PULSE_SERVER || 'unix:/run/qqbridge/pulse/native';

async function main(argv: string[]): Promise<number> {
  const [command, ...rest] = argv;
  switch (command) {
    case 'pulse-selftest': {
      const result = await pulseSelftest({
        server: PULSE_SERVER,
        ...(process.env.CAPTURE_LATENCY_MS ? { captureLatencyMs: Number(process.env.CAPTURE_LATENCY_MS) } : {}),
        ...(process.env.PLAYBACK_LATENCY_MS ? { playbackLatencyMs: Number(process.env.PLAYBACK_LATENCY_MS) } : {}),
      });
      console.log(JSON.stringify(result, null, 2));
      return result.downlink.ok && result.uplink.ok ? 0 : 1;
    }
    case 'bridge': {
      const { values } = parseArgs({
        args: rest,
        options: {
          room: { type: 'string' },
          identity: { type: 'string', default: 'qq-gateway' },
          url: { type: 'string', default: process.env.LIVEKIT_URL },
          token: { type: 'string' },
        },
      });
      if (!values.url || !values.room) throw new Error('usage: bridge --room <name> [--url ws://...] [--token <jwt>]');
      const token =
        values.token ??
        (await mintRoomToken({
          apiKey: requireEnv('LIVEKIT_API_KEY'),
          apiSecret: requireEnv('LIVEKIT_API_SECRET'),
          room: values.room,
          identity: values.identity,
        }));
      const bridge = new CallAudioBridge({
        url: values.url,
        token,
        capture: new PulseCapture({ server: PULSE_SERVER }),
        playback: new PulsePlayback({ server: PULSE_SERVER }),
        onLog: (event, detail) => console.log(JSON.stringify({ event, ...detail })),
      });
      await bridge.start();
      console.log(JSON.stringify({ event: 'bridging', room: values.room }));
      const timer = setInterval(() => console.log(JSON.stringify({ event: 'stats', ...bridge.stats })), 5000);
      await new Promise<void>((resolve) => {
        process.once('SIGINT', resolve);
        process.once('SIGTERM', resolve);
      });
      clearInterval(timer);
      await bridge.stop();
      return 0;
    }
    case 'serve': {
      const server = await startGatewayServer({
        host: process.env.GATEWAY_HOST || '0.0.0.0',
        port: Number(process.env.GATEWAY_PORT || 6120),
        token: requireToken('CALL_GATEWAY_TOKEN'),
        livekitUrl: requireEnv('LIVEKIT_URL'),
        pulseServer: PULSE_SERVER,
        log: (event, detail) => console.log(JSON.stringify({ time: new Date().toISOString(), event, ...detail })),
      });
      console.log(JSON.stringify({ event: 'listening', address: server.address() }));
      await new Promise<void>((resolve) => {
        process.once('SIGINT', resolve);
        process.once('SIGTERM', resolve);
      });
      server.close();
      return 0;
    }
    case 'phone-rtt': {
      // 在 Mac 上扮演 iPhone：发出 660Hz + 每 2 秒一段 1500Hz 标记音，测标记音经整条链路回来的往返时延。
      // 需要 QQ 容器里临时加 Pulse 回环（qq_mic_source → qq_speaker），模拟 QQ 把对方的声音原样播出来。
      const { values } = parseArgs({
        args: rest,
        options: {
          url: { type: 'string', default: process.env.LIVEKIT_PUBLIC_URL },
          room: { type: 'string' },
          seconds: { type: 'string', default: '10' },
        },
      });
      if (!values.url || !values.room) throw new Error('usage: phone-rtt --url ws://<ip>:7880 --room <name> [--seconds 10]');
      const result = await measurePhoneRtt({
        url: values.url,
        room: values.room,
        seconds: Number(values.seconds),
        apiKey: requireEnv('LIVEKIT_API_KEY'),
        apiSecret: requireEnv('LIVEKIT_API_SECRET'),
      });
      console.log(JSON.stringify(result, null, 2));
      return result.rttMs.length > 0 ? 0 : 1;
    }
    default:
      console.error('usage: cli <pulse-selftest|bridge|serve|phone-rtt>');
      return 2;
  }
}

function requireToken(name: string): string {
  const value = requireEnv(name);
  if (Buffer.byteLength(value) < 32) throw new Error(`${name} must be at least 32 bytes`);
  return value;
}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

main(process.argv.slice(2))
  .then(async (code) => {
    await dispose();
    process.exit(code);
  })
  .catch(async (error) => {
    console.error(error instanceof Error ? error.message : error);
    await dispose().catch(() => undefined);
    process.exit(1);
  });
