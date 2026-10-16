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
#   DEVELOPER_ID_PROFILE=path          Developer ID 描述文件（.provisionprofile）。给了就手动签名导出：
#                                      钥匙串里要有对应的 Developer ID Application 证书（含私钥）。
#                                      2026-10-16 实测：API 密钥（即使 Admin）不能用云端管理的 Developer ID 证书，
#                                      也就没法自动生成 Developer ID 描述文件；CI 必须带证书 + 这个描述文件。
#
# 自动更新（Sparkle，见 MacUpdater.swift）：
#   SPARKLE_FEED_URL / SPARKLE_PUBLIC_KEY   写进 App 的 Info.plist（更新源、EdDSA 公钥）；不给就打出不会自动更新的包
#   SPARKLE_ED_KEY                          EdDSA 私钥（generate_keys -x 导出的那一行），给了就签名 DMG 并生成 appcast.xml
#   SPARKLE_DOWNLOAD_BASE                   更新目录的公开地址（appcast 里的下载链接 = 它 + /latest.dmg）
#   RELEASE_NOTES                           可选：这一版的更新说明（纯文本，Sparkle 弹窗里显示）
#   R2_ACCOUNT_ID / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_BUCKET / R2_PATH
#                                           给了就把 latest.dmg 和 appcast.xml 传到 Cloudflare R2（aws cli，S3 兼容接口）。
#                                           更新桶多个项目共用，按「项目/设备/架构」分目录、每个目录只放最新一份，
#                                           例如 R2_PATH=betterchat/macos/arm64（以后别的端换了打包方式，同目录下换后缀即可）。
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

sparkle=()
[ -n "${SPARKLE_FEED_URL:-}" ] && sparkle+=("SPARKLE_FEED_URL=$SPARKLE_FEED_URL")
[ -n "${SPARKLE_PUBLIC_KEY:-}" ] && sparkle+=("SPARKLE_PUBLIC_KEY=$SPARKLE_PUBLIC_KEY")

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

step "BetterChat for Mac $version ($build) → $out"

step "生成工程、归档（Release）"
xcodegen generate --spec "$spec" >"$log/xcodegen.log"
xcodebuild -project "$project" -scheme BetterChatMac -configuration Release \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  -archivePath "$archive" -clonedSourcePackagesDirPath "$out/packages" \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} ${sparkle[@]+"${sparkle[@]}"} archive >"$log/archive.log" 2>&1 \
  || { tail -30 "$log/archive.log"; echo "归档失败，完整日志：$log/archive.log" >&2; exit 1; }

step "用 Developer ID 签名并提交公证"
opts="$out/ExportOptions.plist"
signing="<key>signingStyle</key><string>automatic</string>"
if [ -n "${DEVELOPER_ID_PROFILE:-}" ]; then
  # 装进 Xcode 找描述文件的目录，按名字指给导出用。
  profile_plist="$out/profile.plist"
  security cms -D -i "$DEVELOPER_ID_PROFILE" >"$profile_plist"
  profile_uuid=$(/usr/libexec/PlistBuddy -c "Print :UUID" "$profile_plist")
  profile_name=$(/usr/libexec/PlistBuddy -c "Print :Name" "$profile_plist")
  profiles_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  mkdir -p "$profiles_dir"
  cp "$DEVELOPER_ID_PROFILE" "$profiles_dir/$profile_uuid.provisionprofile"
  echo "描述文件：${profile_name}（${profile_uuid}）"
  signing="<key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>provisioningProfiles</key>
  <dict><key>com.xiaomouz.betterchat.mac</key><string>$profile_name</string></dict>"
fi
cat >"$opts" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>upload</string>
  $signing
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
  step "公证 DMG（notarytool，凭据 ${NOTARY_PROFILE}）"
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
fi

# Sparkle：签名要在 DMG 定稿（公证、钉票据）之后，钉票据会改动文件。
if [ -n "${SPARKLE_ED_KEY:-}" ]; then
  step "Sparkle 签名、生成 appcast.xml"
  sign_update=$(find "$out/packages/artifacts" -path '*/bin/sign_update' -type f | head -1)
  [ -n "$sign_update" ] && [ -x "$sign_update" ] || { echo "找不到 Sparkle 的 sign_update" >&2; exit 1; }
  # 输出形如：sparkle:edSignature="…" length="…"
  signature=$(printf '%s' "$SPARKLE_ED_KEY" | "$sign_update" --ed-key-file - "$dmg")
  # 只保留 latest.dmg：链接带上构建号，Cloudflare 边缘缓存不会把旧包当新包发出去（签名就对不上了）。
  url="${SPARKLE_DOWNLOAD_BASE:?设了 SPARKLE_ED_KEY 也要设 SPARKLE_DOWNLOAD_BASE}/latest.dmg?build=$build"
  notes=$(printf '%s' "${RELEASE_NOTES:-BetterChat for Mac $version}" | sed 's/]]>/]]]]><![CDATA[>/g')
  {
    echo '<?xml version="1.0" encoding="utf-8"?>'
    echo '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
    echo '  <channel>'
    echo '    <title>BetterChat for Mac</title>'
    echo '    <item>'
    echo "      <title>$version</title>"
    echo "      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>"
    echo "      <sparkle:version>$build</sparkle:version>"
    echo "      <sparkle:shortVersionString>$version</sparkle:shortVersionString>"
    echo '      <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>'
    echo "      <description><![CDATA[<pre>$notes</pre>]]></description>"
    echo "      <enclosure url=\"$url\" type=\"application/octet-stream\" $signature />"
    echo '    </item>'
    echo '  </channel>'
    echo '</rss>'
  } >"$out/appcast.xml"
fi

if [ -n "${R2_BUCKET:-}" ]; then
  r2_path="${R2_PATH:?设了 R2_BUCKET 也要设 R2_PATH（项目/设备/架构，例如 betterchat/macos/arm64）}"
  step "上传 Cloudflare R2（${r2_path}/latest.dmg、appcast.xml）"
  export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" AWS_DEFAULT_REGION=auto
  endpoint="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com"
  dest="s3://$R2_BUCKET/$r2_path"
  # 只放最新一份；带版本号的 DMG 在 GitHub Release 里。
  aws s3 cp "$dmg" "$dest/latest.dmg" --endpoint-url "$endpoint" --content-type application/x-apple-diskimage \
    --cache-control no-cache --content-disposition "attachment; filename=\"$(basename "$dmg")\""
  # appcast 最后传：DMG 到位了才让已装的 App 看到新版本。
  if [ -f "$out/appcast.xml" ]; then
    aws s3 cp "$out/appcast.xml" "$dest/appcast.xml" --endpoint-url "$endpoint" --content-type application/xml --cache-control no-cache
  fi
fi

step "完成"
shasum -a 256 "$dmg"
echo "$dmg"
# CI 用：把 DMG 路径交给后面的步骤。
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "dmg=$dmg" >>"$GITHUB_OUTPUT"; fi
