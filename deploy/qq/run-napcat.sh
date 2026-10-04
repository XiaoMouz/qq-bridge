#!/usr/bin/env bash
# QQ 主进程（加载 NapCat 和我们的插件）。与官方镜像的启动方式一致，只是声音接到隔离的 PulseAudio。
set -euo pipefail
export HOME=/app USER=napcat DISPLAY=:1 FFMPEG_PATH=/usr/bin/ffmpeg
export PULSE_SERVER=unix:/run/qqbridge/pulse/native
unset QQBRIDGE_AV_HOST

cd /app/napcat
args=(--no-sandbox)
if [ -n "${ACCOUNT:-}" ]; then
  args+=(-q "$ACCOUNT")
fi
exec /opt/QQ/qq "${args[@]}"
