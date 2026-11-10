#!/usr/bin/env bash
# Regression tests for the fzf and pure-Bash loop backends.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/omnish-backend-tests.XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

CACHE_OMNISH_DIR="$TEST_ROOT/cache"
TMP_OMNISH_DIR="$TEST_ROOT/runtime"
MARKED_FILES_FILE="$TMP_OMNISH_DIR/marked_files"
MARGIN_PREVIEW="$CACHE_OMNISH_DIR/margin_preview"
SCRIPT_PATH="$TEST_ROOT/omnish entrypoint"
OMNISH_VERSION="3.0.0"
YELLOW=''
NC=''
mkdir -p -- "$CACHE_OMNISH_DIR" "$TMP_OMNISH_DIR"
: > "$MARKED_FILES_FILE"
printf '55%%\n' > "$MARGIN_PREVIEW"
touch -- "$SCRIPT_PATH"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
pass() {
    printf 'PASS: %s\n' "$*"
}

# ---- loop backend: directory enumeration and split-pane rendering ----
source "$ROOT/lib/70-loop.sh"

tree="$TEST_ROOT/tree with spaces"
mkdir -p -- "$tree/a-directory"
printf 'file payload\n' > "$tree/plain file.txt"
printf 'hidden payload\n' > "$tree/.hidden-entry"
ln -s -- "$TEST_ROOT/missing-target" "$tree/dangling-link"

cd -- "$tree"
loop_list=()
loop_marks=()
marked_files=()
loop_scroll=0
loop_total=0
loop_find_previous=0
loop_prev_idx=0
loop_show_help=0

# The listing function must not leak nullglob/dotglob changes to callers.
shopt -u nullglob dotglob
loop_read_dir
[[ ! -o nullglob && ! -o dotglob ]] || fail "loop_read_dir changed shell glob options"

[[ "${loop_list[0]:-}" == "$tree/a-directory" ]] || fail "directories are not listed first"
[[ " ${loop_list[*]} " == *" $tree/plain file.txt "* ]] || fail "filename with spaces is missing"
[[ " ${loop_list[*]} " == *" $tree/dangling-link "* ]] || fail "dangling symlink is missing"
[[ " ${loop_list[*]} " != *" $tree/.hidden-entry "* ]] || fail "hidden file shown while hidden mode is off"
pass "loop directory enumeration"

touch -- "$CACHE_OMNISH_DIR/showhidden"
loop_read_dir
[[ " ${loop_list[*]} " == *" $tree/.hidden-entry "* ]] || fail "hidden file not shown when enabled"
pass "loop hidden-file toggle"

# Use deterministic dimensions and a harmless preview renderer. Capture the
# ANSI output to assert that both columns receive content on the first draw.
get_term_size() {
    LINES=18
    COLUMNS=80
}
_preview_file() {
    printf 'live preview: %s\n' "${1##*/}"
}
for i in "${!loop_list[@]}"; do
    if [[ "${loop_list[i]##*/}" == "plain file.txt" ]]; then
        loop_scroll="$i"
        break
    fi
done
rendered=$(loop_draw full)
[[ "$rendered" == *"plain file.txt"* ]] || fail "loop left pane did not render file entries"
[[ "$rendered" == *"│"* ]] || fail "loop split divider was not rendered"
[[ "$rendered" == *"live preview: plain file.txt"* ]] || fail "loop right pane did not render the selected file preview"
[[ "$rendered" == *$'\e[1;1H'* ]] || fail "loop redraw did not clear from the top-left origin"
pass "loop split-pane list and live preview"

# ---- fzf backend: command construction and preview placeholder safety ----
source "$ROOT/lib/70-fzf.sh"

clean_path() { printf '%s' "$1"; }
help() { printf 'test help\n'; }
FZF_ARGS_FILE="$TEST_ROOT/fzf-args"
FZF_INPUT_FILE="$TEST_ROOT/fzf-input"
FZF_PREVIEW_FILE="$TEST_ROOT/fzf-preview-command"
export FZF_ARGS_FILE FZF_INPUT_FILE FZF_PREVIEW_FILE

fzf() {
    local capture_preview=0 arg
    : > "$FZF_ARGS_FILE"
    for arg in "$@"; do
        printf '%s\n' "$arg" >> "$FZF_ARGS_FILE"
        if (( capture_preview )); then
            printf '%s' "$arg" > "$FZF_PREVIEW_FILE"
            capture_preview=0
        fi
        [[ "$arg" == "--preview" ]] && capture_preview=1
    done
    cat > "$FZF_INPUT_FILE"
    printf 'enter\nplain file.txt\n'
}

LINES=40
COLUMNS=120
rm -f -- "$CACHE_OMNISH_DIR/showhidden" "$CACHE_OMNISH_DIR/hidepreview"
: > "$TMP_OMNISH_DIR/marked_files"
marked_files=()
selected=''
fzf_binds "$tree" || fail "fzf_binds returned failure"

[[ "$selected" == $'enter\nplain file.txt' ]] || fail "fzf selection output was not preserved"
grep -Fq -- "plain file.txt" "$FZF_INPUT_FILE" || fail "fzf input list omitted filenames with spaces"
preview_command=$(<"$FZF_PREVIEW_FILE")
[[ "$preview_command" == *"--preview-file \"$tree\"/{}"* ]] || fail "fzf preview placeholder is incorrectly quoted"
[[ "$preview_command" != *"--preview-file \"$tree/{}\""* ]] || fail "fzf preview wraps the escaped placeholder in quotes"
grep -Fxq -- "right:55%:noborder" "$FZF_ARGS_FILE" || fail "fzf did not receive the configured split preview width"
grep -Fq -- "╭─ omnish" "$FZF_ARGS_FILE" || fail "fzf header ignored the actual terminal height"
pass "fzf split-pane preview command and sizing"

printf '\nAll backend regression tests passed.\n'
