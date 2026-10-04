// vitest 全局准备：用 Docker 起一个真实的 LiveKit 服务端（固定端口，节点 IP 为 127.0.0.1）。
// 没有 Docker 时提供空地址，集成测试会自动跳过。
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { TestProject } from 'vitest/node';

export const LIVEKIT_IMAGE = 'livekit/livekit-server:v1.13.7';
export const LIVEKIT_KEY = 'testkey';
export const LIVEKIT_SECRET = 'testsecret-testsecret-testsecret-0123456789';
const NAME = 'qqbridge-livekit-test';
const HTTP = 17880;
const TCP = 17881;
const UDP = 17882;

declare module 'vitest' {
  export interface ProvidedContext {
    livekitUrl: string;
  }
}

export default async function setup(project: TestProject) {
  try {
    execFileSync('docker', ['info'], { stdio: 'ignore' });
  } catch {
    project.provide('livekitUrl', '');
    return;
  }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'qqbridge-livekit-'));
  fs.writeFileSync(
    path.join(dir, 'livekit.yaml'),
    [
      `port: ${HTTP}`,
      'bind_addresses: ["0.0.0.0"]',
      'rtc:',
      `  tcp_port: ${TCP}`,
      `  udp_port: ${UDP}`,
      '  use_external_ip: false',
      '  node_ip: 127.0.0.1',
      'keys:',
      `  ${LIVEKIT_KEY}: ${LIVEKIT_SECRET}`,
      'logging:',
      '  level: warn',
      '',
    ].join('\n'),
  );
  try {
    execFileSync('docker', ['rm', '-f', NAME], { stdio: 'ignore' });
  } catch {
    // 不存在就算了
  }
  execFileSync('docker', [
    'run',
    '-d',
    '--rm',
    '--name',
    NAME,
    '-p',
    `${HTTP}:${HTTP}`,
    '-p',
    `${TCP}:${TCP}`,
    '-p',
    `${UDP}:${UDP}/udp`,
    '-v',
    `${dir}/livekit.yaml:/etc/livekit.yaml:ro`,
    LIVEKIT_IMAGE,
    '--config',
    '/etc/livekit.yaml',
  ]);
  for (let i = 0; i < 80; i++) {
    try {
      if ((await fetch(`http://127.0.0.1:${HTTP}`)).ok) break;
    } catch {
      // 还没起来
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  project.provide('livekitUrl', `ws://127.0.0.1:${HTTP}`);

  return () => {
    try {
      execFileSync('docker', ['rm', '-f', NAME], { stdio: 'ignore' });
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  };
}
