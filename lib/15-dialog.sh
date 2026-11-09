# omnish — script-dialog integration
#
# Sources vendor/script-dialog/script-dialog.sh when OMNISH_HAS_SCRIPT_DIALOG=1
# (set by the entrypoint) and replaces three UI functions with native
# whiptail/dialog versions:
#
#   cmd_yes_no   → yesno   (blocking, sets $cmd_reply=yes|no)
#   cmd_line     → inputbox (blocking, sets $cmd_reply, returns 1 on cancel)
#   status_msg   → bash fallback only (kept non-blocking)
#
# Design decisions:
#   * We force TUI mode (whiptail/dialog). We never delegate to zenity/kdialog
#     because omnish runs inside a terminal and a separate window would break
#     the alt-screen.
#   * We detect the backend OURSELVES (before sourcing) instead of trusting
#     script-dialog's auto-detection, which may pick zenity/kdialog when
#     $DISPLAY is set.
#   * If neither whiptail nor dialog is available, we DON'T source the lib
#     and DON'T override anything. 20-ui.sh provides our own (better) bash
#     fallbacks with tab-completion and inline rendering.
#   * INTERFACE and GUI are preserved around the source so we don't pollute
#     the caller's environment.

# ------------------------------------------------------------------
# Idempotency guard
# ------------------------------------------------------------------
[[ -n "${_FF_DIALOG_LOADED:-}" ]] && return
_FF_DIALOG_LOADED=1

_FF_DIALOG_AVAILABLE=0
_FF_DIALOG_BACKEND=""
_FF_DIALOG_REASON=""

# ------------------------------------------------------------------
# Initialization
# ------------------------------------------------------------------
_ff_dialog_init() {
    [[ "${OMNISH_HAS_SCRIPT_DIALOG:-0}" == "1" ]] || {
        _FF_DIALOG_REASON="not vendored"
        return 1
    }

    local lib="$OMNISH_ROOT/vendor/script-dialog/script-dialog.sh"
    [[ -r "$lib" ]] || {
        _FF_DIALOG_REASON="lib missing: $lib"
        return 1
    }

    # [FIX 1] Detect native backend BEFORE sourcing.
    #         Trust our own detection, not the lib's (which may pick zenity).
    local detected=""
    if command -v whiptail >/dev/null 2>&1; then
        detected="whiptail"
    elif command -v dialog >/dev/null 2>&1; then
        detected="dialog"
    fi

    if [[ -z "$detected" ]]; then
        _FF_DIALOG_REASON="no whiptail/dialog in PATH"
        return 1
    fi

    # [FIX 2] Save caller's INTERFACE/GUI, force ours, source, restore.
    local _saved_interface="${INTERFACE-__unset__}"
    local _saved_gui="${GUI-__unset__}"
    INTERFACE="$detected"
    GUI=false

    # shellcheck disable=SC1090
    if ! source "$lib" 2>/dev/null; then
        _FF_DIALOG_REASON="source failed: $lib"
        if [[ "$_saved_interface" == "__unset__" ]]; then unset INTERFACE; else INTERFACE="$_saved_interface"; fi
        if [[ "$_saved_gui" == "__unset__" ]]; then unset GUI; else GUI="$_saved_gui"; fi
        return 1
    fi

    _FF_DIALOG_AVAILABLE=1
    _FF_DIALOG_BACKEND="$detected"

    # Restore caller's environment
    if [[ "$_saved_interface" == "__unset__" ]]; then unset INTERFACE; else INTERFACE="$_saved_interface"; fi
    if [[ "$_saved_gui" == "__unset__" ]]; then unset GUI; else GUI="$_saved_gui"; fi

    return 0
}

_ff_dialog_init || true

# ------------------------------------------------------------------
# Introspection helpers (used by --has-dialog, debug, tests)
# ------------------------------------------------------------------
_ff_dialog_available() { (( _FF_DIALOG_AVAILABLE )); }
_ff_dialog_backend()   { printf '%s\n' "${_FF_DIALOG_BACKEND:-none}"; }
_ff_dialog_reason()    { printf '%s\n' "${_FF_DIALOG_REASON:-}"; }

# ------------------------------------------------------------------
# Compatibility wrappers
# Only installed if a native dialog backend is available.
# 20-ui.sh will skip its own definitions thanks to `declare -F`.
# ------------------------------------------------------------------
if (( _FF_DIALOG_AVAILABLE )); then

    # --- cmd_yes_no --------------------------------------------------
    # Contract: sets $cmd_reply to "yes" or "no". Never blocks on errors.
    #
    # [FIX 3] Simplified: trust the exit code. Dialog/whiptail return
    #         0 for Yes, non-zero for No/Esc. We don't try to guess the
    #         user's intent from stdout (which varies between versions).
    #         The old "if no && default==y && rc!=1 → yes" logic was
    #         broken: it turned Esc into "yes" for safety-critical prompts.
    cmd_yes_no() {
        local prompt="$1" default="${2:-n}"
        local rc

        yesno "$prompt" 2>/dev/null
        rc=$?

        case "$rc" in
            0) cmd_reply=yes ;;
            *) cmd_reply=no  ;;
        esac
        return 0
    }

    # --- cmd_line ----------------------------------------------------
    # Contract: sets $cmd_reply to the entered string.
    # Returns 1 on cancel (Esc or Cancel button), 0 otherwise.
    # Note: tab-completion is lost with whiptail/dialog — that's the
    # trade-off for native dialogs. The bash fallback (20-ui.sh) keeps it.
    cmd_line() {
        local prompt="$1" mode="${2:-}"
        local val rc

        val=$(inputbox "$prompt" 2>/dev/null)
        rc=$?

        if (( rc != 0 )); then
            cmd_reply=""
            return 1
        fi
        cmd_reply="$val"
        return 0
    }

    # --- status_msg --------------------------------------------------
    # Kept as bash inline to guarantee non-blocking behavior.
    # whiptail/dialog --msgbox would steal the alt-screen, block for
    # the full timeout on every call, and cause visible flicker in loops.
    # We deliberately do NOT delegate this to script-dialog.
    status_msg() {
        local msg="${1//$'\n'/ }" wait="${2:-0.8}"
        printf '\e7\e[%sH\e[2K\e[33m%.*s\e[m\e8' \
            "${LINES:-24}" "${COLUMNS:-80}" "$msg"
        read -rsn 1 -t "$wait" _ 2>/dev/null
        printf '\e7\e[%sH\e[2K\e8' "${LINES:-24}"
    }

    # --- Native dialog helpers for other modules ---------------------
    # 45-system.sh can use these instead of fzf for its menus if desired.
    dialog_menu()  { menu         "$@"; }
    dialog_input() { inputbox     "$@"; }
    dialog_yesno() { yesno        "$@"; }
    dialog_msg()   { message-info "$@"; }
    dialog_error() { message-error "$@" 2>/dev/null || message-info "$@"; }

fi