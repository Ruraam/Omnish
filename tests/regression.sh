#!/usr/bin/env bash
# Focused regression tests for destructive-path and trash behavior.
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
source "$ROOT/lib/60-trash.sh"

# Caller-owned runtime directories must survive cleanup.
cleanup
[[ -d "$WORK/external-runtime" ]] || {
    printf 'FAIL: caller-owned runtime directory was removed\n' >&2
    exit 1
}

# Two files with identical basenames in separate directories must form one
# batch and restore to their exact original locations.
mkdir -p -- "$WORK/source-a" "$WORK/source-b"
printf 'alpha\n' > "$WORK/source-a/shared name.txt"
printf 'beta\n' > "$WORK/source-b/shared name.txt"
trash "$WORK/source-a/shared name.txt" "$WORK/source-b/shared name.txt"
[[ ! -e "$WORK/source-a/shared name.txt" && ! -e "$WORK/source-b/shared name.txt" ]] || {
    printf 'FAIL: trash did not move both source files\n' >&2
    exit 1
}
undo_trash
[[ "$(cat "$WORK/source-a/shared name.txt")" == alpha ]] || {
    printf 'FAIL: first file was not restored to its source path\n' >&2
    exit 1
}
[[ "$(cat "$WORK/source-b/shared name.txt")" == beta ]] || {
    printf 'FAIL: second file was not restored to its source path\n' >&2
    exit 1
}

# Symlinks must be moved/restored as links, not replaced by their referents.
printf 'target\n' > "$WORK/target"
ln -s -- "$WORK/target" "$WORK/source-a/link"
trash "$WORK/source-a/link"
undo_trash
[[ -L "$WORK/source-a/link" ]] || {
    printf 'FAIL: symlink identity was not preserved\n' >&2
    exit 1
}
[[ "$(readlink -- "$WORK/source-a/link")" == "$WORK/target" ]] || {
    printf 'FAIL: symlink target changed\n' >&2
    exit 1
}

# An internally-created runtime directory is private and cleaned up.
(
    unset OMNISH_RUNTIME_DIR OMNISH_RUNTIME_OWNED
    export XDG_RUNTIME_DIR="$WORK"
    source "$ROOT/lib/00-config.sh"
    source "$ROOT/lib/10-utils.sh"
    owned_runtime="$TMP_OMNISH_DIR"
    [[ "$OMNISH_RUNTIME_OWNED" == 1 ]]
    cleanup
    [[ ! -e "$owned_runtime" ]]
)

printf 'PASS: runtime ownership and trash restore regressions\n'
