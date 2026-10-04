#!/bin/sh
# 把 qqbridge 服务端装成当前用户的 launchd 常驻服务：登录后自动启动，退出或崩溃后自动拉起。
#   sh deploy/launchd/install.sh            安装或更新并启动
#   sh deploy/launchd/install.sh uninstall  停止并移除
# 日志：~/Library/Logs/qqbridge/server.log（pino JSON）；重启服务：launchctl kickstart -k gui/$(id -u)/com.xiaomouz.qqbridge.server
set -eu

LABEL=com.xiaomouz.qqbridge.server
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
REPO=$(cd "$(dirname "$0")/../.." && pwd)
LOGS="$HOME/Library/Logs/qqbridge"
# Homebrew 的 opt 路径在 node 升级后不变。
NODE=${NODE:-/opt/homebrew/opt/node/bin/node}

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
if [ "${1:-}" = uninstall ]; then
  rm -f "$PLIST"
  echo "removed $LABEL"
  exit 0
fi

[ -x "$NODE" ] || { echo "node not found at $NODE (set NODE=...)" >&2; exit 1; }
mkdir -p "$LOGS" "$(dirname "$PLIST")"
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>WorkingDirectory</key><string>$REPO/packages/server</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE</string>
    <string>--env-file-if-exists=../../deploy/.env</string>
    <string>--import</string><string>tsx</string>
    <string>src/cli.ts</string><string>serve</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <!-- ffmpeg 在 Homebrew 下；launchd 默认 PATH 里没有 -->
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <!-- 开机时 OrbStack 里的 Postgres 可能还没起来：启动失败就隔 10 秒再试 -->
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOGS/server.log</string>
  <key>StandardErrorPath</key><string>$LOGS/server.log</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "installed $LABEL → $PLIST"
echo "logs: $LOGS/server.log"
