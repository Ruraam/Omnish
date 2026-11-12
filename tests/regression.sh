#!/usr/bin/env bash
# Focused regression tests for runtime ownership, file operations and trash.
set -euo pipefail
trap 'rc=$?; printf "FAIL: regression command at line %s (exit %s): %s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2; exit "$rc"' ERR

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
source "$ROOT/lib/30-preview.sh"
source "$ROOT/lib/65-scratchpad.sh"

status_msg() { :; }
spinner_begin() { :; }
spinner_end() { :; }
source "$ROOT/lib/50-fileops.sh"
source "$ROOT/lib/60-trash.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}


# Chafa image protocol selection is passive and backend-safe.
mkdir -p -- "$WORK/image-bin"
cat > "$WORK/image-bin/chafa" <<'EOF_CHAFA'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CHAFA_ARGS_LOG"
if [[ "${CHAFA_FAIL_FORMAT:-}" == *"$2"* && "$1" == --format=* ]]; then
    exit 1
fi
exit 0
EOF_CHAFA
chmod +x "$WORK/image-bin/chafa"
export CHAFA_ARGS_LOG="$WORK/chafa-args.log"
: > "$CHAFA_ARGS_LOG"
PATH="$WORK/image-bin:$PATH"

unset OMNISH_IMAGE_FORMAT KITTY_PID
export TERM=xterm-kitty
[[ "$(_preview_detect_image_format)" == kitty ]] || fail "Kitty was not detected from TERM"
export KITTY_PID=123
export TERM=xterm-kitty
[[ "$(_preview_detect_image_format)" == kitty ]] || fail "Kitty was not detected from KITTY_PID"
unset KITTY_PID
export TERM=xterm-256color
export TERM_PROGRAM=iTerm.app
[[ "$(_preview_detect_image_format)" == iterm ]] || fail "iTerm2 was not detected passively"
export TERM_PROGRAM=WezTerm
[[ "$(_preview_detect_image_format)" == sixel ]] || fail "WezTerm Sixel capability was not detected passively"
unset TERM_PROGRAM
export TERM=foot
[[ "$(_preview_detect_image_format)" == sixel ]] || fail "foot Sixel capability was not detected passively"
export TERM=xterm-256color
[[ "$(_preview_detect_image_format)" == symbols ]] || fail "unknown terminal did not use safe symbols fallback"

# Chafa names its 24-bit mode "full", not "24bit". Exercise the fzf
# symbols path with a truecolor terminal so fallback rendering stays valid.
: > "$CHAFA_ARGS_LOG"
OMNISH_IMAGE_FORMAT=symbols
OMNISH_PREVIEW_BACKEND=fzf
COLORTERM=truecolor
_preview_image "$WORK/fixture.png" 48 18 || fail "truecolor symbols preview failed"
grep -Fq -- '--colors=full' "$CHAFA_ARGS_LOG" || fail "truecolor symbols preview did not use Chafa's full color mode"
unset OMNISH_IMAGE_FORMAT COLORTERM OMNISH_PREVIEW_BACKEND

