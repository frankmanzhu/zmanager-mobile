#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR/ios/ZManagerMobile"

xcodebuild \
  -project ZManagerMobile.xcodeproj \
  -scheme ZManagerMobile \
  -destination 'generic/platform=iOS Simulator' \
  build
