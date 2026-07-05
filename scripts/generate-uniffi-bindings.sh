#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UDL_FILE="$ROOT_DIR/rust/zmanager-mobile-core/uniffi/zmanager_mobile_core.udl"
CONFIG_FILE="$ROOT_DIR/rust/zmanager-mobile-core/uniffi/uniffi.toml"

ANDROID_JAVA_ROOT="$ROOT_DIR/android/app/src/main/java"
ANDROID_GENERATED_DIR="$ANDROID_JAVA_ROOT/org/tzap/zmanager/mobile/bridge/generated"
IOS_GENERATED_DIR="$ROOT_DIR/ios/ZManagerMobile/ZManagerMobile/Bridge/Generated"

rm -rf "$ANDROID_GENERATED_DIR" "$IOS_GENERATED_DIR"
mkdir -p "$ANDROID_GENERATED_DIR" "$IOS_GENERATED_DIR"

(
  cd "$ROOT_DIR/rust"
  cargo run -p zmanager-uniffi-bindgen -- generate \
    --language kotlin \
    --out-dir "$ANDROID_JAVA_ROOT" \
    --config "$CONFIG_FILE" \
    --no-format \
    "$UDL_FILE"
)

(
  cd "$ROOT_DIR/rust"
  cargo run -p zmanager-uniffi-bindgen -- generate \
    --language swift \
    --out-dir "$IOS_GENERATED_DIR" \
    --config "$CONFIG_FILE" \
    --no-format \
    "$UDL_FILE"
)
