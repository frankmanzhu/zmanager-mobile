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

# File-size guard: ContentView.swift once held 100+ top-level types across
# 6,685 lines, and ArchiveImportModel.swift was a 1,374-line god object with
# 31 @Published properties and 67 methods (docs/mobile-code-health-
# remediation-plan.md, Tracks 6 and 7). Both are now split; keep them split.
IOS_SIZE_GUARD_MAX_LINES=1500
IOS_SIZE_GUARD_EXCEPTIONS=()
ios_size_guard_failed=0
while IFS= read -r -d '' swift_file; do
  base="$(basename "$swift_file")"
  skip=0
  for exception in "${IOS_SIZE_GUARD_EXCEPTIONS[@]}"; do
    [[ "$base" == "$exception" ]] && skip=1
  done
  [[ "$skip" == 1 ]] && continue
  line_count="$(wc -l < "$swift_file")"
  if (( line_count > IOS_SIZE_GUARD_MAX_LINES )); then
    echo "iOS source file exceeds the ${IOS_SIZE_GUARD_MAX_LINES}-line size guard ($line_count lines): $swift_file" >&2
    ios_size_guard_failed=1
  fi
done < <(find "$ROOT_DIR/ios/ZManagerMobile/ZManagerMobile" -name '*.swift' -not -path '*/Bridge/Generated/*' -print0)
if [[ "$ios_size_guard_failed" == 1 ]]; then
  echo "See Track 6 in docs/mobile-code-health-remediation-plan.md." >&2
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
