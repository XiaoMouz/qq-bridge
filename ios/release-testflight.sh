#!/bin/bash
# iOS 发 TestFlight：Release 归档 → App Store 签名并上传 App Store Connect（Apple 处理完自动出现在 TestFlight，内部测试员可装）。
#
#   ASC_KEY_PATH=… ASC_KEY_ID=… ASC_ISSUER_ID=… ./ios/release-testflight.sh
#
# 版本号取 ios/QQBridge/project.yml 的 MARKETING_VERSION / CURRENT_PROJECT_VERSION（规则见根目录 AGENTS.md：
# 发布升小版本、构建号 +1；同一版本下构建号必须比上次上传的大，否则 App Store Connect 拒收）。
# 签名和上传用 App Store Connect API 密钥（Admin 角色，和 macos/release.sh 同一把）；没给时走本机 Xcode 登录的账号
# （从命令行调用常报 No Accounts，这时用 Organizer 上传）。
# 产物在 ios/.release/BetterChat-<版本>-<构建号>/，日志在其中的 logs/。
#
# 新版本提示（App/AppUpdate.swift）：给了 R2_ACCOUNT_ID / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_BUCKET / R2_PATH
# 就在上传成功后写 latest.json（版本、构建号、RELEASE_NOTES、时间）到 R2，例如 R2_PATH=betterchat/ios/arm64。
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app="$root/ios/QQBridge"
spec="$app/project.yml"
team="L7V7ULL3VT"

version=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' "$spec" | head -1)
build=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' "$spec" | head -1)
[ -n "$version" ] && [ -n "$build" ] || { echo "读不到版本号：$spec" >&2; exit 1; }

out="${RELEASE_DIR:-$root/ios/.release}/BetterChat-$version-$build"
archive="$out/BetterChat.xcarchive"
log="$out/logs"
rm -rf "$out"
mkdir -p "$log"

auth=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
  auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

step() { printf '\n==> %s\n' "$*"; }
restore() { git -C "$root" checkout -- ios/QQBridgeKit/Package.resolved 2>/dev/null || true; }
# 正文在子进程里跑，结束后在这里清理并带着它的退出码退出。不用 trap EXIT：macOS 自带的 bash 3.2 里，
# set -u 报「变量未定义」时 EXIT trap 拿到的 $? 是 0，脚本出错也会返回 0（2026-10-16 CI 因此把失败的一步标成了成功）。
if [ -z "${RELEASE_CHILD:-}" ]; then
  status=0
  RELEASE_CHILD=1 "$BASH" "$0" "$@" || status=$?
  restore
  exit "$status"
fi

step "BetterChat iOS $version ($build) → TestFlight"

step "生成工程、归档（Release）"
(cd "$app" && xcodegen generate >"$log/xcodegen.log")
xcodebuild -project "$app/BetterChat.xcodeproj" -scheme BetterChat -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} archive >"$log/archive.log" 2>&1 \
  || { tail -30 "$log/archive.log"; echo "归档失败，完整日志：$log/archive.log" >&2; exit 1; }

step "签名并上传 App Store Connect"
opts="$out/ExportOptions.plist"
cat >"$opts" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$team</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$opts" -exportPath "$out/upload" \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} >"$log/upload.log" 2>&1 \
  || { tail -30 "$log/upload.log"; echo "上传失败，完整日志：$log/upload.log" >&2; exit 1; }

if [ -n "${R2_BUCKET:-}" ]; then
  r2_path="${R2_PATH:?设了 R2_BUCKET 也要设 R2_PATH（项目/设备/架构，例如 betterchat/ios/arm64）}"
  step "写新版本信息到 Cloudflare R2（${r2_path}/latest.json）"
  VERSION="$version" BUILD="$build" NOTES="${RELEASE_NOTES:-}" python3 - "$out/latest.json" <<'PY'
import json, os, sys, datetime
info = {"version": os.environ["VERSION"], "build": int(os.environ["BUILD"]),
        "notes": os.environ["NOTES"].strip(), "publishedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")}
json.dump(info, open(sys.argv[1], "w"), ensure_ascii=False)
PY
  export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" AWS_DEFAULT_REGION=auto
  aws s3 cp "$out/latest.json" "s3://$R2_BUCKET/$r2_path/latest.json" --endpoint-url "https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com" \
    --content-type "application/json; charset=utf-8" --cache-control no-cache
fi

step "完成：已上传 $version ($build)，Apple 处理完（通常十几分钟）会出现在 TestFlight"
