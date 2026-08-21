#!/usr/bin/env bash
# Shared path configuration for mobile's Rust bridge scripts.
# Callers must set ROOT_DIR to the mobile repository root before sourcing.
set -euo pipefail

: "${ROOT_DIR:?ROOT_DIR must be set before sourcing zmanager-paths.sh}"

ZMANAGER_RELATIVE_DIR="${ZMANAGER_RELATIVE_DIR:-../zmanager}"
if [[ -z "${ZMANAGER_COMMIT:-}" ]]; then
  default_zmanager_dir="$ROOT_DIR/$ZMANAGER_RELATIVE_DIR"
  ZMANAGER_COMMIT="$(git -C "$default_zmanager_dir" rev-parse HEAD 2>/dev/null || true)"
  ZMANAGER_COMMIT="${ZMANAGER_COMMIT:-b1336fc48fbc2bd1db548b7cb9042c8fbf6f7224}"
fi
if [[ -n "${ZMANAGER_DIR:-}" ]]; then
  ZMANAGER_DIR_OVERRIDE=1
else
  ZMANAGER_DIR_OVERRIDE=0
fi

if [[ -n "${ZMANAGER_DIR:-}" && "$ZMANAGER_DIR" != /* ]]; then
  ZMANAGER_DIR="$ROOT_DIR/$ZMANAGER_DIR"
elif [[ -z "${ZMANAGER_DIR:-}" ]]; then
  ZMANAGER_DIR="$ROOT_DIR/$ZMANAGER_RELATIVE_DIR"
fi

# zmanager's Cargo.toml expects its path-reader siblings beside the selected
# checkout, e.g. ../forensic-vfs-engine or .cache/forensic-vfs-engine.
ZMANAGER_CACHE_ROOT="${ZMANAGER_CACHE_ROOT:-$(dirname "$ZMANAGER_DIR")}"
export ZMANAGER_COMMIT ZMANAGER_RELATIVE_DIR ZMANAGER_DIR ZMANAGER_DIR_OVERRIDE ZMANAGER_CACHE_ROOT
