#!/usr/bin/env bash
# Regression tests for lib/60-trash.sh.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/omnish-trash-tests.XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

OMNI_TRASH="$TEST_ROOT/trash"
export OMNI_TRASH
mkdir -p -- "$OMNI_TRASH"

status_msg() { :; }
spinner_begin() { :; }
spinner_end() { :; }
progress_begin() { :; }
progress_set() { :; }
progress_end() { :; }
# cmd_yes_no and the sourced trash module share this test double state.
# shellcheck disable=SC2034
cmd_reply=yes
cmd_yes_no() { cmd_reply=yes; }

# shellcheck source=../lib/60-trash.sh
source "$ROOT/lib/60-trash.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
pass() {
    printf 'PASS: %s\n' "$*"
}
reset_trash() {
    rm -rf -- "$OMNI_TRASH"
    mkdir -p -- "$OMNI_TRASH"
}
assert_file_content() {
    local path="$1" expected="$2" actual
    [[ -f "$path" ]] || fail "missing file: $path"
    actual=$(cat -- "$path")
    [[ "$actual" == "$expected" ]] || fail "unexpected content in: $path"
}
batch_payload_count() {
    local batch item count=0
    batch=$(find "$OMNI_TRASH" -mindepth 1 -maxdepth 1 -type d -print -quit)
    [[ -n "$batch" ]] || { printf '0'; return; }
    while IFS= read -r -d '' item; do
        [[ "${item##*/}" == ".omnish-meta" ]] && continue
        count=$((count + 1))
    done < <(find "$batch" -mindepth 1 -maxdepth 1 -print0)
    printf '%s' "$count"
}

# Path normalization must not trim or unquote valid filename characters.
# shellcheck source=../lib/10-utils.sh
source "$ROOT/lib/10-utils.sh"
spaced_name='  name with surrounding spaces  '
quoted_name="'literal quote' and \\backslash"
[[ "$(clean_path "$spaced_name")" == "$spaced_name" ]] || fail "clean_path trimmed spaces"
[[ "$(clean_path "$quoted_name")" == "$quoted_name" ]] || fail "clean_path altered literal quote/backslash characters"
pass "literal path characters"

# Replacing a symlink target must not pre-delete the existing data.
# shellcheck source=../lib/50-fileops.sh
source "$ROOT/lib/50-fileops.sh"
status_msg() { :; }
cmd_line() { cmd_reply="$INPUT_REPLY"; }
# shellcheck disable=SC2034
cmd_yes_no() { cmd_reply=yes; }

reset_trash
mkdir -p -- "$TEST_ROOT/symlink-ops"
cd -- "$TEST_ROOT/symlink-ops"
printf 'link source\n' > source.txt
printf 'existing destination\n' > destination
INPUT_REPLY=destination
create_symlink source.txt
[[ -L destination ]] || fail "existing file was not replaced by a symlink"
[[ "$(readlink -- destination)" == "$TEST_ROOT/symlink-ops/source.txt" ]] || fail "symlink target is incorrect"
pass "atomic symlink replacement"

# If an existing directory cannot be replaced, it must remain untouched.
mkdir -- existing-directory
printf 'preserve directory\n' > existing-directory/keep.txt
INPUT_REPLY=existing-directory
if create_symlink source.txt; then
    fail "unexpectedly replaced a directory with a symlink"
fi
assert_file_content "existing-directory/keep.txt" "preserve directory"
pass "failed symlink replacement preserves existing directory"

# A normal item must return to the absolute path from which it was trashed.
reset_trash
mkdir -p -- "$TEST_ROOT/original" "$TEST_ROOT/elsewhere"
printf 'original data\n' > "$TEST_ROOT/original/hello world.txt"
cd -- "$TEST_ROOT/elsewhere"
trash "$TEST_ROOT/original/hello world.txt"
[[ ! -e "$TEST_ROOT/original/hello world.txt" ]] || fail "trash did not move file"
undo_trash
assert_file_content "$TEST_ROOT/original/hello world.txt" "original data"
pass "restore to original absolute path"

# An absent original parent must not be recreated; the payload must stay safe.
reset_trash
mkdir -p -- "$TEST_ROOT/vanishing/subdir"
printf 'keep me\n' > "$TEST_ROOT/vanishing/subdir/item.txt"
trash "$TEST_ROOT/vanishing/subdir/item.txt"
rmdir -- "$TEST_ROOT/vanishing/subdir"
if undo_trash; then
    fail "restore unexpectedly succeeded with a missing parent"