# loop must remain textual, but use the high-detail Chafa glyph and color pipeline.
: > "$CHAFA_ARGS_LOG"
KITTY_PID=123
OMNISH_PREVIEW_BACKEND=loop
OMNISH_IMAGE_QUALITY=high
_preview_image "$WORK/fixture.png" 40 16 || fail "loop Chafa preview failed"
grep -Fq -- '--format=symbols' "$CHAFA_ARGS_LOG" || fail "loop did not force symbols"
grep -Fq -- '--symbols=block+border+diagonal+dot+quad+half+braille+geometric+inverted' "$CHAFA_ARGS_LOG" || fail "loop did not enable detailed glyphs"
grep -Fq -- '--colors=full' "$CHAFA_ARGS_LOG" || fail "loop did not force 24bit colour"
grep -Fq -- '--work=9' "$CHAFA_ARGS_LOG" || fail "high quality did not use Chafa work level 9"
grep -Fq -- '--color-space=din99d' "$CHAFA_ARGS_LOG" || fail "high quality did not use perceptual color space"
grep -Fq -- '--color-extractor=median' "$CHAFA_ARGS_LOG" || fail "high quality did not use median color extraction"
! grep -Eq -- '--format=(kitty|sixel|iterm)' "$CHAFA_ARGS_LOG" || fail "loop emitted a graphical protocol"
: > "$CHAFA_ARGS_LOG"
OMNISH_IMAGE_QUALITY=fast
_preview_image "$WORK/fixture.png" 40 16 || fail "fast loop Chafa preview failed"
grep -Fq -- '--work=2' "$CHAFA_ARGS_LOG" || fail "fast quality did not reduce Chafa work"
grep -Fq -- '--colors=full' "$CHAFA_ARGS_LOG" || fail "loop fast quality did not preserve 24bit colour"
OMNISH_IMAGE_QUALITY=high

# fzf can use Kitty directly; a failed protocol falls back to safe symbols.
: > "$CHAFA_ARGS_LOG"
OMNISH_PREVIEW_BACKEND=fzf
_preview_image "$WORK/fixture.png" 48 18 || fail "fzf Chafa preview failed"
grep -Fq -- '--format=kitty' "$CHAFA_ARGS_LOG" || fail "fzf did not select Kitty graphics"
: > "$CHAFA_ARGS_LOG"
cat > "$WORK/image-bin/chafa" <<'EOF_CHAFA_FAIL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CHAFA_ARGS_LOG"
[[ "$1" == --format=kitty ]] && exit 1
exit 0
EOF_CHAFA_FAIL
chmod +x "$WORK/image-bin/chafa"
_preview_image "$WORK/fixture.png" 48 18 || fail "fzf did not fall back after a protocol render failure"
grep -Fq -- '--format=symbols' "$CHAFA_ARGS_LOG" || fail "fzf protocol failure did not fall back to symbols"
# Failed image rendering must never fall through to raw SVG/XML or image bytes.
cat > "$WORK/image-bin/chafa" <<'EOF_CHAFA_FAIL_ALL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CHAFA_ARGS_LOG"
exit 2
EOF_CHAFA_FAIL_ALL
chmod +x "$WORK/image-bin/chafa"
printf '<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>\n' > "$WORK/fixture.svg"
printf '\211PNG\r\n\032\n' > "$WORK/fixture.png"
for image in "$WORK/fixture.svg" "$WORK/fixture.png"; do
    image_preview_output=$(_preview_file "$image")
    [[ "$image_preview_output" == *"image preview unavailable"* ]] || fail "failed image rendering did not show a clear diagnostic"
    [[ "$image_preview_output" != *"<svg"* ]] || fail "failed SVG preview leaked XML source"
    [[ "$image_preview_output" != *"PNG"* ]] || fail "failed PNG preview leaked binary signature"
done

