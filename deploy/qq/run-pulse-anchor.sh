#!/usr/bin/env bash
# 把两个虚拟声卡"钉"在 10ms 低延迟上。
# 原因：PulseAudio 的 null-sink 在没人要求低延迟时按 2 秒为一块渲染，新连上的流不一定能及时让它缩小，
# 实测通话路径会因此时快时慢地多出 1 秒以上的延迟。各挂一个常驻的 10ms 录音流（数据直接丢弃）后，
# 下行稳态延迟稳定在约 20–30ms，上行约 40ms。
set -euo pipefail
export HOME=/app
export PULSE_SERVER=unix:/run/qqbridge/pulse/native

for _ in $(seq 1 40); do
  pactl info >/dev/null 2>&1 && break
  sleep 0.25
done

anchor() {
  parec --device="$1" --format=s16le --rate=48000 --channels=1 --latency-msec=10 --raw > /dev/null
}

anchor qq_speaker.monitor &
anchor qq_mic.monitor &
# 任意一个退出就整体退出，交给 supervisord 重启。
wait -n
exit 1
