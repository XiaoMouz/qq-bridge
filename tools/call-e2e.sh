#!/usr/bin/env bash
# 通话链路端到端自测（不需要登录 QQ）：
#   假 iPhone（本机）⇄ LiveKit ⇄ 网关容器 ⇄ QQ 容器里的 PulseAudio（加临时回环，模拟 QQ 把对方的声音原样播出来）
# 测量标记音的往返时延；往返 / 2 ≈ 单向额外延迟（设计目标 < 250ms，见 docs/design.md 5.6）。
#
#   tools/call-e2e.sh            默认跑 12 秒
#   SECONDS_TO_RUN=30 tools/call-e2e.sh
#
# 需要：QQ 容器在运行（不必登录）、deploy/.env 里配好 LIVEKIT_API_KEY / LIVEKIT_API_SECRET。
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
PULSE='PULSE_SERVER=unix:/run/qqbridge/pulse/native'

detect_ip() {
  local ts=/Applications/Tailscale.app/Contents/MacOS/Tailscale
  if [ -x "$ts" ] && "$ts" ip -4 >/dev/null 2>&1; then "$ts" ip -4 | head -1; return; fi
  if command -v tailscale >/dev/null 2>&1 && tailscale ip -4 >/dev/null 2>&1; then tailscale ip -4 | head -1; return; fi
  ipconfig getifaddr en0 2>/dev/null || hostname -I | awk '{print $1}'
}

export LIVEKIT_NODE_IP=${LIVEKIT_NODE_IP:-$(detect_ip)}
# OrbStack / Docker Desktop 上只能绑 0.0.0.0 或 127.0.0.1（引擎在虚拟机里，没有宿主机的 Tailscale IP）。
export LIVEKIT_BIND_IP=${LIVEKIT_BIND_IP:-0.0.0.0}

compose() {
  docker compose -f "$ROOT/deploy/docker-compose.yml" --env-file "$ROOT/deploy/.env" --profile calls "$@"
}

MOD=''
cleanup() {
  docker rm -f qqbridge-gw-e2e >/dev/null 2>&1 || true
  if [ -n "$MOD" ]; then docker exec -u napcat qqbridge-qq bash -c "$PULSE pactl unload-module $MOD" || true; fi
  compose stop livekit >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[e2e] LiveKit 节点 IP：$LIVEKIT_NODE_IP"
compose up -d livekit >/dev/null
for _ in $(seq 1 60); do
  curl -s -o /dev/null --noproxy '*' "http://$LIVEKIT_NODE_IP:7880" && break
  sleep 0.5
done

MOD=$(docker exec -u napcat qqbridge-qq bash -c "$PULSE pactl load-module module-loopback source=qq_mic_source sink=qq_speaker latency_msec=20")
echo "[e2e] 已加载 Pulse 回环（模块 $MOD）"

docker rm -f qqbridge-gw-e2e >/dev/null 2>&1 || true
compose run -d --no-deps --name qqbridge-gw-e2e call-gateway bridge --room e2e >/dev/null
sleep 4

pnpm --silent --filter @qqbridge/call-gateway cli phone-rtt \
  --url "ws://$LIVEKIT_NODE_IP:7880" --room e2e --seconds "${SECONDS_TO_RUN:-12}" 2>&1 | grep -v '"level":20'
echo "[e2e] 网关统计：$(docker logs qqbridge-gw-e2e 2>&1 | grep '"stats"' | tail -1)"