fi
[[ "$(batch_payload_count)" == 1 ]] || fail "item was not kept in trash"
[[ ! -d "$TEST_ROOT/vanishing/subdir" ]] || fail "missing directory was recreated"
mkdir -- "$TEST_ROOT/vanishing/subdir"
undo_trash
assert_file_content "$TEST_ROOT/vanishing/subdir/item.txt" "keep me"
pass "missing original directory leaves data in trash"

# A destination collision must leave both the existing file and trashed item intact.
reset_trash
mkdir -p -- "$TEST_ROOT/collision"
printf 'from trash\n' > "$TEST_ROOT/collision/same.txt"
trash "$TEST_ROOT/collision/same.txt"
printf 'existing data\n' > "$TEST_ROOT/collision/same.txt"
undo_trash
assert_file_content "$TEST_ROOT/collision/same.txt" "existing data"
[[ "$(batch_payload_count)" == 1 ]] || fail "collision removed trashed payload"
rm -- "$TEST_ROOT/collision/same.txt"
undo_trash
assert_file_content "$TEST_ROOT/collision/same.txt" "from trash"
pass "destination collision does not overwrite data"

# Two different paths with one basename must both survive a single batch.
reset_trash
mkdir -p -- "$TEST_ROOT/one" "$TEST_ROOT/two"
printf 'one\n' > "$TEST_ROOT/one/duplicate.txt"
printf 'two\n' > "$TEST_ROOT/two/duplicate.txt"
trash "$TEST_ROOT/one/duplicate.txt" "$TEST_ROOT/two/duplicate.txt"
[[ "$(batch_payload_count)" == 2 ]] || fail "same-basename payload collision"
undo_trash
assert_file_content "$TEST_ROOT/one/duplicate.txt" "one"
assert_file_content "$TEST_ROOT/two/duplicate.txt" "two"
pass "duplicate basenames in one batch"

# Broken symlinks are valid payloads and must be restored as symlinks.
reset_trash
mkdir -p -- "$TEST_ROOT/symlinks"
ln -s -- "$TEST_ROOT/does-not-exist" "$TEST_ROOT/symlinks/dangling-link"
trash "$TEST_ROOT/symlinks/dangling-link"
[[ ! -L "$TEST_ROOT/symlinks/dangling-link" ]] || fail "broken symlink was not moved"
undo_trash
[[ -L "$TEST_ROOT/symlinks/dangling-link" ]] || fail "broken symlink was not restored"
pass "broken symlink restore"

# Newlines in the basename and in its parent path must survive metadata parsing.
reset_trash
newline_dir="$TEST_ROOT/parent"$'\n'"with-newline"
newline_file="$newline_dir/file"$'\n'"name.txt"
mkdir -p -- "$newline_dir"
printf 'newline data\n' > "$newline_file"
trash "$newline_file"
undo_trash
assert_file_content "$newline_file" "newline data"
pass "newline characters in stored paths"

# Legacy batches have no metadata and retain the historical cwd restore behavior.
reset_trash
mkdir -p -- "$OMNI_TRASH/legacy-batch" "$TEST_ROOT/legacy-destination"
printf 'legacy\n' > "$OMNI_TRASH/legacy-batch/legacy.txt"
cd -- "$TEST_ROOT/legacy-destination"
undo_trash
assert_file_content "$TEST_ROOT/legacy-destination/legacy.txt" "legacy"
pass "legacy batch compatibility"

# Guard against accidentally trashing dot entries, the trash root, or its parent.
reset_trash
mkdir -p -- "$TEST_ROOT/guarded"
cd -- "$TEST_ROOT/guarded"
if trash ..; then fail "accepted dot-dot path"; fi
if trash "$OMNI_TRASH"; then fail "accepted trash root"; fi
if trash "$TEST_ROOT"; then fail "accepted parent containing trash root"; fi
[[ -d "$TEST_ROOT" && -d "$OMNI_TRASH" ]] || fail "guard removed a protected directory"
pass "protected trash paths"

# A symlink-only batch must also be removable by empty_trash.
reset_trash
mkdir -p -- "$OMNI_TRASH/symlink-only"
ln -s -- "$TEST_ROOT/missing-target" "$OMNI_TRASH/symlink-only/dangling"
empty_trash
[[ -z "$(find "$OMNI_TRASH" -mindepth 1 -print -quit)" ]] || fail "empty_trash left symlink-only entries"
pass "empty symlink-only trash"

printf '\nAll trash regression tests passed.\n'
