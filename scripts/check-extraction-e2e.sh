#!/usr/bin/env bash
set -euo pipefail

if ! command -v maestro >/dev/null 2>&1; then
  echo "Maestro CLI is required. Install it with: brew install mobile-dev-inc/tap/maestro" >&2
  exit 1
fi

platform="${MAESTRO_PLATFORM:-android}"
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_id="org.tzap.zmanager.mobile"
# iOS launches a fresh XCTest driver for every matrix case. Allow Xcode and
# the simulator enough time to start that driver after a previous case.
export MAESTRO_DRIVER_STARTUP_TIMEOUT="${MAESTRO_DRIVER_STARTUP_TIMEOUT:-120000}"

"$root_dir/scripts/generate-maestro-fixtures.sh"

case "$platform" in
  android)
    command -v adb >/dev/null 2>&1 || { echo "adb is required for Android extraction verification." >&2; exit 1; }
    adb wait-for-device
    platform_flows=(
      "extraction-workflow.yaml:5"
      "extraction-7z.yaml:5"
      "extraction-targz.yaml:5"
      "extraction-tarzst.yaml:5"
      "extraction-tzap.yaml:5"
      "extraction-tarbz2.yaml:5"
      "extraction-tarxz.yaml:5"
      "extraction-tarlzma.yaml:5"
      "extraction-tarlz.yaml:5"
      "extraction-tarlzo.yaml:5"
      "extraction-tarz.yaml:5"
      "extraction-tarlz4.yaml:5"
      "extraction-taruu.yaml:5"
      "extraction-gzip.yaml:1"
      "extraction-bzip2.yaml:1"
      "extraction-xz.yaml:1"
      "extraction-lzma.yaml:1"
      "extraction-lzip.yaml:1"
      "extraction-lzo.yaml:1"
      "extraction-unix-compress.yaml:1"
      "extraction-lz4.yaml:1"
      "extraction-zstd.yaml:1"
      "extraction-brotli.yaml:1"
      "extraction-uu.yaml:1"
      "extraction-b64.yaml:1"
      "extraction-split-zip.yaml:6"
      "extraction-split-7z.yaml:6"
      "extraction-split-tzap.yaml:6"
      "extraction-multipart-rar.yaml:6"
      # The Debian fixture has three archive members (the UI count), but its
      # data member expands to nine committed payload/metadata files.
      "extraction-deb.yaml:9"
      "extraction-cab.yaml:5"
      "extraction-ar.yaml:3"
      "extraction-cpio.yaml:4"
      "extraction-xar.yaml:4"
      "extraction-iso.yaml:4"
      "extraction-pkg.yaml:14"
      "extraction-msi.yaml:3"
      "extraction-dmg.yaml:4"
      "extraction-vhd.yaml:4"
      "extraction-vmdk.yaml:4"
      "extraction-udf.yaml:4:extract"
      "extraction-rpm.yaml:1:extract"
      # LHA reports one directory plus two regular files (three writable
      # entries); the app-private verification intentionally counts files.
      "extraction-lha.yaml:2:extract"
      "extraction-warc.yaml:1:extract"
      "extraction-mtree.yaml:2:test"
    )
    reset_destination() {
      adb shell "run-as $app_id sh -c 'rm -rf files/Extracted'"
    }
    verify_destination() {
      local expected_count="$1"
      local actual_count
      actual_count="$(adb shell "run-as $app_id sh -c 'find files/Extracted -type f -print 2>/dev/null | wc -l'" | tr -d '[:space:]')"
      [ "$actual_count" = "$expected_count" ] || {
        echo "Expected $expected_count committed Android files, found ${actual_count:-0}." >&2
        adb shell "run-as $app_id sh -c 'find files/Extracted -type f -print 2>/dev/null'" >&2 || true
        return 1
      }
    }
    ;;
  ios)
    command -v xcrun >/dev/null 2>&1 || { echo "Xcode command-line tools are required for iOS extraction verification." >&2; exit 1; }
    platform_flows=(
      "extraction-workflow.yaml:5"
      "extraction-7z.yaml:5"
      "extraction-targz.yaml:5"
      "extraction-tarzst.yaml:5"
      "extraction-tzap.yaml:5"
      "extraction-applearchive.yaml:5"
      "extraction-tarbz2.yaml:5"
      "extraction-tarxz.yaml:5"
      "extraction-tarlzma.yaml:5"
      "extraction-tarlz.yaml:5"
      "extraction-tarlzo.yaml:5"
      "extraction-tarz.yaml:5"
      "extraction-tarlz4.yaml:5"
      "extraction-taruu.yaml:5"
      "extraction-gzip.yaml:1"
      "extraction-bzip2.yaml:1"
      "extraction-xz.yaml:1"
      "extraction-lzma.yaml:1"
      "extraction-lzip.yaml:1"
      "extraction-lzo.yaml:1"
      "extraction-unix-compress.yaml:1"
      "extraction-lz4.yaml:1"
      "extraction-zstd.yaml:1"
      "extraction-brotli.yaml:1"
      "extraction-uu.yaml:1"
      "extraction-b64.yaml:1"
      "extraction-split-zip.yaml:6"
      "extraction-split-7z.yaml:6"
      "extraction-split-tzap.yaml:6"
      "extraction-multipart-rar.yaml:6"
      # The Debian fixture has three archive members (the UI count), but its
      # data member expands to nine committed payload/metadata files.
      "extraction-deb.yaml:9"
      "extraction-cab.yaml:5"
      "extraction-ar.yaml:3"
      "extraction-cpio.yaml:4"
      "extraction-xar.yaml:4"
      "extraction-iso.yaml:4"
      "extraction-pkg.yaml:14"
      "extraction-msi.yaml:3"
      "extraction-dmg.yaml:4"
      "extraction-vhd.yaml:4"
      "extraction-vmdk.yaml:4"
      "extraction-udf.yaml:4:extract"
      "extraction-rpm.yaml:1:extract"
      # LHA reports one directory plus two regular files (three writable
      # entries); the app-private verification intentionally counts files.
      "extraction-lha.yaml:2:extract"
      "extraction-warc.yaml:1:extract"
      "extraction-mtree.yaml:2:test"
    )
    reset_destination() {
      local container
      container="$(xcrun simctl get_app_container booted "$app_id" data)"
      rm -rf "$container/Library/Application Support/ZManagerMobile/Extracted"
    }
    verify_destination() {
      local expected_count="$1"
      local container actual_count
      container="$(xcrun simctl get_app_container booted "$app_id" data)"
      actual_count="$(find "$container/Library/Application Support/ZManagerMobile/Extracted" -type f -print 2>/dev/null | wc -l | tr -d '[:space:]')"
      [ "$actual_count" = "$expected_count" ] || {
        echo "Expected $expected_count committed iOS files, found ${actual_count:-0}." >&2
        find "$container/Library/Application Support/ZManagerMobile/Extracted" -type f -print 2>/dev/null >&2 || true
        return 1
      }
    }
    ;;
  *)
    echo "Usage: MAESTRO_PLATFORM=android|ios $0" >&2
    exit 2
    ;;
