#!/usr/bin/env bash
set -euo pipefail

platform="${MAESTRO_PLATFORM:-android}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID="org.tzap.zmanager.mobile"

if ! command -v maestro >/dev/null 2>&1; then
  echo "Maestro CLI is required for cancellation verification." >&2
  exit 1
fi

case "$platform" in
  android)
    command -v adb >/dev/null 2>&1 || { echo "adb is required." >&2; exit 1; }
    adb wait-for-device
    adb shell "run-as $APP_ID sh -c 'rm -rf files/Extracted'"
    maestro --platform android test "$ROOT_DIR/maestro/android/extraction-cancellation.yaml"
    sleep 2
    count="$(adb shell "run-as $APP_ID sh -c 'if [ -d files/Extracted ]; then find files/Extracted -type f -print; fi'" | wc -l | tr -d '[:space:]')"
    [ "$count" = 0 ] || { echo "Cancellation left $count final Android files." >&2; exit 1; }
    ;;
  ios)
    command -v xcrun >/dev/null 2>&1 || { echo "xcrun is required." >&2; exit 1; }
    container="$(xcrun simctl get_app_container booted "$APP_ID" data)"
    rm -rf "$container/Library/Application Support/ZManagerMobile/Extracted"
    xcrun simctl terminate booted "$APP_ID" >/dev/null 2>&1 || true
    MAESTRO_DRIVER_STARTUP_TIMEOUT="${MAESTRO_DRIVER_STARTUP_TIMEOUT:-120000}" \
      maestro --platform ios test "$ROOT_DIR/maestro/ios/extraction-cancellation.yaml"
    sleep 2
    extracted_root="$container/Library/Application Support/ZManagerMobile/Extracted"
    if [[ -d "$extracted_root" ]]; then
      count="$(find "$extracted_root" -type f -print | wc -l | tr -d '[:space:]')"
    else
      count=0
    fi
    [ "$count" = 0 ] || { echo "Cancellation left $count final iOS files." >&2; exit 1; }
    ;;
  *)
    echo "Usage: MAESTRO_PLATFORM=android|ios $0" >&2
    exit 2
    ;;
esac

echo "${platform} deterministic cancellation left no final destination files."
