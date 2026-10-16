#!/bin/bash
# 把签名证书（base64 后的 .p12）导入一个临时钥匙串，供 xcodebuild 使用；跑完由工作流删掉这个钥匙串。
#   .github/scripts/import-certs.sh <证书变量名> <密码变量名> [<证书变量名> <密码变量名> …]
# 变量名指向环境变量（工作流从 Secrets 传入），值不出现在命令行里。
#
# 为什么要导开发证书：归档时 Xcode 先用开发证书签名；全新的 CI 机器上没有，它就会用 API 密钥新建一张，
# 私钥随机器销毁，每跑一次多一张没用的证书（2026-10-16 三次运行留下了三张）。导入固定的一张，Xcode 就复用它。
set -euo pipefail

keychain="$RUNNER_TEMP/signing.keychain-db"
password=$(openssl rand -hex 16)
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 7200 "$keychain"
security unlock-keychain -p "$password" "$keychain"

while [ $# -ge 2 ]; do
  cert_var=$1 pass_var=$2
  shift 2
  value=${!cert_var:-}
  [ -n "$value" ] || { echo "缺少 Secret $cert_var" >&2; exit 1; }
  file="$RUNNER_TEMP/$cert_var.p12"
  printf '%s' "$value" | base64 --decode >"$file"
  security import "$file" -k "$keychain" -P "${!pass_var:-}" -A -t cert -f pkcs12
  rm -f "$file"
done

security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
# 放在搜索列表最前面，xcodebuild 和 codesign 都能找到。
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
security find-identity -v -p codesigning "$keychain"
