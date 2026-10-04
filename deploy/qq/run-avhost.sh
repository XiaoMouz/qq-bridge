#!/usr/bin/env bash
# AV Host：用 QQ 自带的 Electron 起第二个进程，经 loadNapCat.js 分流到 /app/av-host/host.cjs。
set -euo pipefail
export HOME=/app USER=napcat DISPLAY=:1
export PULSE_SERVER=unix:/run/qqbridge/pulse/native
export QQBRIDGE_AV_HOST=1

# 通话桥总开关：环境变量 QQBRIDGE_CALLS，可被挂载卷上的开关文件覆盖（与插件读同一个文件）。
OVERRIDES=${QQBRIDGE_OVERRIDES_FILE:-/app/napcat/config/qqbridge.env}
calls_enabled() {
  local value=${QQBRIDGE_CALLS:-0} line
  if [ -f "$OVERRIDES" ]; then
    line=$(grep -E '^[[:space:]]*QQBRIDGE_CALLS[[:space:]]*=' "$OVERRIDES" | tail -n1 || true)
    [ -n "$line" ] && value=$(echo "${line#*=}" | tr -d '[:space:]')
  fi
  [ "$value" = "1" ] || [ "$value" = "true" ]
}

# 关闭时空转等待（不退出，supervisord 不会反复拉起）；开关文件改成 1 后几秒内自动启动。
if ! calls_enabled; then
  echo "[qqbridge] calls are off; AV Host waits for QQBRIDGE_CALLS=1 in $OVERRIDES"
  until calls_enabled; do sleep 5; done
  echo "[qqbridge] calls switched on"
fi

AVSDK=${QQBRIDGE_AVSDK_PATH:-/opt/QQ/resources/app/avsdk/libAVSDKPlugin.so}
if [ ! -f "$AVSDK" ]; then
  echo "[qqbridge] AVSDK not found at $AVSDK; call bridge stays disabled"
  exec sleep infinity
fi
avsdk_dir=$(dirname "$AVSDK")
export LD_LIBRARY_PATH="$avsdk_dir:$avsdk_dir/bugly${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# 等 PulseAudio 就绪，否则通话引擎可能拿不到默认设备。
for _ in $(seq 1 40); do
  pactl info >/dev/null 2>&1 && break
  sleep 0.25
done

profile=/app/.config/qqbridge-avhost
mkdir -p "$profile"
exec /opt/QQ/qq --no-sandbox --user-data-dir="$profile"
