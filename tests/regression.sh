#!/usr/bin/env bash
# Focused regression tests for runtime ownership, file operations and trash.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

export HOME="$WORK/home"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
mkdir -p -- "$HOME" "$WORK/external-runtime"

export OMNISH_RUNTIME_DIR="$WORK/external-runtime"
source "$ROOT/lib/00-config.sh"
source "$ROOT/lib/10-utils.sh"

status_msg() { :; }
spinner_begin() { :; }
spinner_end() { :; }
source "$ROOT/lib/50-fileops.sh"
source "$ROOT/lib/60-trash.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# Caller-owned runtime directories must survive cleanup.
cleanup
[[ -d "$WORK/external-runtime" ]] || fail "caller-owned runtime directory was removed"

# Multi-source copy/move into one directory must reject duplicate basenames.
_fileops_has_duplicate_basenames \
    "$WORK/source-a/shared name.txt" "$WORK/source-b/shared name.txt" \
    || fail "duplicate basenames were not detected"
if _fileops_has_duplicate_basenames "$WORK/source-a/one.txt" "$WORK/source-b/two.txt"; then
    fail "distinct basenames were incorrectly rejected"
fi
_fileops_has_duplicate_basenames "$WORK/source-a/one" "$WORK/source-b/dir/one" \
    || fail "duplicate basenames in nested paths were not detected"

# Two files with identical basenames in separate directories must form one
# trash batch and restore to their exact original locations.
mkdir -p -- "$WORK/source-a" "$WORK/source-b"
printf 'alpha\n' > "$WORK/source-a/shared name.txt"
printf 'beta\n' > "$WORK/source-b/shared name.txt"
trash "$WORK/source-a/shared name.txt" "$WORK/source-b/shared name.txt"
[[ ! -e "$WORK/source-a/shared name.txt" && ! -e "$WORK/source-b/shared name.txt" ]] \
    || fail "trash did not move both source files"
undo_trash
[[ "$(cat "$WORK/source-a/shared name.txt")" == alpha ]] || fail "first file was not restored"
[[ "$(cat "$WORK/source-b/shared name.txt")" == beta ]] || fail "second file was not restored"

# Symlinks must be moved/restored as links, not replaced by their referents.
printf 'target\n' > "$WORK/target"
ln -s -- "$WORK/target" "$WORK/source-a/link"
trash "$WORK/source-a/link"
undo_trash
[[ -L "$WORK/source-a/link" ]] || fail "symlink identity was not preserved"
[[ "$(readlink -- "$WORK/source-a/link")" == "$WORK/target" ]] || fail "symlink target changed"

# Dangling symlinks are valid filesystem entries and must also survive trash.
ln -s -- "$WORK/missing-target" "$WORK/source-a/dangling-link"
trash "$WORK/source-a/dangling-link"
[[ ! -e "$WORK/source-a/dangling-link" && ! -L "$WORK/source-a/dangling-link" ]] \
    || fail "dangling symlink was not moved to trash"
undo_trash
[[ -L "$WORK/source-a/dangling-link" ]] || fail "dangling symlink was not restored"
[[ "$(readlink -- "$WORK/source-a/dangling-link")" == "$WORK/missing-target" ]] \
    || fail "dangling symlink target changed"

# An internally-created runtime directory is private and cleaned up.
(
    unset OMNISH_CONFIG_LOADED OMNISH_RUNTIME_DIR OMNISH_RUNTIME_OWNED
    export XDG_RUNTIME_DIR="$WORK"
    source "$ROOT/lib/00-config.sh"
    source "$ROOT/lib/10-utils.sh"
    owned_runtime="$TMP_OMNISH_DIR"
    [[ "$OMNISH_RUNTIME_OWNED" == 1 ]]
    cleanup
    [[ ! -e "$owned_runtime" ]]
)

printf 'PASS: runtime ownership, file-operation guards and trash restore regressions\n'
