#!/usr/bin/env bash
# Resolve the Rust bridge source used by this checkout.
#
# The default is intentionally a separate detached checkout. This keeps a
# moving or dirty sibling ../zmanager worktree from changing mobile builds.
# Set ZMANAGER_DIR only when an existing checkout is already at ZMANAGER_COMMIT.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/zmanager-paths.sh"
ZMANAGER_REPOSITORY="${ZMANAGER_REPOSITORY:-https://github.com/tzap-org/zmanager.git}"
FORENSIC_VFS_ENGINE_REPOSITORY="${FORENSIC_VFS_ENGINE_REPOSITORY:-https://github.com/frankmanzhu/forensic-vfs-engine.git}"
NTFS_FORENSIC_REPOSITORY="${NTFS_FORENSIC_REPOSITORY:-https://github.com/frankmanzhu/ntfs-forensic.git}"
UDF_FORENSIC_REPOSITORY="${UDF_FORENSIC_REPOSITORY:-https://github.com/frankmanzhu/udf-forensic.git}"

verify_checkout() {
  local checkout="$1"
  local revision="${2:-$ZMANAGER_COMMIT}"
  if [[ ! -f "$checkout/Cargo.toml" && ! -f "$checkout/core/Cargo.toml" ||
        ! -d "$checkout/.git" && ! -f "$checkout/.git" ]]; then
    return 1
  fi
  [[ "$(git -C "$checkout" rev-parse HEAD 2>/dev/null)" == "$revision" ]]
}

clone_at_revision() {
  local repository="$1"
  local revision="$2"
  local checkout="$3"
  if verify_checkout "$checkout" "$revision"; then
    return 0
  fi
  mkdir -p "$(dirname "$checkout")"
  if [[ -e "$checkout" ]]; then
    echo "Pinned dependency cache exists but is not at $revision: $checkout" >&2
    exit 1
  fi
  git clone --no-checkout --filter=blob:none --no-tags "$repository" "$checkout" >&2
  git -C "$checkout" fetch --depth=1 origin "$revision" >&2
  git -C "$checkout" checkout --detach "$revision" >&2
  if ! verify_checkout "$checkout" "$revision"; then
    echo "Resolved dependency is not pinned to $revision: $checkout" >&2
    exit 1
  fi
}

if [[ "${ZMANAGER_DIR_OVERRIDE:-0}" == 1 ]]; then
  if ! verify_checkout "$ZMANAGER_DIR" "$ZMANAGER_COMMIT"; then
    echo "ZMANAGER_DIR must be a zmanager checkout at $ZMANAGER_COMMIT" >&2
    exit 1
  fi
  printf '%s\n' "$(cd "$ZMANAGER_DIR" && pwd)"
  exit 0
fi

clone_at_revision "$ZMANAGER_REPOSITORY" "$ZMANAGER_COMMIT" "$ZMANAGER_DIR"

# The pinned zmanager workspace deliberately uses path dependencies for these
# readers. Hydrate them beside the checkout under .cache/ so Cargo never
# resolves through mutable sibling workspaces.
clone_at_revision \
  "$FORENSIC_VFS_ENGINE_REPOSITORY" \
  "$(tr -d '[:space:]' < "$ZMANAGER_DIR/forensic-vfs-engine-rev.txt")" \
  "$ZMANAGER_CACHE_ROOT/forensic-vfs-engine"
clone_at_revision \
  "$NTFS_FORENSIC_REPOSITORY" \
  "$(tr -d '[:space:]' < "$ZMANAGER_DIR/ntfs-forensic-rev.txt")" \
  "$ZMANAGER_CACHE_ROOT/ntfs-forensic"
clone_at_revision \
  "$UDF_FORENSIC_REPOSITORY" \
  "$(tr -d '[:space:]' < "$ZMANAGER_DIR/udf-forensic-rev.txt")" \
  "$ZMANAGER_CACHE_ROOT/udf-forensic"

printf '%s\n' "$(cd "$ZMANAGER_DIR" && pwd)"
