# shellcheck shell=bash
# omnish — utilities
#
# [FIX Bug 1] trap cleanup was at module scope → every preview subprocess
#             deleted $TMP_OMNISH_DIR (including $MARKED_FILES_FILE). The trap
#             is now installed by fzf_main / loop_main only.
# [FIX Bug 2] INT/TERM handlers now call `exit`, so Ctrl-C actually quits.
# [FIX Bug 3] clean_path no longer strips backslashes that are part of the
#             filename; only fzf's shell-escaping backslashes are removed.

clean_path() {
    # Preserve filenames literally. Spaces, quotes and backslashes are valid
    # path characters; callers must pass the original path, never shell text.
    printf '%s' "$1"
}

_human_size() {
    local b=${1:-0}
    if   (( b >= 1073741824 )); then printf '%d.%dG' $((b/1073741824)) $(((b%1073741824)*10/1073741824))
    elif (( b >= 1048576 ));    then printf '%d.%dM' $((b/1048576))    $(((b%1048576)*10/1048576))
    elif (( b >= 1024 ));       then printf '%d.%dK' $((b/1024))       $(((b%1024)*10/1024))
    else                             printf '%dB' "$b"
    fi
}

get_term_size() {
    if [[ -t 1 ]]; then
        read -r LINES COLUMNS < <(stty size 2>/dev/null) || { LINES=24; COLUMNS=80; }
    else
        LINES=${LINES:-24}; COLUMNS=${COLUMNS:-80}
    fi
    # Shared with lib/20-ui.sh (cross-file global).
    # shellcheck disable=SC2034
    message_height=$(( LINES / 2 ))
    # Shared with lib/20-ui.sh (cross-file global).
    # shellcheck disable=SC2034
    message_width=$(( COLUMNS / 2 ))
}

# ===============================================================
# cleanup — restores terminal, persists cwd, removes temp dir.
# NOTE: This function is idempotent and safe to call from EXIT only.
#       Do NOT install it at module scope (would fire in every subcommand).
#       Installed by fzf_main() and loop_main() instead.
# ===============================================================
cleanup() {
    # Kill progress/spinner if 25-progress.sh is loaded
    if declare -F _progress_cleanup >/dev/null 2>&1; then
        _progress_cleanup
    fi

    # Persist cwd for parent shell (opt-in via OMNI_CD_ON_EXIT=1)
    if [[ ${OMNI_CD_ON_EXIT:-1} == 1 && -n ${OMNI_CD_FILE:-} && -d ${OMNI_CD_FILE%/*} ]]; then
        printf '%s\n' "$PWD" > "$OMNI_CD_FILE" 2>/dev/null
    fi

    # Remove temp dir last (subcommands must not do this)
    [[ -d "$TMP_OMNISH_DIR" ]] && rm -rf "$TMP_OMNISH_DIR" 2>/dev/null

    # Restore terminal
    printf '\e[?25h\e[0m' 2>/dev/null
    stty sane 2>/dev/null
}

# ===============================================================
# sync_marked_files — persist marks to disk.
# Called after any mark mutation in fzf_main / loop_main.
# ===============================================================
sync_marked_files() {
    if (( ${#marked_files[@]} > 0 )); then
        printf '%s\n' "${marked_files[@]}" > "$MARKED_FILES_FILE" 2>/dev/null
    else
        : > "$MARKED_FILES_FILE" 2>/dev/null
    fi
}

generate_mark_file() {
    marked_files=()
    sync_marked_files
}

# ===============================================================
# NOTE: `trap cleanup EXIT INT TERM` is DELIBERATELY NOT set here.
# It must be installed by the interactive entry points:
#
#   fzf_main()   →  trap 'cleanup' EXIT
#                   trap 'cleanup; exit 130' INT
#                   trap 'cleanup; exit 143' TERM
#
#   loop_main()  →  trap 'loop_reset_terminal; cleanup' EXIT
#                   trap 'loop_reset_terminal; cleanup; exit 130' INT
#                   trap 'loop_reset_terminal; cleanup; exit 143' TERM
#
# Rationale: 10-utils.sh is sourced by EVERY subcommand (`bash omnish
# --preview-file`, `--mark-file`, etc.). Installing the trap here would
# make each preview/action delete $TMP_OMNISH_DIR on exit, which wipes
# $MARKED_FILES_FILE and destroys every mark between fzf interactions.
# ===============================================================