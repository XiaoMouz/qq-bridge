#!/usr/bin/env bash
# 隔离的 PulseAudio：只加载 /etc/qqbridge/pulse.pa 里的虚拟设备，不碰任何真实声卡。
set -euo pipefail
export HOME=/app
export PULSE_RUNTIME_PATH=/run/qqbridge/pulse
exec /usr/bin/pulseaudio \
  --daemonize=no \
  --system=no \
  --exit-idle-time=-1 \
  --disallow-exit \
  --disable-shm=yes \
  -n --file=/etc/qqbridge/pulse.pa \
  --log-target=stderr
