#!/usr/bin/env bash
# The Rust bridge is owned by the sibling `zmanager` repo. This check runs the
# zmanager-ffi unit tests and verifies the crate builds.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZMANAGER_DIR="$ROOT_DIR/../zmanager"

cargo test --manifest-path "$ZMANAGER_DIR/Cargo.toml" -p zmanager-ffi
