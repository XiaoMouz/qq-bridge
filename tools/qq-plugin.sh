#!/bin/sh
# 不重建容器、不重新登录 QQ，就能更新插件和开关通话桥。
#   sh tools/qq-plugin.sh deploy        构建插件 → 拷进容器（含 AV Host 启动脚本）→ 重载插件
#   sh tools/qq-plugin.sh reload        只重载插件（经 NapCat WebUI 的插件启停接口）
#   sh tools/qq-plugin.sh calls on|off  改开关文件里的 QQBRIDGE_CALLS 并生效
#   sh tools/qq-plugin.sh set KEY VALUE 改开关文件里的其他开关（QQBRIDGE_CALL_AUTO_ACCEPT 等）后重载
# 开关文件：deploy/data/napcat-config/qqbridge.env（容器里是 /app/napcat/config/qqbridge.env），覆盖同名环境变量。
# 拷进容器的文件在容器重启后仍在；重建容器时以镜像为准，所以改完也要记得重新构建镜像。
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
CONTAINER=${QQ_CONTAINER:-qqbridge-qq}
PLUGIN_ID=napcat-plugin-qqbridge
OVERRIDES="$REPO/deploy/data/napcat-config/qqbridge.env"
WEBUI=http://127.0.0.1:6099/api

webui_token() {
  sed -n 's/^NAPCAT_WEBUI_TOKEN=//p' "$REPO/deploy/.env" | tail -n1
}

# WebUI 登录：口令的 sha256(token + ".napcat") 换一个 Credential。
credential() {
  hash=$(printf '%s.napcat' "$(webui_token)" | shasum -a 256 | cut -d' ' -f1)
  curl -fsS -X POST "$WEBUI/auth/login" -H 'content-type: application/json' -d "{\"hash\":\"$hash\"}" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); c=(d.get("data") or {}).get("Credential"); print(c) if c else sys.exit("webui login failed: %s" % d.get("message"))'
}

set_status() {
  curl -fsS -X POST "$WEBUI/Plugin/SetStatus" -H "authorization: Bearer $1" -H 'content-type: application/json' \
    -d "{\"id\":\"$PLUGIN_ID\",\"enable\":$2}" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("code")==0 else "SetStatus failed: %s" % d.get("message"))'
}

reload() {
  cred=$(credential)
  set_status "$cred" false
  set_status "$cred" true
  echo "plugin reloaded"
}

set_override() {
  mkdir -p "$(dirname "$OVERRIDES")"
  touch "$OVERRIDES"
  grep -v "^[[:space:]]*$1[[:space:]]*=" "$OVERRIDES" >"$OVERRIDES.tmp" || true
  echo "$1=$2" >>"$OVERRIDES.tmp"
  mv "$OVERRIDES.tmp" "$OVERRIDES"
}

case "${1:-}" in
  deploy)
    pnpm --dir "$REPO" --filter "$PLUGIN_ID" build
    docker cp "$REPO/packages/$PLUGIN_ID/dist/." "$CONTAINER:/app/napcat/plugins/$PLUGIN_ID/"
    docker cp "$REPO/packages/$PLUGIN_ID/dist/." "$CONTAINER:/app/qqbridge/plugin/$PLUGIN_ID/"
    docker cp "$REPO/deploy/qq/run-avhost.sh" "$CONTAINER:/app/qqbridge/run-avhost.sh"
    docker exec "$CONTAINER" chown -R napcat:napcat "/app/napcat/plugins/$PLUGIN_ID"
    reload
    ;;
  reload)
    reload
    ;;
  calls)
    case "${2:-}" in
      on) set_override QQBRIDGE_CALLS 1 ;;
      off) set_override QQBRIDGE_CALLS 0 ;;
      *) echo "usage: $0 calls on|off" >&2; exit 2 ;;
    esac
    reload
    # 重启 AV Host，让它按新开关启动或退回空转（旧进程可能还是旧版启动脚本，不会自己看开关文件）。
    docker exec "$CONTAINER" supervisorctl -c /etc/qqbridge/supervisord.conf restart avhost
    echo "calls $2"
    ;;
  set)
    [ $# -eq 3 ] || { echo "usage: $0 set KEY VALUE" >&2; exit 2; }
    set_override "$2" "$3"
    reload
    ;;
  *)
    sed -n '2,8p' "$0"
    exit 2
    ;;
esac
