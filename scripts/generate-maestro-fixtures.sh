#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/fixtures/maestro/contents"
ANDROID_ASSETS_DIR="$ROOT_DIR/android/app/src/debug/assets"
IOS_FIXTURES_DIR="$ROOT_DIR/ios/ZManagerMobile/ZManagerMobile/MaestroFixtures"
ARCHIVE_NAME="maestro-files.zip"

if ! command -v zip >/dev/null 2>&1; then
  echo "zip is required to generate Maestro fixtures." >&2
  exit 1
fi

mkdir -p "$ANDROID_ASSETS_DIR" "$IOS_FIXTURES_DIR"

temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

archive_path="$temp_dir/$ARCHIVE_NAME"
(
  cd "$SOURCE_DIR"
  zip -X -q "$archive_path" \
    docs/readme.txt \
    data/manifest.json \
    images/cover.svg \
    notes/release-notes.md \
    reports/summary.pdf
)

install -m 0644 "$archive_path" "$ANDROID_ASSETS_DIR/$ARCHIVE_NAME"
install -m 0644 "$archive_path" "$IOS_FIXTURES_DIR/$ARCHIVE_NAME"
