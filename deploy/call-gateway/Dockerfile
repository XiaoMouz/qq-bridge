# 通话网关：Node + PulseAudio 客户端（parec / pacat）。与 QQ 容器共享 /run/qqbridge（PulseAudio socket）。
# 构建上下文是仓库根目录。@livekit/rtc-node 的原生绑定需要 glibc（不能用 alpine）。
FROM node:24-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends pulseaudio-utils ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && corepack enable

WORKDIR /app
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml tsconfig.base.json ./
# 复制所有包的 package.json，保证工作区结构与 lockfile 一致，再只安装网关需要的依赖。
COPY packages/av-host/package.json packages/av-host/
COPY packages/call-gateway/package.json packages/call-gateway/
COPY packages/domain/package.json packages/domain/
COPY packages/napcat-plugin-qqbridge/package.json packages/napcat-plugin-qqbridge/
COPY packages/protocol/package.json packages/protocol/
COPY packages/server/package.json packages/server/
RUN pnpm install --frozen-lockfile --filter @qqbridge/call-gateway...

COPY packages/call-gateway/ packages/call-gateway/

WORKDIR /app/packages/call-gateway
ENV PULSE_SERVER=unix:/run/qqbridge/pulse/native
ENTRYPOINT ["node", "--import", "tsx", "src/cli.ts"]
CMD ["pulse-selftest"]
