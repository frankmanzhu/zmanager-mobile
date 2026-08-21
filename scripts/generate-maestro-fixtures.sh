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

create_tar_codec_fixture() {
  local archive_name="$1"
  local compressor="$2"
  local archive_path="$temp_dir/$archive_name"
  local tar_path="$temp_dir/maestro-files.tar"

  if [[ ! -f "$tar_path" ]]; then
    COPYFILE_DISABLE=1 tar -cf "$tar_path" -C "$SOURCE_DIR" "${SOURCE_PATHS[@]}"
  fi
  case "$compressor" in
    bzip2|xz|lzma|lzip|lzop|compress|lz4|zstd)
      "$compressor" -c "$tar_path" > "$archive_path"
      ;;
    uuencode)
      uuencode -m -o "$archive_path" "$tar_path" maestro-files.tar
      ;;
    *)
      echo "Unknown TAR fixture compressor: $compressor" >&2
      exit 1
      ;;
  esac
  copy_fixture "$archive_path"
}

create_raw_stream_fixture() {
  local archive_name="$1"
  local compressor="$2"
  local source_path="$SOURCE_DIR/docs/readme.txt"
  local archive_path="$temp_dir/$archive_name"

  case "$compressor" in
    gzip|bzip2|xz|lzma|lzip|lzop|compress|lz4|zstd|brotli)
      "$compressor" -c "$source_path" > "$archive_path"
      ;;
    uuencode)
      uuencode -m -o "$archive_path" "$source_path" readme.txt
      ;;
    *)
      echo "Unknown raw-stream fixture compressor: $compressor" >&2
      exit 1
      ;;
  esac
  if [[ "$archive_name" == "maestro-stream.gz" ]]; then
    # AAPT strips a literal .gz asset name and inflates it on read. Keep the
    # source bytes under a neutral Android-only name; the importer restores
    # the production .gz display/path suffix before invoking the bridge.
    install -m 0644 "$archive_path" "$ANDROID_ASSETS_DIR/maestro-stream.gz.fixture"
    install -m 0644 "$archive_path" "$IOS_FIXTURES_DIR/$archive_name"
  else
    copy_fixture "$archive_path"
  fi
}

create_lha_fixture() {
  local archive_path="$temp_dir/maestro-files.lha"
  python3 - "$archive_path" <<'PY'
import struct
import sys

destination = sys.argv[1]

def crc16(data):
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xa001 if crc & 1 else crc >> 1
    return crc

entries = [
    ("nested", b"", True),
    ("nested/hello.txt", b"Hello, LHA world!\n", False),
    ("notes.txt", b"Second file contents", False),
]
archive = bytearray()
for name, data, is_directory in entries:
    name_bytes = name.encode("ascii")
    header_size = 22 + len(name_bytes)
    method = b"-lhd-" if is_directory else b"-lh0-"
    size = 0 if is_directory else len(data)
    dos_time = ((2026 - 1980) << 25) | (1 << 21) | (1 << 16) | (12 << 11)
    header = bytearray([header_size, 0])
    header += method
    header += struct.pack("<II", size, size)
    header += struct.pack("<I", dos_time)
    header += bytes([0x10 if is_directory else 0x20, 0, len(name_bytes)])
    header += name_bytes
    header += struct.pack("<H", 0 if is_directory else crc16(data))
    header[1] = sum(header[2:]) & 0xff
    archive += header
    if not is_directory:
        archive += data
archive.append(0)
with open(destination, "wb") as output:
    output.write(archive)
PY
  copy_fixture "$archive_path"
}

create_warc_fixture() {
  local archive_path="$temp_dir/maestro-files.warc"
  python3 - "$archive_path" <<'PY'
import sys

destination = sys.argv[1]
records = [
    ("resource", None, b"ZManager Mobile WARC fixture\n"),
]
with open(destination, "wb") as output:
    for index, (record_type, target, body) in enumerate(records):
        output.write(b"WARC/1.0\r\n")
        output.write(f"WARC-Type: {record_type}\r\n".encode())
        output.write(f"WARC-Record-ID: <urn:uuid:00000000-0000-0000-0000-{index:012}>\r\n".encode())
        output.write(b"WARC-Date: 2026-01-01T12:00:00Z\r\n")
        if target:
            output.write(f"WARC-Target-URI: {target}\r\n".encode())
        output.write(f"Content-Length: {len(body)}\r\n\r\n".encode())
        output.write(body)
        output.write(b"\r\n\r\n")
PY
  copy_fixture "$archive_path"
}

create_mtree_fixture() {
  local archive_path="$temp_dir/maestro-files.mtree"
  local readme_size
  readme_size="$(wc -c < "$SOURCE_DIR/docs/readme.txt" | tr -d '[:space:]')"
  {
    printf '%s\n' '#mtree'
    # The mtree parser treats one-component names as relative to the process
    # working directory. A leading ./ keeps these portable when iOS has no
    # usable process cwd while still producing normalized archive paths.
    printf '%s\n' './docs type=dir'
    printf '%s\n' "./docs/readme.txt type=file size=$readme_size"
  } > "$archive_path"
  copy_fixture "$archive_path"
}

