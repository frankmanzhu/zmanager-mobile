#!/usr/bin/env bash
set -euo pipefail

if ! command -v maestro >/dev/null 2>&1; then
  echo "Maestro CLI is required. Install it with: brew install mobile-dev-inc/tap/maestro" >&2
  exit 1
fi

platform="${MAESTRO_PLATFORM:-android}"

case "$platform" in
  android)
    maestro test maestro/android/smoke.yaml
    ;;
  ios)
    maestro test maestro/ios/smoke.yaml
    ;;
  all)
    maestro test maestro/android/smoke.yaml
    maestro test maestro/ios/smoke.yaml
    ;;
  *)
    echo "Usage: MAESTRO_PLATFORM=android|ios|all $0" >&2
    exit 2
    ;;
esac
