#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/zmanager-paths.sh"
ZMANAGER_DIR="$($ROOT_DIR/scripts/resolve-zmanager-source.sh)"
export ZMANAGER_DIR
export ZMANAGER_TZAP_PROFILE="${ZMANAGER_TZAP_PROFILE:-offline}"

"$ZMANAGER_DIR/scripts/build-ios-rust.sh"
mkdir -p "$ROOT_DIR/ios/ZManagerMobile/build/rust"
cp "$ZMANAGER_DIR/dist/ios/libzmanager_ffi_sim.a" \
  "$ROOT_DIR/ios/ZManagerMobile/build/rust/libzmanager_ffi_sim.a"
echo "Built the iOS Rust bridge from zmanager $ZMANAGER_COMMIT" >&2