create_rpm_fixture() {
  local rpm_root="$temp_dir/rpm-build"
  local spec_path="$rpm_root/SPECS/maestro-mobile-fixture.spec"
  mkdir -p "$rpm_root"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
  cp "$SOURCE_DIR/docs/readme.txt" "$rpm_root/SOURCES/maestro-rpm-readme.txt"
  {
    printf '%s\n' 'Name: maestro-mobile-fixture'
    printf '%s\n' 'Version: 1.0'
    printf '%s\n' 'Release: 1'
    printf '%s\n' 'Summary: ZManager Mobile RPM fixture'
    printf '%s\n' 'License: MIT'
    printf '%s\n' 'BuildArch: noarch'
    printf '%s\n' '%description'
    printf '%s\n' 'Deterministic archive fixture for mobile bridge tests.'
    printf '%s\n' '%prep'
    printf '%s\n' '%build'
    printf '%s\n' '%install'
    printf '%s\n' 'mkdir -p %{buildroot}/usr/share/zmanager'
    printf '%s\n' 'cp %{_sourcedir}/maestro-rpm-readme.txt %{buildroot}/usr/share/zmanager/readme.txt'
    printf '%s\n' '%files'
    printf '%s\n' '/usr/share/zmanager/readme.txt'
  } > "$spec_path"
  rpmbuild --quiet --define "_topdir $rpm_root" --define "_build_id_links none" -bb "$spec_path"
  local rpm_path
  rpm_path="$(find "$rpm_root/RPMS" -type f -name '*.rpm' -print -quit)"
  test -n "$rpm_path"
  copy_fixture "$rpm_path" "maestro-files.rpm"
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

for required_command in rar gcab bzip2 xz lzma lzip lzop compress lz4 zstd brotli uuencode rpmbuild python3; do
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

create_tar_codec_fixture "maestro-files.tar.bz2" "bzip2"
create_tar_codec_fixture "maestro-files.tar.xz" "xz"
create_tar_codec_fixture "maestro-files.tar.lzma" "lzma"
create_tar_codec_fixture "maestro-files.tar.lz" "lzip"
create_tar_codec_fixture "maestro-files.tar.lzo" "lzop"
create_tar_codec_fixture "maestro-files.tar.z" "compress"
create_tar_codec_fixture "maestro-files.tar.lz4" "lz4"
create_tar_codec_fixture "maestro-files.tar.uu" "uuencode"

create_raw_stream_fixture "maestro-stream.gz" "gzip"
create_raw_stream_fixture "maestro-stream.bz2" "bzip2"
create_raw_stream_fixture "maestro-stream.xz" "xz"
create_raw_stream_fixture "maestro-stream.lzma" "lzma"
create_raw_stream_fixture "maestro-stream.lz" "lzip"
create_raw_stream_fixture "maestro-stream.lzo" "lzop"
create_raw_stream_fixture "maestro-stream.Z" "compress"
create_raw_stream_fixture "maestro-stream.lz4" "lz4"
create_raw_stream_fixture "maestro-stream.zst" "zstd"
create_raw_stream_fixture "maestro-stream.br" "brotli"
create_raw_stream_fixture "maestro-stream.uu" "uuencode"
copy_fixture "$temp_dir/maestro-stream.uu" "maestro-stream.b64"
create_lha_fixture
create_warc_fixture
create_mtree_fixture
create_rpm_fixture

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

# A password-bearing ZIP keeps the password-required and wrong-password flows
# deterministic without putting a password in production code or diagnostics.
# Use the resolved Rust CLI so both mobile bridges exercise the same encrypted
# ZIP implementation instead of depending on host `zip` encryption details.
(
  cd "$nested_dir"
  printf '%s\n' "v2testpassword" | cargo run --quiet --manifest-path "$CLI_MANIFEST" -p zmanager-cli --bin zm -- \
    --no-progress --no-color create "$temp_dir/maestro-encrypted.zip" maestro-inner.zip \
    --format zip --encrypt --password-stdin
)
copy_fixture "$temp_dir/maestro-encrypted.zip"

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
copy_fixture "$CORE_ROOT/fixtures/archives/basic.deb" "maestro-files.ar"
copy_fixture "$CORE_ROOT/fixtures/archives/basic.cpio" "maestro-files.cpio"
copy_fixture "$CORE_ROOT/fixtures/archives/basic.xar" "maestro-files.xar"
copy_fixture "$CORE_ROOT/fixtures/archives/basic.iso" "maestro-files.iso"
copy_fixture "$CORE_ROOT/fixtures/archives/basic.pkg" "maestro-files.pkg"
copy_fixture "$CORE_ROOT/fixtures/archives/basic.msi" "maestro-files.msi"
copy_fixture "$CORE_ROOT/fixtures/archives/basic.dmg" "maestro-files.dmg"
copy_fixture "$CORE_ROOT/fixtures/archives/basic.vhd" "maestro-files.vhd"
copy_fixture "$CORE_ROOT/fixtures/archives/basic.vmdk" "maestro-files.vmdk"
copy_fixture "$CORE_ROOT/fixtures/archives/basic.udf" "maestro-files.udf"
