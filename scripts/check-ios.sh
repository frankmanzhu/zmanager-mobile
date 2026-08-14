#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/ios/ZManagerMobile/ZManagerMobile/Info.plist"
SHARE_INFO_PLIST="$ROOT_DIR/ios/ZManagerMobile/ZManagerMobileShareExtension/Info.plist"

restore_generated_fixtures() {
  git -C "$ROOT_DIR" restore --source=HEAD -- android/app/src/debug/assets ios/ZManagerMobile/ZManagerMobile/MaestroFixtures
}

trap restore_generated_fixtures EXIT
if ! /usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$INFO_PLIST" 2>/dev/null | grep -qx 'zmanager'; then
  echo "iOS automation URL scheme zmanager is missing from Info.plist." >&2
  exit 1
fi
if ! /usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$SHARE_INFO_PLIST" 2>/dev/null | grep -qx 'com.apple.share-services'; then
  echo "iOS Share Extension declaration is missing from its Info.plist." >&2
  exit 1
fi
"$ROOT_DIR/scripts/generate-maestro-fixtures.sh"
cd "$ROOT_DIR/ios/ZManagerMobile"

xcodebuild \
  -project ZManagerMobile.xcodeproj \
  -scheme ZManagerMobile \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project ZManagerMobile.xcodeproj \
  -target ZManagerMobileShareExtension \
  -configuration Debug \
  -sdk iphonesimulator \
  CODE_SIGNING_ALLOWED=NO \
  build
