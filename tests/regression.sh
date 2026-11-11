#!/usr/bin/env bash
# Focused regression tests for runtime ownership, file operations and trash.
set -euo pipefail
trap 'rc=$?; printf "FAIL: regression command at line %s (exit %s): %s\\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2; exit "$rc"' ERR

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


# Exercise user-facing file operations with deterministic prompt/progress mocks.
cmd_line() { cmd_reply="${TEST_CMD_REPLY:-}"; }
cmd_yes_no() { cmd_reply=yes; }
messages() { :; }
progress_begin() { :; }
progress_set() { :; }
progress_end() { :; }

mkdir -p -- "$WORK/op-source" "$WORK/op-dest"
printf 'copy payload\n' > "$WORK/op-source/file with spaces.txt"
(
    cd -- "$WORK/op-dest"
    export TEST_CMD_REPLY="copied file.txt"
    copy_file "$WORK/op-source/file with spaces.txt"
)
[[ "$(cat "$WORK/op-dest/copied file.txt")" == "copy payload" ]] \
    || fail "copy_file did not preserve a spaced source path"

(
    cd -- "$WORK/op-dest"
    export TEST_CMD_REPLY="moved file.txt"
    move_file "$WORK/op-source/file with spaces.txt"
)
[[ ! -e "$WORK/op-source/file with spaces.txt" ]] || fail "move_file left the source behind"
[[ "$(cat "$WORK/op-dest/moved file.txt")" == "copy payload" ]] \
    || fail "move_file did not preserve file contents"

(
    cd -- "$WORK/op-dest"
    export TEST_CMD_REPLY="created directory"
    create_directory
    export TEST_CMD_REPLY="created file.txt"
    create_file
)
[[ -d "$WORK/op-dest/created directory" ]] || fail "create_directory failed"
[[ -f "$WORK/op-dest/created file.txt" ]] || fail "create_file failed"

(
    cd -- "$WORK/op-dest"
    export TEST_CMD_REPLY="created link"
    create_symlink "$WORK/op-dest/moved file.txt"
)
[[ -L "$WORK/op-dest/created link" ]] || fail "create_symlink did not create a link"
[[ "$(readlink -- "$WORK/op-dest/created link")" == "$WORK/op-dest/moved file.txt" ]] \
    || fail "create_symlink target was not preserved"


# Marked multi-file operations must reject colliding destination basenames.
mkdir -p -- "$WORK/marked-a" "$WORK/marked-b" "$WORK/marked-dest"
printf 'first\n' > "$WORK/marked-a/collision.txt"
printf 'second\n' > "$WORK/marked-b/collision.txt"
printf '%s\n%s\n' "$WORK/marked-a/collision.txt" "$WORK/marked-b/collision.txt" > "$WORK/marks.txt"
MARKED_FILES_FILE="$WORK/marks.txt"
(
    cd -- "$WORK/marked-dest"
    copy_file ""
)
[[ ! -e "$WORK/marked-dest/collision.txt" ]] || fail "marked copy overwrote a colliding basename"
(
    cd -- "$WORK/marked-dest"
    move_file ""
)
[[ -f "$WORK/marked-a/collision.txt" && -f "$WORK/marked-b/collision.txt" ]] \
    || fail "marked move consumed files with colliding basenames"

# Distinct marked files must copy and move as a batch without losing spaces.
printf 'third\n' > "$WORK/marked-a/first item.txt"
printf 'fourth\n' > "$WORK/marked-b/second-item.txt"
printf '%s\n%s\n' "$WORK/marked-a/first item.txt" "$WORK/marked-b/second-item.txt" > "$WORK/marks.txt"
generate_mark_file() { marked_files=(); :; }
(
    cd -- "$WORK/marked-dest"
    copy_file ""
)
[[ "$(cat "$WORK/marked-dest/first item.txt")" == third ]] \
    || fail "marked copy failed for a spaced filename"
[[ "$(cat "$WORK/marked-dest/second-item.txt")" == fourth ]] \
    || fail "marked copy failed for a second source"

mkdir -p -- "$WORK/marked-move-dest"
printf '%s\n%s\n' "$WORK/marked-a/first item.txt" "$WORK/marked-b/second-item.txt" > "$WORK/marks.txt"
(
    cd -- "$WORK/marked-move-dest"
    move_file ""
)
[[ ! -e "$WORK/marked-a/first item.txt" && ! -e "$WORK/marked-b/second-item.txt" ]] \
    || fail "marked move did not remove both sources"
[[ "$(cat "$WORK/marked-move-dest/first item.txt")" == third ]] \
    || fail "marked move failed for a spaced filename"


# A partial restore must preserve conflicting entries for a safe retry.
mkdir -p -- "$WORK/restore-a" "$WORK/restore-b"
printf 'restore alpha\n' > "$WORK/restore-a/conflict item.txt"
printf 'restore beta\n' > "$WORK/restore-b/retry item.txt"
trash "$WORK/restore-a/conflict item.txt" "$WORK/restore-b/retry item.txt"
[[ ! -e "$WORK/restore-a/conflict item.txt" && ! -e "$WORK/restore-b/retry item.txt" ]] \
    || fail "partial-restore fixture was not trashed"
