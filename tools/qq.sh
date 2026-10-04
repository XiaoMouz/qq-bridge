#!/usr/bin/env bash
# 调试 QQ 容器的小工具。插件和 AV Host 的控制接口只监听容器内回环地址，所以都经 docker exec 访问。
#
#   tools/qq.sh status            插件与通话桥状态
#   tools/qq.sh call              当前通话
#   tools/qq.sh accept            接听当前来电
#   tools/qq.sh avhost            AV Host 状态（通话引擎是否加载、方法列表）
#   tools/qq.sh get <path>        对插件发任意 GET，例如 '/x/recent_contacts?count=20'
#   tools/qq.sh post <path> <json>
#   tools/qq.sh record [秒]       录下通话对方的声音（qq_speaker.monitor）到 fixtures/raw/
#   tools/qq.sh tone [秒]         往 QQ 麦克风（qq_mic）播放 440Hz 测试音
#   tools/qq.sh pulse             查看虚拟声卡状态
#   tools/qq.sh logs              跟随容器日志
set -euo pipefail

CONTAINER=${QQBRIDGE_CONTAINER:-qqbridge-qq}
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
PULSE='PULSE_SERVER=unix:/run/qqbridge/pulse/native'

in_container() {
  docker exec -u napcat "$CONTAINER" bash -c "$1"
}

curl_plugin() {
  local method=$1 path=$2 body=${3:-}
  local port=${4:-6110}
  local cmd="curl -sS -X $method -H \"Authorization: Bearer \$(cat /run/qqbridge/control.token)\""
  if [ -n "$body" ]; then
    cmd+=" -H 'Content-Type: application/json' --data $(printf '%q' "$body")"
  fi
  cmd+=" 'http://127.0.0.1:${port}${path}'"
  in_container "$cmd"
  echo
}

case "${1:-help}" in
  status) curl_plugin GET /v1/status ;;
  call) curl_plugin GET /v1/calls/current ;;
  accept) curl_plugin POST /v1/calls/accept '{}' ;;
  avhost) curl_plugin GET /v1/status '' 6111 ;;
  get) curl_plugin GET "${2:?path required}" ;;
  post) curl_plugin POST "${2:?path required}" "${3:-{\}}" ;;
  record)
    secs=${2:-15}
    mkdir -p "$ROOT/fixtures/raw"
    out="$ROOT/fixtures/raw/speaker-$(date +%Y%m%d-%H%M%S).wav"
    in_container "$PULSE timeout $secs parec -d qq_speaker.monitor --format=s16le --rate=48000 --channels=2 --file-format=wav" > "$out" || true
    echo "saved $out"
    ;;
  tone)
    secs=${2:-10}
    in_container "ffmpeg -loglevel error -f lavfi -i sine=frequency=440:duration=$secs -f s16le -ar 48000 -ac 2 - | $PULSE pacat -d qq_mic --format=s16le --rate=48000 --channels=2"
    ;;
  pulse)
    in_container "$PULSE pactl info | sed -n -E '/^(Server Name|Default Sink|Default Source):/p'; $PULSE pactl list short sinks; $PULSE pactl list short sources"
    ;;
  logs) docker logs -f --tail 200 "$CONTAINER" ;;
  *)
    sed -n '2,15p' "$0"
    ;;
esac
