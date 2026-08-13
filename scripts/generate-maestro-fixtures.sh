#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/fixtures/maestro/contents"
ANDROID_ASSETS_DIR="$ROOT_DIR/android/app/src/debug/assets"
IOS_FIXTURES_DIR="$ROOT_DIR/ios/ZManagerMobile/ZManagerMobile/MaestroFixtures"
CORE_ROOT="$($ROOT_DIR/scripts/resolve-zmanager-source.sh)"
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

# The split ZIP fixture used to use 64 KiB volumes, leaving obsolete sidecars
# behind when its payload changed. Keep the test set compact and self-cleaning.
for fixture_dir in "$ANDROID_ASSETS_DIR" "$IOS_FIXTURES_DIR"; do
  find "$fixture_dir" -maxdepth 1 -type f -name 'maestro-split.z*' -delete
done

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

copy_fixture() {
  local source_path="$1"
  local fixture_name="${2:-$(basename "$source_path")}"

  install -m 0644 "$source_path" "$ANDROID_ASSETS_DIR/$fixture_name"
  install -m 0644 "$source_path" "$IOS_FIXTURES_DIR/$fixture_name"
}

copy_fixture_group() {
  local pattern="$1"
  local fixture_path
  local fixture_paths=()

  shopt -s nullglob
  fixture_paths=( $pattern )
  shopt -u nullglob
  if (( ${#fixture_paths[@]} == 0 )); then
    echo "No Maestro fixture files matched: $pattern" >&2
    exit 1
  fi
  for fixture_path in "${fixture_paths[@]}"; do
    copy_fixture "$fixture_path"
  done
}

create_split_fixture() {
  local archive_name="$1"
  local archive_format="$2"
  local volume_size="$3"
  shift 3
  local archive_path="$temp_dir/$archive_name"
  local volume_source_dir="$temp_dir/volume-source"

  (
    cd "$volume_source_dir"
    cargo run --quiet --manifest-path "$CLI_MANIFEST" -p zmanager-cli --bin zm -- \
      --no-progress --no-color create "$archive_path" "${SOURCE_PATHS[@]}" data/volume-fixture.txt \
      --format "$archive_format" --volume-size "$volume_size" "$@"
  )
}

for required_command in rar gcab; do
  if ! command -v "$required_command" >/dev/null; then
    echo "$required_command is required to generate the Maestro RAR/CAB fixtures." >&2
    exit 1
  fi
done

volume_source_dir="$temp_dir/volume-source"
mkdir -p "$volume_source_dir"
cp -R "$SOURCE_DIR"/. "$volume_source_dir"/
# Fixed-seed pseudo-random data keeps split fixtures deterministic while
# remaining incompressible enough to exercise every volume reader.
awk 'BEGIN { srand(107); for (i = 0; i < 300000; i++) printf "%.12f\\n", rand() }' \
  > "$volume_source_dir/data/volume-fixture.txt"

create_fixture "maestro-files.zip" "zip"
create_fixture "maestro-files.7z" "7z"
create_fixture "maestro-files.tgz" "tgz"
create_fixture "maestro-files.tar.zst" "tar.zst"
create_fixture "maestro-files.tzap" "tzap"
create_fixture "maestro-files.aar" "aar"

# A deterministic archive-in-archive fixture exercises the native nested
# session stack without adding archive parsing to either mobile shell.
nested_dir="$temp_dir/nested"
mkdir -p "$nested_dir/inner"
cp "$SOURCE_DIR/docs/readme.txt" "$nested_dir/inner/readme.txt"
(
  cd "$nested_dir/inner"
  zip -X -q "$nested_dir/maestro-inner.zip" readme.txt
)
(
  cd "$nested_dir"
  cargo run --quiet --manifest-path "$CLI_MANIFEST" -p zmanager-cli --bin zm -- \
    --no-progress --no-color create "$temp_dir/maestro-nested.zip" maestro-inner.zip --format zip
)
copy_fixture "$temp_dir/maestro-nested.zip"

create_split_fixture "maestro-split.zip" "zip" "4m" "--store"
copy_fixture_group "$temp_dir/maestro-split.z*"

create_split_fixture "maestro-split.7z" "7z" "1m"
copy_fixture_group "$temp_dir/maestro-split.7z.*"

create_split_fixture "maestro-split.tzap" "tzap" "1m"
copy_fixture_group "$temp_dir/maestro-split.vol*.tzap"

(
  cd "$volume_source_dir"
  rar a -idq -m0 -v1m "$temp_dir/maestro-split-rar.rar" \
    "${SOURCE_PATHS[@]}" data/volume-fixture.txt
)
copy_fixture_group "$temp_dir/maestro-split-rar.part*.rar"

(
  cd "$SOURCE_DIR"
  gcab -c "$temp_dir/maestro-files.cab" "${SOURCE_PATHS[@]}"
)
copy_fixture "$temp_dir/maestro-files.cab"
copy_fixture "$CORE_ROOT/fixtures/archives/basic.deb" "maestro-files.deb"
