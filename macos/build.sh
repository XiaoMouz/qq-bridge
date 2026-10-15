#!/bin/sh
set -eu
macos_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Catalyst keychain access requires a provisioned developer signature.
# Keep unsigned builds available for compile-only CI validation.
signing=${MACOS_SIGNING:-unsigned}
if [ "${MACOS_ADHOC_SIGN:-0}" = "1" ]; then signing=adhoc; fi
case "$signing" in
  development) set -- -allowProvisioningUpdates CODE_SIGNING_ALLOWED=YES "$@" ;;
  unsigned|adhoc) set -- CODE_SIGNING_ALLOWED=NO "$@" ;;
  *) echo "MACOS_SIGNING must be unsigned, adhoc, or development" >&2; exit 2 ;;
esac
xcodegen generate --spec "$macos_root/BetterChat/project.yml"
xcodebuild \
  -project "$macos_root/BetterChat/BetterChatMac.xcodeproj" \
  -scheme BetterChatMac \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$macos_root/.build-app" \
  build "$@"
if [ "$signing" = "adhoc" ]; then
  # UI preview only: Catalyst keychain login and APNs require provisioning.
  codesign --force --deep --sign - "$macos_root/.build-app/Build/Products/Debug-maccatalyst/BetterChat.app"
fi
