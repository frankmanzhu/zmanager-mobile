#!/usr/bin/env bash
set -euo pipefail

if ! command -v maestro >/dev/null 2>&1; then
  echo "Maestro CLI is required. Install it with: brew install mobile-dev-inc/tap/maestro" >&2
  exit 1
fi

platform="${MAESTRO_PLATFORM:-android}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT_DIR/scripts/generate-maestro-fixtures.sh"

case "$platform" in
  android)
    maestro --platform android test maestro/android
    ;;
  ios)
    maestro --platform ios test maestro/ios
    ;;
  all)
    maestro --platform android test maestro/android
    maestro --platform ios test maestro/ios
    ;;
  *)
    echo "Usage: MAESTRO_PLATFORM=android|ios|all $0" >&2
    exit 2
    ;;
esac
