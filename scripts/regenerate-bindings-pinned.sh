#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/zmanager-paths.sh"
ZMANAGER_DIR="$($ROOT_DIR/scripts/resolve-zmanager-source.sh)"
export ZMANAGER_DIR

exec "$ZMANAGER_DIR/scripts/regenerate-bindings.sh" "$@"
