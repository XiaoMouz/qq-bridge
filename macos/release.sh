#!/bin/bash
# macOS 版发布：归档 → 用 Developer ID 签名并提交 Apple 公证 → 等公证完成取回已钉票据的 app → 打 DMG。
#
#   ./macos/release.sh                 版本号取 macos/BetterChat/project.yml 的 MARKETING_VERSION / CURRENT_PROJECT_VERSION
#   RELEASE_DIR=/path ./macos/release.sh   产物目录（默认 macos/.release）
#   NOTARY_TIMEOUT=3600                等公证的最长秒数（默认 3600）
#   ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID
#                                      App Store Connect API 密钥（.p8 路径、密钥 ID、Issuer ID；Admin 角色）。
#                                      CI 用：xcodebuild 拿它走云端 Developer ID 证书签名、提交公证，DMG 也用它公证。
#   NOTARY_PROFILE=xxx                 本机可选：notarytool 的钥匙串凭据名，设了就把 DMG 也公证并钉票据
#
# 没给 API 密钥时，签名和公证走本机 Xcode 里登录的开发者账号（团队 L7V7ULL3VT 的云端 Developer ID 证书），
# 和 Organizer 的「直接分发」一样，本机不需要装 Developer ID 证书。
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mac="$root/macos"
spec="$mac/BetterChat/project.yml"
project="$mac/BetterChat/BetterChatMac.xcodeproj"
team="L7V7ULL3VT"

version=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' "$spec" | head -1)
build=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' "$spec" | head -1)
[ -n "$version" ] && [ -n "$build" ] || { echo "读不到版本号：$spec" >&2; exit 1; }

out="${RELEASE_DIR:-$mac/.release}/BetterChat-$version-$build"
archive="$out/BetterChatMac.xcarchive"
dmg="$out/BetterChat-Mac-$version-$build.dmg"
log="$out/logs"
rm -rf "$out"
mkdir -p "$log"

auth=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
  auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

step() { printf '\n==> %s\n' "$*"; }
restore() { git -C "$root" checkout -- ios/QQBridgeKit/Package.resolved 2>/dev/null || true; }
trap restore EXIT

step "BetterChat for Mac $version ($build) → $out"

step "生成工程、归档（Release）"
xcodegen generate --spec "$spec" >"$log/xcodegen.log"
xcodebuild -project "$project" -scheme BetterChatMac -configuration Release \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  -archivePath "$archive" -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} archive >"$log/archive.log" 2>&1 \
  || { tail -30 "$log/archive.log"; echo "归档失败，完整日志：$log/archive.log" >&2; exit 1; }

step "用 Developer ID 签名并提交公证"
opts="$out/ExportOptions.plist"
cat >"$opts" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$team</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$opts" \
  -exportPath "$out/submitted" -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} >"$log/submit.log" 2>&1 \
  || { tail -30 "$log/submit.log"; echo "提交公证失败，完整日志：$log/submit.log" >&2; exit 1; }

step "等 Apple 公证（每 30 秒查一次，最长 ${NOTARY_TIMEOUT:-3600} 秒）"
deadline=$(( $(date +%s) + ${NOTARY_TIMEOUT:-3600} ))
until xcodebuild -exportNotarizedApp -archivePath "$archive" -exportPath "$out/app" ${auth[@]+"${auth[@]}"} >"$log/notarized.log" 2>&1; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    tail -20 "$log/notarized.log"
    echo "公证超时（可稍后再跑：xcodebuild -exportNotarizedApp -archivePath \"$archive\" -exportPath \"$out/app\"）" >&2
    exit 1
  fi
  # 公证被拒（不是还在处理中）就不用再等了。
  if grep -qiE "invalid|rejected" "$log/notarized.log"; then
    tail -30 "$log/notarized.log"; echo "公证未通过，详见 $log/notarized.log" >&2; exit 1
  fi
  sleep 30
done
app="$out/app/BetterChat.app"
[ -d "$app" ] || app=$(find "$out/app" -maxdepth 1 -name '*.app' | head -1)

step "检查签名和公证票据"
codesign --verify --deep --strict "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

step "打 DMG"
stage="$out/dmg"
mkdir -p "$stage"
ditto "$app" "$stage/$(basename "$app")"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "BetterChat $version" -srcfolder "$stage" -ov -format UDZO "$dmg" >"$log/dmg.log"
rm -rf "$stage"

# DMG 本身也公证：下载后打开 DMG 时 Gatekeeper 不再提示（里面的 app 上面已经公证过）。
if [ -n "${ASC_KEY_PATH:-}" ]; then
  step "公证 DMG（notarytool，API 密钥）"
  xcrun notarytool submit "$dmg" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
  xcrun stapler staple "$dmg"
elif [ -n "${NOTARY_PROFILE:-}" ]; then
  step "公证 DMG（notarytool，凭据 $NOTARY_PROFILE）"
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
fi

step "完成"
shasum -a 256 "$dmg"
echo "$dmg"
# CI 用：把 DMG 路径交给后面的步骤。
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "dmg=$dmg" >>"$GITHUB_OUTPUT"; fi