esac

start_flow="${MAESTRO_START_FLOW:-}"
if [[ -z "$start_flow" ]]; then
  started_from_requested_flow=true
else
  started_from_requested_flow=false
fi
for flow_case in "${platform_flows[@]}"; do
  flow_name="${flow_case%%:*}"
  if [[ "$started_from_requested_flow" == false ]]; then
    if [[ "$flow_name" != "$start_flow" ]]; then
      continue
    fi
    started_from_requested_flow=true
  fi
  flow_details="${flow_case#*:}"
  expected_count="${flow_details%%:*}"
  flow_mode="${flow_details#*:}"
  if [[ "$flow_mode" == "$flow_details" ]]; then
    flow_mode="extract"
  fi
  reset_destination
  if [[ "$platform" == "ios" ]]; then
    # SwiftUI can preserve the outer ScrollView/Menu presentation across a
    # simulator relaunch. Terminate the app so every matrix case starts with
    # the same landing-screen process state.
    xcrun simctl terminate booted "$app_id" >/dev/null 2>&1 || true
  fi
  maestro --platform "$platform" test "$root_dir/maestro/$platform/$flow_name"
  if [[ "$flow_mode" == "extract" ]]; then
    verify_destination "$expected_count"
  fi
done

if [[ "$started_from_requested_flow" == false ]]; then
  echo "MAESTRO_START_FLOW did not match the platform matrix: $start_flow" >&2
  exit 2
fi
