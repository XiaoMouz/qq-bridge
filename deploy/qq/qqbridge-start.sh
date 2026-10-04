#!/usr/bin/env bash
# 由官方 entrypoint 在完成反容器检测和用户准备后调用（以 root 运行），最后交给 supervisord。
set -euo pipefail

RUN_DIR=/run/qqbridge
install -d -m 0750 -o napcat -g napcat "$RUN_DIR" "$RUN_DIR/pulse"

# 控制 token：插件、AV Host、tools/qq.sh 共用；只在容器内可读。
if [ ! -s "$RUN_DIR/control.token" ]; then
  head -c 48 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$RUN_DIR/control.token"
fi
chown napcat:napcat "$RUN_DIR/control.token"
chmod 0600 "$RUN_DIR/control.token"

# 安装插件。开发时设 QQBRIDGE_PLUGIN_DEV=1，并把 packages/napcat-plugin-qqbridge/dist 挂载进来，改完只需重启容器。
PLUGIN_DIR=/app/napcat/plugins/napcat-plugin-qqbridge
if [ "${QQBRIDGE_PLUGIN_DEV:-0}" != "1" ]; then
  mkdir -p "$PLUGIN_DIR"
  cp -rf /app/qqbridge/plugin/napcat-plugin-qqbridge/. "$PLUGIN_DIR/"
fi

# 启用插件（NapCat 默认只启用内置插件）。以 napcat 用户写入：在 macOS 绑定挂载上 chown 不生效，
# 只有与宿主 uid 一致的 napcat 用户写出的文件，NapCat 之后才能继续改写。
chown -R napcat:napcat /app/napcat/plugins
gosu napcat bash -c '
  f=/app/napcat/config/plugins.json
  [ -s "$f" ] || echo "{}" > "$f"
  jq ". + {\"napcat-plugin-qqbridge\": true}" "$f" > "$f.tmp" && mv "$f.tmp" "$f" && chmod 0644 "$f"
'

# NapCat 4.18 起只加载官方白名单里的插件（为挡住发卡、博彩等黑灰产插件），第三方插件一律拒绝。
# 我们的插件只在本机自用：每次启动时把它加进本地这份 NapCat 的白名单（不对外发布修改版）。
# NapCat 由官方 entrypoint 在本脚本之前解压到 /app/napcat，所以放在这里而不是构建时。
# 幂等：已经加过就跳过；找不到白名单（NapCat 升级后写法变了）时只告警，不阻止 NapCat 启动。
NAPCAT_MJS=/app/napcat/napcat.mjs
if grep -q '"napcat-plugin-qqbridge"' "$NAPCAT_MJS"; then
  echo "[qqbridge] plugin whitelist: already contains napcat-plugin-qqbridge"
elif [ "$(grep -c '"napcat-plugin-qce"$' "$NAPCAT_MJS")" = 1 ]; then
  sed -i 's/"napcat-plugin-qce"$/"napcat-plugin-qce", "napcat-plugin-qqbridge"/' "$NAPCAT_MJS"
  echo "[qqbridge] plugin whitelist: added napcat-plugin-qqbridge"
else
  echo "[qqbridge] WARNING: NapCat plugin whitelist not found, napcat-plugin-qqbridge may be rejected" >&2
fi

exec /usr/bin/supervisord -n -c /etc/qqbridge/supervisord.conf
