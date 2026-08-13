#!/usr/bin/env bash
# The Rust bridge is owned by the `zmanager` repo. This check resolves the
# pinned source checkout, then runs zmanager-ffi tests.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZMANAGER_DIR="$($ROOT_DIR/scripts/resolve-zmanager-source.sh)"

cargo test --manifest-path "$ZMANAGER_DIR/Cargo.toml" -p zmanager-ffi
