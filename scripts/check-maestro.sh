#!/usr/bin/env bash
set -euo pipefail

if ! command -v maestro >/dev/null 2>&1; then
  echo "Maestro CLI is required. Install it with: brew install mobile-dev-inc/tap/maestro" >&2
  exit 1
fi

platform="${MAESTRO_PLATFORM:-android}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

restore_generated_fixtures() {
  git -C "$ROOT_DIR" restore --source=HEAD -- \
    android/app/src/debug/assets \
    ios/ZManagerMobile/ZManagerMobile/MaestroFixtures
}

trap restore_generated_fixtures EXIT

"$ROOT_DIR/scripts/generate-maestro-fixtures.sh"

run_platform_flows() {
  local target_platform="$1"
  local flow
  local -a maestro_args=(--platform "$target_platform")
  if [[ -n "${MAESTRO_DEVICE_ID:-}" ]]; then
    maestro_args+=(--device "$MAESTRO_DEVICE_ID")
  fi
  shopt -s nullglob
  for flow in "$ROOT_DIR/maestro/$target_platform"/*.yaml; do
    case "$(basename "$flow")" in
      extraction-process-death-start.yaml|extraction-process-death-recovery.yaml)
        # These two flows must be run as a pair by the dedicated ordered
        # process-death harness below.
        continue
        ;;
    esac
    maestro "${maestro_args[@]}" test "$flow"
  done
}

case "$platform" in
  android)
    run_platform_flows android
    "$ROOT_DIR/scripts/check-android-process-death.sh"
    ;;
  ios)
    run_platform_flows ios
    ;;
  all)
    run_platform_flows android
    "$ROOT_DIR/scripts/check-android-process-death.sh"
    run_platform_flows ios
    ;;
  *)
    echo "Usage: MAESTRO_PLATFORM=android|ios|all $0" >&2
    exit 2
    ;;
esac
