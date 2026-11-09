# omnish — inline UI (P0)
# Functions here are fallbacks. If 15-dialog.sh loaded script-dialog,
# its wrappers take precedence (guarded by `declare -F`).
#
# [FIX 1] cmd_yes_no: prompt hint is [Y/n] when default=y (was [y/N] always).
# [FIX 2] cmd_line: returns 1 on Esc/Cancel (was 0). Matches 15-dialog.
# [FIX 3] cmd_line: preserves any pre-set $cmd_reply as an initial value.
# [FIX 4] cmd_line: `~` is only expanded at position 0 (was: anywhere).
# [FIX 5] dialog_help: falls back to dialog(1), then $PAGER, then cat.
# [FIX 6] status_msg: adds ellipsis when truncating; guards LINES/COLUMNS=0.
# [FIX 7] messages: guarded by declare -F (avoid clobber if another module
#                    defined it, e.g. 15-dialog in a future version).

# ------------------------------------------------------------------
# status_msg — non-blocking toast on the last terminal line
# ------------------------------------------------------------------
if ! declare -F status_msg >/dev/null 2>&1; then
    status_msg() {
        local msg="${1//$'\n'/ }" wait="${2:-0.8}"
        local cols="${COLUMNS:-80}" lines="${LINES:-24}"
        (( cols  > 0 )) || cols=80
        (( lines > 0 )) || lines=24

        local display="$msg"
        if (( ${#msg} > cols )); then
            display="${msg:0:cols-1}…"
        fi

        printf '\e7\e[%sH\e[2K\e[33m%s\e[m\e8' "$lines" "$display"
        read -rsn 1 -t "$wait" _ 2>/dev/null
        printf '\e7\e[%sH\e[2K\e8' "$lines"
    }
fi

# ------------------------------------------------------------------
# cmd_yes_no — single-key yes/no prompt
# ------------------------------------------------------------------
if ! declare -F cmd_yes_no >/dev/null 2>&1; then
    cmd_yes_no() {
        local prompt="$1" default="${2:-n}"
        local hint="[y/N]" lines="${LINES:-24}"
        (( lines > 0 )) || lines=24
        [[ "$default" == "y" ]] && hint="[Y/n]"

        printf '\e[%sH\e[2K\e[?25h%s %s ' "$lines" "$prompt" "$hint"
        IFS= read -rsn 1 cmd_reply
        printf '\e[2K\e[?25l'

        case "${cmd_reply:-$default}" in
            [yY]*) cmd_reply=yes ;;
            *)     cmd_reply=no  ;;
        esac
        return 0
    }
fi

# ------------------------------------------------------------------
# cmd_line — inline input with tab-completion
# ------------------------------------------------------------------
if ! declare -F cmd_line >/dev/null 2>&1; then
    cmd_line() {
        local prompt="$1" mode="${2:-}"
        local comp=() c=0 read_reply comp_glob lines="${LINES:-24}"
        local initial="${cmd_reply:-}"
        (( lines > 0 )) || lines=24

        cmd_reply="$initial"
        printf '\e[%sH\e[2K\e[?25h%s%s' "$lines" "$prompt" "$cmd_reply"

        while IFS= read -rsn 1 read_reply; do
            case "$read_reply" in
                $'\177'|$'\b')
                    cmd_reply=${cmd_reply%?}
                    unset 'comp' c
                    ;;
                $'\t')
                    comp_glob="$cmd_reply*"
                    [[ $mode == dirs ]] && comp_glob="$cmd_reply*/"
                    if [[ -z ${comp[0]:-} ]]; then
                        IFS=$'\n' read -d '' -ra comp < <(compgen -G "$comp_glob" 2>/dev/null)
                    fi
                    if [[ -n ${comp[c]:-} ]]; then
                        cmd_reply=${comp[c]}
                        (( c = c >= ${#comp[@]}-1 ? 0 : ++c ))
                    fi
                    ;;
                $'\e')
                    # Consume any trailing bytes of the escape sequence
                    # (arrow keys, F-keys, Alt-x, etc.) and treat as Cancel.
                    read -rsn 2 -t 0.05 _ 2>/dev/null
                    cmd_reply=""
                    printf '\e[2K\e[?25l'
                    return 1
                    ;;
                "")
                    # Enter pressed — commit the value
                    break
                    ;;
                "~")
                    # Only expand ~ at the start of the input
                    if [[ -z "$cmd_reply" ]]; then
                        cmd_reply+=$HOME
                    else
                        cmd_reply+="~"
                    fi
                    ;;
                *)
                    cmd_reply+=$read_reply
                    unset 'comp' c
                    ;;
            esac
            printf '\e[%sH\e[2K%s%s' "$lines" "$prompt" "$cmd_reply"
        done
        printf '\e[2K\e[?25l'
        return 0
    }
fi

# ------------------------------------------------------------------
# messages — thin wrapper around status_msg (formatted [TAG] message)
# ------------------------------------------------------------------
if ! declare -F messages >/dev/null 2>&1; then
    messages() {
        status_msg "[$1] $2"
    }
fi

# ------------------------------------------------------------------
# dialog_help — full help text, native TUI if available, else pager
# ------------------------------------------------------------------
if ! declare -F dialog_help >/dev/null 2>&1; then
    dialog_help() {
        local helpfile="${TMP_OMNISH_DIR}/help.txt"
        help > "$helpfile" 2>/dev/null

        local h="${message_height:-20}" w="${message_width:-60}"
        (( h > 0 )) || h=20
        (( w > 0 )) || w=60

        if command -v whiptail >/dev/null 2>&1; then
            whiptail --title "omnish Help" --scrolltext --textbox "$helpfile" "$h" "$w"
        elif command -v dialog >/dev/null 2>&1; then
            dialog --title "omnish Help" --textbox "$helpfile" "$h" "$w"
        elif command -v less >/dev/null 2>&1; then
            less "$helpfile"
        else
            cat "$helpfile"
        fi

        rm -f "$helpfile"
    }
fi