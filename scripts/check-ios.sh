#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT_DIR/scripts/generate-maestro-fixtures.sh"
cd "$ROOT_DIR/ios/ZManagerMobile"

xcodebuild \
  -project ZManagerMobile.xcodeproj \
  -scheme ZManagerMobile \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build
