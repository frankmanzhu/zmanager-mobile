#!/usr/bin/env bash
# Copies the zmanager format contract (the output of `zm formats --contract`,
# committed in the sibling zmanager repo) into the Android test resources so
# FormatRegistryConformanceTest can pin the app's static format knowledge to
# the registry. Run after any change to FORMAT_CAPABILITIES or the extension
# constants in zmanager-core, and commit the refreshed snapshot.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZMANAGER_DIR="$($ROOT_DIR/scripts/resolve-zmanager-source.sh)"
CONTRACT="$ZMANAGER_DIR/crates/zmanager-cli/contracts/archive-formats.json"
SNAPSHOT="$ROOT_DIR/android/app/src/test/resources/format-capabilities.json"

if [[ ! -f "$CONTRACT" ]]; then
  echo "format contract not found at $CONTRACT" >&2
  echo "generate it with zmanager's scripts/refresh-format-contract.sh" >&2
  exit 1
fi

cp "$CONTRACT" "$SNAPSHOT"
echo "Refreshed $SNAPSHOT"
