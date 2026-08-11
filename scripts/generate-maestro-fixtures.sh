#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/fixtures/maestro/contents"
ANDROID_ASSETS_DIR="$ROOT_DIR/android/app/src/debug/assets"
IOS_FIXTURES_DIR="$ROOT_DIR/ios/ZManagerMobile/ZManagerMobile/MaestroFixtures"
CORE_ROOT="$ROOT_DIR/../zmanager"
CLI_MANIFEST="$CORE_ROOT/Cargo.toml"
SOURCE_PATHS=(
  docs/readme.txt
  data/manifest.json
  images/cover.svg
  notes/release-notes.md
  reports/summary.pdf
)

if [[ ! -f "$CLI_MANIFEST" ]]; then
  echo "The sibling zmanager checkout is required to generate Maestro fixtures." >&2
  exit 1
fi

mkdir -p "$ANDROID_ASSETS_DIR" "$IOS_FIXTURES_DIR"

temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

create_fixture() {
  local archive_name="$1"
  local archive_format="$2"
  local archive_path="$temp_dir/$archive_name"

  (
    cd "$SOURCE_DIR"
    cargo run --quiet --manifest-path "$CLI_MANIFEST" -p zmanager-cli --bin zm -- \
      --no-progress --no-color create "$archive_path" "${SOURCE_PATHS[@]}" --format "$archive_format"
  )

  install -m 0644 "$archive_path" "$ANDROID_ASSETS_DIR/$archive_name"
  install -m 0644 "$archive_path" "$IOS_FIXTURES_DIR/$archive_name"
}

create_fixture "maestro-files.zip" "zip"
create_fixture "maestro-files.7z" "7z"
create_fixture "maestro-files.tgz" "tgz"
create_fixture "maestro-files.tar.zst" "tar.zst"
create_fixture "maestro-files.tzap" "tzap"
create_fixture "maestro-files.aar" "aar"
