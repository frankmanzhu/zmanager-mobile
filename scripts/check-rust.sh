#!/usr/bin/env bash
# The Rust bridge is owned by the `zmanager` repo. This check resolves the
# pinned source checkout, then runs zmanager-ffi tests.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZMANAGER_DIR="$($ROOT_DIR/scripts/resolve-zmanager-source.sh)"

for profile in full offline; do
  profile_args=()
  if [[ "$profile" == "full" ]]; then
    profile_args=(--no-default-features --features tzap-online)
  else
    profile_args=(--no-default-features)
  fi
  cargo test --manifest-path "$ZMANAGER_DIR/Cargo.toml" -p zmanager-ffi "${profile_args[@]}"
done
