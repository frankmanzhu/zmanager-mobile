#!/usr/bin/env bash
# Shared path configuration for mobile's Rust bridge scripts.
# Callers must set ROOT_DIR to the mobile repository root before sourcing.
set -euo pipefail

: "${ROOT_DIR:?ROOT_DIR must be set before sourcing zmanager-paths.sh}"

ZMANAGER_COMMIT="${ZMANAGER_COMMIT:-f65d23385ae583462f6d9e68dd84c6fcae1ec89c}"
ZMANAGER_RELATIVE_DIR="${ZMANAGER_RELATIVE_DIR:-.cache/zmanager}"
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

# zmanager's pinned Cargo.toml expects its path-reader siblings beside the
# checkout, e.g. .cache/forensic-vfs-engine and .cache/ntfs-forensic.
ZMANAGER_CACHE_ROOT="${ZMANAGER_CACHE_ROOT:-$(dirname "$ZMANAGER_DIR")}"
export ZMANAGER_COMMIT ZMANAGER_RELATIVE_DIR ZMANAGER_DIR ZMANAGER_DIR_OVERRIDE ZMANAGER_CACHE_ROOT
