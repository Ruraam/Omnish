# omnish — private Markdown scratchpad

scratchpad_file() {
    printf '%s/omnish/scratchpad.md' "${XDG_DATA_HOME:-$HOME/.local/share}"
}

scratchpad_prepare() {
    local file dir
    file="$(scratchpad_file)"
    dir="${file%/*}"
    (umask 077; mkdir -p -- "$dir") || return 1
    [[ ! -L "$file" ]] || return 1
    if [[ ! -e "$file" ]]; then (umask 077; : > "$file") || return 1; fi
    [[ -f "$file" ]] || return 1
    chmod 600 -- "$file" 2>/dev/null || return 1
    printf '%s' "$file"
}

scratchpad_append() {
    local kind="$1" payload="$2" file stamp
    file="$(scratchpad_prepare)" || return 1
    stamp="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf 'unknown time')"
    { [[ -s "$file" ]] && printf '\n'; printf '%s — %s\n\n' "$kind" "$stamp"; printf '%s\n' "$payload"; } >> "$file"
    chmod 600 -- "$file" 2>/dev/null || return 1
}

scratchpad_insert_path() {
    local selected_path="$1"
    [[ -n "$selected_path" ]] || return 1
    [[ "$selected_path" == /* ]] || selected_path="$PWD/$selected_path"
    scratchpad_append '### Path' "\`$selected_path\`"
}

scratchpad_insert_clipboard() {
    local file tmp copied=0
    file="$(scratchpad_prepare)" || return 1
    tmp="$TMP_OMNISH_DIR/scratchpad-clipboard.$$"
    : > "$tmp"
    if command -v wl-paste >/dev/null 2>&1; then
        wl-paste --no-newline > "$tmp" 2>/dev/null && [[ -s "$tmp" ]] && copied=1
    fi
    if (( ! copied )) && command -v xclip >/dev/null 2>&1; then
        : > "$tmp"; xclip -selection clipboard -o > "$tmp" 2>/dev/null && [[ -s "$tmp" ]] && copied=1
    fi
    if (( ! copied )) && command -v xsel >/dev/null 2>&1; then
        : > "$tmp"; xsel --clipboard --output > "$tmp" 2>/dev/null && [[ -s "$tmp" ]] && copied=1
    fi
    if (( ! copied )) && command -v termux-clipboard-get >/dev/null 2>&1; then
        : > "$tmp"; termux-clipboard-get > "$tmp" 2>/dev/null && [[ -s "$tmp" ]] && copied=1
    fi
    if (( ! copied )); then rm -f -- "$tmp"; return 2; fi
    { [[ -s "$file" ]] && printf '\n'; printf '### Clipboard — %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf 'unknown time')"; cat -- "$tmp"; printf '\n'; } >> "$file"
    rm -f -- "$tmp"
    chmod 600 -- "$file" 2>/dev/null
}

scratchpad_edit() {
    local file editor_line saved_tty="" rc=0
    file="$(scratchpad_prepare)" || return 1
    saved_tty="$(stty -g </dev/tty 2>/dev/null)" || :
    editor_line="${VISUAL:-${EDITOR:-vi}}"
    local -a editor_cmd=()
    read -r -a editor_cmd <<< "$editor_line"
    (("${#editor_cmd[@]}")) || editor_cmd=(vi)
    # fzf execute may not preserve the child process standard input.
    # Attach full-screen editors to the controlling terminal explicitly.
    "${editor_cmd[@]}" -- "$file" </dev/tty >/dev/tty 2>&1 || rc=$?
    [[ -n "$saved_tty" ]] && stty "$saved_tty" </dev/tty 2>/dev/null || :
    chmod 600 -- "$file" 2>/dev/null || :
    return "$rc"
}

scratchpad_open() {
    local selected_path="${1:-}" file action note
    file="$(scratchpad_prepare)" || return 1
    [[ "$selected_path" == "empty" ]] && selected_path=""
    if [[ -n "$selected_path" && ! -e "$selected_path" && ! -L "$selected_path" ]]; then
        if [[ -e "$PWD/$selected_path" || -L "$PWD/$selected_path" ]]; then
            selected_path="$PWD/$selected_path"
        else
            selected_path=""
        fi
    fi
    while :; do
        printf '\033[2J\033[H'
        printf '\033[1;96m╭─ Omnish Scratchpad ─────────────────────────────────╮\033[0m\n'
        printf '  %s\n\n' "$file"
        printf '  [n] Add note       [t] Add TODO\n'
        printf '  [p] Paste clipboard into note\n'
        printf '  [c] Insert current selected path\n'
        printf '  [e] Open in $VISUAL / $EDITOR\n'
        printf '  [v] View note      [q] Return to Omnish\n'
        [[ -n "$selected_path" ]] && printf '\n  Selected: %s\n' "$selected_path"
        printf '\n  Action: '
        IFS= read -r action </dev/tty || action=q
        case "$action" in
            n|t)
                printf '\n  Text: '
                IFS= read -r note </dev/tty || note=''
                if [[ -n "$note" ]]; then
                    if [[ "$action" == t ]]; then scratchpad_append '- [ ] TODO' "$note"
                    else scratchpad_append '### Note' "$note"; fi
                fi
                ;;
            p)
                if scratchpad_insert_clipboard; then printf '\n  Clipboard inserted.'
                else printf '\n  Clipboard unavailable or empty (no change).'; fi
                IFS= read -r -t 1 _ </dev/tty || :
                ;;
            c)
                if [[ -n "$selected_path" ]]; then scratchpad_insert_path "$selected_path" || :
                else printf '\n  No file is currently selected.'; IFS= read -r -t 1 _ </dev/tty || :; fi
                ;;
            e) scratchpad_edit ;;
            v)
                printf '\033[2J\033[H'
                if command -v less >/dev/null 2>&1; then less -- "$file" </dev/tty >/dev/tty 2>&1
                else cat -- "$file"; printf '\nPress Enter to return...'; IFS= read -r _ </dev/tty || :; fi
                ;;
            q|'') break ;;
            *) : ;;
        esac
    done
}