unset KITTY_PID OMNISH_PREVIEW_BACKEND
export TERM=xterm-256color

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
# Mark reload is a successful operation for both empty and populated files.
: > "$MARKED_FILES_FILE"
if ! loop_reload_marks_from_disk; then fail "empty mark reload returned failure"; fi
printf '%s\n' "$WORK/loop-list/visible file.txt" > "$MARKED_FILES_FILE"
if ! loop_reload_marks_from_disk; then fail "populated mark reload returned failure"; fi
declare -p marked_files | grep -Fq -- "$WORK/loop-list/visible file.txt" || fail "populated mark reload lost its entry"
mkdir -p -- "$WORK/loop-list/visible-dir" "$WORK/loop-list/dir with spaces"
printf 'visible\n' > "$WORK/loop-list/visible file.txt"
printf 'hidden\n' > "$WORK/loop-list/.hidden-file"
(
    cd -- "$WORK/loop-list"
    rm -f -- "$CACHE_OMNISH_DIR/showhidden"
    shopt -u nullglob dotglob
    loop_read_dir
    if shopt -q nullglob; then fail "loop_read_dir leaked nullglob when initially disabled"; fi
    if shopt -q dotglob; then fail "loop_read_dir leaked dotglob when initially disabled"; fi
    [[ " ${loop_list[*]} " == *"visible file.txt"* ]] || fail "loop listing omitted a visible filename with spaces"
    [[ " ${loop_list[*]} " != *".hidden-file"* ]] || fail "hidden file appeared while showhidden was disabled"

    # An inherited dotglob must not expose hidden files when showhidden is off.
    shopt -s nullglob dotglob
    loop_read_dir
    shopt -q nullglob || fail "loop_read_dir disabled caller's nullglob"
    shopt -q dotglob || fail "loop_read_dir disabled caller's dotglob"
    [[ " ${loop_list[*]} " != *".hidden-file"* ]] || fail "inherited dotglob bypassed showhidden setting"

    touch "$CACHE_OMNISH_DIR/showhidden"
    loop_read_dir
    [[ " ${loop_list[*]} " == *".hidden-file"* ]] || fail "showhidden did not include hidden entries"
    shopt -u nullglob dotglob
)


# Responsive layout policy: both backends keep the side preview from 70 columns
# upward. Portrait is balanced 50/50; landscape gives 60% to the preview.
get_term_size() { LINES=$TEST_LINES; COLUMNS=$TEST_COLUMNS; }
loop_print_line() { :; }
loop_draw_preview() { :; }
loop_status_line() { :; }
loop_hide_cursor() { :; }
loop_clear_scroll() { :; }
loop_total=0
loop_scroll=0
loop_list=("fixture")
TEST_LINES=24
TEST_COLUMNS=68
loop_draw
[[ "$loop_preview_visible" -eq 0 && "$loop_list_width" -eq 66 ]] || fail "loop very narrow layout did not use the full list width"
TEST_LINES=24
TEST_COLUMNS=80
loop_draw
[[ "$loop_preview_visible" -eq 1 && "$loop_list_width" -eq 30 && "$loop_preview_width" -eq 46 ]] || fail "loop landscape 80-column layout did not allocate 40/60 panes"
TEST_LINES=24
TEST_COLUMNS=120
loop_draw
[[ "$loop_preview_visible" -eq 1 && "$loop_list_width" -eq 46 && "$loop_preview_width" -eq 70 ]] || fail "loop wide landscape layout did not allocate 40/60 panes"
TEST_LINES=100
TEST_COLUMNS=80
loop_draw
[[ "$loop_preview_visible" -eq 1 && "$loop_list_width" -eq 38 && "$loop_preview_width" -eq 38 ]] || fail "loop portrait layout did not preserve the 50/50 split"
TEST_LINES=8
TEST_COLUMNS=120
loop_draw
[[ "$loop_preview_visible" -eq 0 ]] || fail "loop short layout did not hide the preview pane"
grep -Fq 'COLUMNS < 70 || LINES < 10' "$ROOT/lib/70-fzf.sh" || fail "fzf compact-terminal preview breakpoint is missing"
# fzf must use the same adaptive width policy as loop, while preserving
# explicit user overrides and returning cancellation to its caller.
source "$ROOT/lib/70-fzf.sh"
[[ "$(fzf_preview_width 120 24 "")" == 72 ]] || fail "fzf landscape preview did not receive 60% width"
[[ "$(fzf_preview_width 80 100 "")" == 40 ]] || fail "fzf portrait preview did not receive 50% width"
[[ "$(fzf_preview_width 120 24 55)" == 55 ]] || fail "fzf ignored an explicit preview width"
[[ "$(fzf_preview_width 120 24 90)" == 72 ]] || fail "fzf did not cap an explicit width to the adaptive maximum"