printf 'keep existing data\n' > "$WORK/restore-a/conflict item.txt"
if undo_trash; then
    fail "undo_trash reported full success despite a destination conflict"
fi
[[ "$(cat "$WORK/restore-a/conflict item.txt")" == "keep existing data" ]] \
    || fail "restore conflict overwrote the existing destination"
[[ "$(cat "$WORK/restore-b/retry item.txt")" == "restore beta" ]] \
    || fail "undo_trash did not restore the non-conflicting item"
latest_batch=$(find "$OMNI_TRASH" -mindepth 1 -maxdepth 1 -type d -print -quit)
[[ -n "$latest_batch" ]] || fail "partial restore discarded its remaining batch"
remaining_count=$(find "$latest_batch" -mindepth 1 -maxdepth 1 ! -name '.omnish-manifest' -print | wc -l)
[[ "$remaining_count" -eq 1 ]] || fail "partial restore did not retain exactly the conflicted item"
rm -- "$WORK/restore-a/conflict item.txt"
if ! undo_trash; then
    fail "undo_trash could not retry after the destination conflict was removed"
fi
[[ "$(cat "$WORK/restore-a/conflict item.txt")" == "restore alpha" ]] \
    || fail "retry did not restore the previously conflicted item"

# Empty batches are harmless and are removed without a spurious restore error.
empty_batch="$OMNI_TRASH/empty-regression-batch"
mkdir -p -- "$empty_batch"
if ! undo_trash; then
    fail "undo_trash rejected an empty batch"
fi
[[ ! -e "$empty_batch" ]] || fail "empty trash batch was not cleaned up"

# Missing sources must not create a phantom trash batch.
before_batches=$(find "$OMNI_TRASH" -mindepth 1 -maxdepth 1 -type d | wc -l)
if ! trash "$WORK/does-not-exist"; then
    fail "trashing a missing source unexpectedly failed"
fi
after_batches=$(find "$OMNI_TRASH" -mindepth 1 -maxdepth 1 -type d | wc -l)
[[ "$before_batches" -eq "$after_batches" ]] || fail "missing source created a phantom trash batch"

# Emptying trash is recursive, confirmation-gated, and keeps the trash root.
mkdir -p -- "$OMNI_TRASH/empty-regression/nested"
printf 'permanent deletion fixture\n' > "$OMNI_TRASH/empty-regression/nested/item.txt"
cmd_yes_no() { cmd_reply=yes; }
if ! empty_trash; then
    fail "empty_trash returned failure after confirmed deletion"
fi
[[ -d "$OMNI_TRASH" ]] || fail "empty_trash removed the trash root"
[[ -z "$(find "$OMNI_TRASH" -mindepth 1 -print -quit)" ]] \
    || fail "empty_trash left entries behind"


# The loop backend must not leak shell glob options into its caller.
source "$ROOT/lib/70-loop.sh"
mkdir -p -- "$WORK/loop-list/visible-dir" "$WORK/loop-list/dir with spaces"
printf 'visible\n' > "$WORK/loop-list/visible file.txt"
printf 'hidden\n' > "$WORK/loop-list/.hidden-file"
(
    cd -- "$WORK/loop-list"
    rm -f -- "$CACHE_OMNISH_DIR/showhidden"
    shopt -u nullglob dotglob
    loop_read_dir
    [[ $(shopt -q nullglob; echo $?) -eq 1 ]] || fail "loop_read_dir leaked nullglob when initially disabled"
    [[ $(shopt -q dotglob; echo $?) -eq 1 ]] || fail "loop_read_dir leaked dotglob when initially disabled"
    [[ " ${loop_list[*]} " == *" visible file.txt "* ]] || fail "loop listing omitted a visible filename with spaces"
    [[ " ${loop_list[*]} " != *".hidden-file"* ]] || fail "hidden file appeared while showhidden was disabled"

    # An inherited dotglob must not expose hidden files when showhidden is off.
    shopt -s nullglob dotglob
    loop_read_dir
    [[ $(shopt -q nullglob; echo $?) -eq 0 ]] || fail "loop_read_dir disabled caller's nullglob"
    [[ $(shopt -q dotglob; echo $?) -eq 0 ]] || fail "loop_read_dir disabled caller's dotglob"
    [[ " ${loop_list[*]} " != *".hidden-file"* ]] || fail "inherited dotglob bypassed showhidden setting"

    touch "$CACHE_OMNISH_DIR/showhidden"
    loop_read_dir
    [[ " ${loop_list[*]} " == *".hidden-file"* ]] || fail "showhidden did not include hidden entries"
    shopt -u nullglob dotglob
)

printf 'PASS: runtime ownership, file-operation guards and trash restore regressions\n'
