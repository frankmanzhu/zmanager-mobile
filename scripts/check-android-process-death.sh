#!/usr/bin/env bash
set -euo pipefail

if ! command -v adb >/dev/null 2>&1 || ! command -v maestro >/dev/null 2>&1; then
  echo "adb and Maestro are required for Android process-death verification." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID="org.tzap.zmanager.mobile"
adb wait-for-device

# Start a deterministic paced job. The flow is expected to be interrupted by
# force-stop, so its Maestro process may report a driver disconnect.
set +e
MAESTRO_DRIVER_STARTUP_TIMEOUT="${MAESTRO_DRIVER_STARTUP_TIMEOUT:-120000}" \
  maestro --platform android test "$ROOT_DIR/maestro/android/extraction-process-death-start.yaml" &
FLOW_PID=$!
set -e

# Wait for the foreground service to persist its active token. This proves the
# process-death boundary is being exercised rather than stopping during import
# or planning.
marker_seen=0
for _ in $(seq 1 "${PROCESS_DEATH_MARKER_TIMEOUT_SECONDS:-90}"); do
  marker="$(adb shell run-as "$APP_ID" cat shared_prefs/archive_job_results.xml 2>/dev/null || true)"
  if [[ "$marker" == *active.token* ]]; then
    marker_seen=1
    break
  fi
  sleep 1
done
if [[ "$marker_seen" != 1 ]]; then
  echo "Foreground service did not persist an active marker before the timeout." >&2
  kill "$FLOW_PID" 2>/dev/null || true
  wait "$FLOW_PID" 2>/dev/null || true
  exit 1
fi
sleep "${PROCESS_DEATH_FORCE_STOP_DELAY_SECONDS:-2}"
adb shell am force-stop "$APP_ID"
wait "$FLOW_PID" || true

MAESTRO_DRIVER_STARTUP_TIMEOUT="${MAESTRO_DRIVER_STARTUP_TIMEOUT:-120000}" \
  maestro --platform android test "$ROOT_DIR/maestro/android/extraction-process-death-recovery.yaml"

echo "Android foreground-service process-death recovery verified."