# A real fzf abort exits with status 130. fzf_binds must propagate that
# status so fzf_main breaks rather than reopening an empty selection.
mkdir -p -- "$WORK/fake-bin"
cat > "$WORK/fake-bin/fzf" <<'EOF_FZF'
#!/usr/bin/env bash
exit 130
EOF_FZF
chmod +x "$WORK/fake-bin/fzf"
safe_ls() { printf 'fixture.txt\n'; }
f_header_text() { printf 'test header'; }
COLUMNS=120
LINES=24
if PATH="$WORK/fake-bin:$PATH" fzf_binds "$WORK"; then
    fail "fzf abort status 130 was not propagated"
fi

# Tab, Space and Shift-Tab must mutate the same persistent mark set.
mkdir -p -- "$WORK/loop-select"
printf "one\n" > "$WORK/loop-select/one.txt"
printf "two\n" > "$WORK/loop-select/two.txt"
loop_list=("$WORK/loop-select/one.txt" "$WORK/loop-select/two.txt")
loop_total=1
loop_scroll=0
marked_files=()
loop_draw() { :; }
tab_key=$(printf '\011')
sync_marked_files
loop_handle_key "$tab_key"
[[ "${#marked_files[@]}" -eq 1 && "${marked_files[0]}" == "$WORK/loop-select/one.txt" ]] || fail "loop Tab did not persist the current selection (key=$(printf \"%q\" \"$tab_key\"), count=${#marked_files[@]}, first=${marked_files[0]:-none})"
[[ "$loop_scroll" -eq 1 ]] || fail "loop Tab did not advance to the next entry"
loop_handle_key ' '
[[ "${#marked_files[@]}" -eq 2 ]] || fail "loop Space did not add the current selection"
loop_handle_key SHIFT_TAB
[[ "${#marked_files[@]}" -eq 1 && "${marked_files[0]}" == "$WORK/loop-select/one.txt" ]] || fail "loop Shift-Tab did not toggle the current selection off"
grep -Fq -- "tab:toggle+down+execute-silent" "$ROOT/lib/70-fzf.sh" || fail "fzf Tab is not synchronized with persistent marks"
grep -Fq -- "shift-tab:toggle+up+execute-silent" "$ROOT/lib/70-fzf.sh" || fail "fzf Shift-Tab is not synchronized with persistent marks"
grep -Fq -- "space:toggle+execute-silent" "$ROOT/lib/70-fzf.sh" || fail "fzf Space is not synchronized with persistent marks"

# SIGWINCH is deferred to the main loop; the trap itself never draws.
resize_draws=0
resize_size_reads=0
get_term_size() { ((resize_size_reads+=1)); LINES=40; COLUMNS=120; }
loop_draw() { ((resize_draws+=1)); }
loop_resize_pending=0
loop_process_resize
[[ "$resize_draws" -eq 0 && "$resize_size_reads" -eq 0 ]] || fail "loop processed a resize without a pending SIGWINCH"
loop_resize_pending=1
loop_process_resize
[[ "$resize_draws" -eq 1 && "$resize_size_reads" -eq 1 ]] || fail "loop did not process a deferred SIGWINCH"
[[ "$loop_resize_pending" -eq 0 ]] || fail "loop did not clear the pending resize flag"


# Scratchpad persistence, permissions, path insertion and clipboard import.
scratch_file="$(scratchpad_prepare)"
[[ "$scratch_file" == "$XDG_DATA_HOME/omnish/scratchpad.md" ]] || fail "scratchpad ignored XDG_DATA_HOME"
[[ "$(stat -c '%a' "$scratch_file")" == 600 ]] || fail "scratchpad was not created mode 600"
scratchpad_append '### Note' 'sha256: deadbeef'
scratchpad_append '- [ ] TODO' 'review the pending patch'
[[ "$(stat -c '%a' "$scratch_file")" == 600 ]] || fail "scratchpad permissions changed after append"
grep -Fq 'sha256: deadbeef' "$scratch_file" || fail "scratchpad note was not persisted"
grep -Fq -- '- [ ] TODO' "$scratch_file" || fail "scratchpad TODO was not persisted"
(
    cd -- "$WORK"
    scratchpad_insert_path 'path with spaces.txt'
)
grep -Fq "\`$WORK/path with spaces.txt\`" "$scratch_file" || fail "scratchpad did not insert selected path safely"
wl-paste() { printf 'clipboard payload'; }
scratchpad_insert_clipboard || fail "scratchpad clipboard import failed with wl-paste"
grep -Fq 'clipboard payload' "$scratch_file" || fail "scratchpad clipboard payload was not appended"

wl-paste() { return 1; }
xclip() { printf 'xclip fallback payload'; }
xsel() { printf 'xsel must not win'; }
termux-clipboard-get() { printf 'Termux must not win'; }
scratchpad_insert_clipboard || fail "scratchpad did not fall back from wl-paste to xclip"
grep -Fq 'xclip fallback payload' "$scratch_file" || fail "xclip fallback payload missing"
xclip() { return 1; }
xsel() { printf 'xsel fallback payload'; }
scratchpad_insert_clipboard || fail "scratchpad did not fall back to xsel"
grep -Fq 'xsel fallback payload' "$scratch_file" || fail "xsel fallback payload missing"
xsel() { return 1; }
termux-clipboard-get() { printf 'Termux fallback payload'; }
scratchpad_insert_clipboard || fail "scratchpad did not fall back to Termux clipboard"
grep -Fq 'Termux fallback payload' "$scratch_file" || fail "Termux fallback payload missing"
termux-clipboard-get() { return 1; }
before_size="$(wc -c < "$scratch_file")"
if scratchpad_insert_clipboard; then fail "missing clipboard provider was not a graceful no-op"; fi
after_size="$(wc -c < "$scratch_file")"
[[ "$before_size" == "$after_size" ]] || fail "empty clipboard changed scratchpad contents"

rm -f -- "$scratch_file"
ln -s -- "$WORK/target" "$scratch_file"
if scratchpad_prepare >/dev/null 2>&1; then fail "scratchpad followed a symlink"; fi
rm -f -- "$scratch_file"

# Quick Archive format detection and read-only index support.
source "$ROOT/lib/55-archive.sh"
archive_fixture="$WORK/archive-fixture"
mkdir -p -- "$archive_fixture/nested"
printf 'archive payload\n' > "$archive_fixture/nested/file with spaces.txt"
archive_file="$WORK/quick-archive-fixture.tar.gz"
tar -czf "$archive_file" -C "$archive_fixture" .
archive_is_supported "$archive_file" || fail "tar.gz was not detected as an archive"
archive_is_supported "$WORK/future.lpk" || fail "future .lpk extension was not recognized"
if archive_is_supported "$WORK/not-an-archive.txt"; then fail "plain text file was classified as an archive"; fi
archive_index="$(_archive_list_to "$archive_file")"
[[ "$archive_index" == *"nested/file with spaces.txt"* ]] || fail "tar archive index omitted nested member"
[[ "$(_archive_stream_member "$archive_file" "./nested/file with spaces.txt")" == "archive payload" ]] || fail "archive member streaming failed for ./ paths"
cp -- "$archive_file" "$WORK/future.lpk"
[[ "$(_archive_kind "$WORK/future.lpk")" == tar ]] || fail "tar-backed .lpk detection failed"
_omnish_select() { printf '%s\n' 'tar.gz — compatible'; }
cmd_line() { cmd_reply="$WORK/created-quick-archive"; }
marked_files=("$archive_fixture/nested/file with spaces.txt")
quick_archive
[[ -f "$WORK/created-quick-archive.tar.gz" ]] || fail "Quick Archive did not create tar.gz output"
tar -tzf "$WORK/created-quick-archive.tar.gz" | grep -Fxq "./file with spaces.txt" || fail "Quick Archive did not store a clean relative member path"

printf 'PASS: runtime ownership, file-operation guards, scratchpad and trash restore regressions\n'
