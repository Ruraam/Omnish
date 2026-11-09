# omnish — fzf bindings, header, listing, navigation
#
# [FIX P0-2] ctrl-h now uses change-preview+show-preview so the help pane
#            appears even if the preview was previously hidden.
# [FIX P0-1] fzf_main uses _reload_marks() if available (from 50-fileops.sh)
#            so marks persisted by subcommands survive between iterations.
# [FIX Bug 1] fzf_main installs its own cleanup trap. 10-utils no longer
#             sets it at module scope (that used to wipe $TMP_OMNISH_DIR in
#             every preview subprocess, destroying $MARKED_FILES_FILE).
# [FIX Bug 2] INT/TERM traps call exit, so Ctrl-C actually terminates.
# [FIX helpfile] _ff_ensure_helpfile regenerates if the script is newer.
# [FIX mark_all] mark_all_files resets all_files=() to avoid accumulation.
# [FIX errors] user-visible errors go to /dev/tty (stderr is logged to disk).

safe_ls() {
    local dir="${1:-$PWD}"
    local showhidden='' list_opts='--group-directories-first --color=always'

    if [[ -f "$TMP_OMNISH_DIR/grep" ]]; then
        printf '\033[1;96m  %s\033[0m\n' "$dir"
        cat "$TMP_OMNISH_DIR/grep"
    else
        [[ -f "$CACHE_OMNISH_DIR/showhidden" ]] && showhidden='-a'
        printf '\033[1;96m  %s\033[0m\n' "$dir"
        ls $showhidden $list_opts "$dir" 2>/dev/null | sed 's/\*$//; s|/$||'
    fi
}

f_header_text() {
    local preview_status="on"
    [[ -f "$CACHE_OMNISH_DIR/hidepreview" ]] && preview_status="${YELLOW}off${NC}"
    local marked_status="none"
    (( ${#marked_files[@]} > 0 )) && marked_status="${#marked_files[@]} marked"
    cat <<EOF
╭─ omnish v${OMNISH_VERSION} ─────────────╮
 Tab/⇧Tab: multi-select | ^H: help
 ?/F1: full help | F5: reload
 ^X: system menu | ^U: dua
 ^Y: copy | ^V: move | ^D: trash
 alt-u: undo | alt-t: trash-view
 Preview: $preview_status | Files: $marked_status
╰────────────────────────────────────╯
EOF
}

mark() {
    local path="$1"
    local file
    file=$(clean_path "$path" | sed 's|^\./||g')
    local real_path
    real_path=$(realpath "$file" 2>/dev/null) || return 1
    [[ -h "$file" ]] && real_path="$PWD/$file"

    local i found=0
    for i in "${!marked_files[@]}"; do
        if [[ "${marked_files[i]}" == "$real_path" ]]; then
            unset 'marked_files[i]'
            marked_files=("${marked_files[@]}")
            found=1; break
        fi
    done
    (( found == 0 )) && marked_files+=("$real_path")
    sync_marked_files
}

mark_all_files() {
    # [FIX mark_all] reset to avoid accumulation across calls
    all_files=()
    local f
    if [[ -f "$CACHE_OMNISH_DIR/showhidden" ]]; then
        while IFS= read -r -d '' f; do
            [[ -e "$f" ]] && all_files+=("$(realpath "$f")")
        done < <(find . -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    else
        while IFS= read -r -d '' f; do
            [[ -e "$f" ]] && all_files+=("$(realpath "$f")")
        done < <(find . -mindepth 1 -maxdepth 1 -not -name '.*' -print0 2>/dev/null)
    fi
}

mark_all_only() {
    marked_files=()
    all_files=()
    mark_all_files
    marked_files=("${all_files[@]}")
    sync_marked_files
}

mark_all_toggle() {
    local new_marked=() f m found
    all_files=()
    mark_all_files
    for f in "${all_files[@]}"; do
        found=0
        for m in "${marked_files[@]}"; do
            [[ "$m" == "$f" ]] && { found=1; break; }
        done
        (( found == 0 )) && new_marked+=("$f")
    done
    marked_files=("${new_marked[@]}")
    sync_marked_files
}

search_term() {
    command -v rg >/dev/null 2>&1 || { messages "Error" "install ripgrep"; return 1; }
    cmd_line "Grep: "
    local term="$cmd_reply"
    [[ -z "$term" ]] && return
    rg --files-with-matches --color=never -i "$term" 2>/dev/null > "$TMP_OMNISH_DIR/grep" &
    local rg_pid=$!
    status_msg "searching..." 5
    kill -0 "$rg_pid" 2>/dev/null && wait "$rg_pid" 2>/dev/null
}

last_folder() {
    [[ -f "$CACHE_OMNISH_DIR/last_folder" ]] && touch "$TMP_OMNISH_DIR/last_folder"
}

history_folder() {
    [[ -s "$HISTORY_FILE" ]] || { messages "Error" "no history"; return 1; }
    local history
    readarray -t history < "$HISTORY_FILE"
    local n=${#history[@]}
    (( n < 2 )) && { messages "Error" "no previous dir"; return 1; }
    local target="${history[$((n-2))]}"
    [[ -d "$target" ]] || { messages "Error" "missing: $target"; return 1; }
    sed -i '$d' "$HISTORY_FILE"
    echo "$target" > "$TMP_OMNISH_DIR/last_dir"
}

add_to_history() {
    local dir="$1"
    if [[ -s "$HISTORY_FILE" ]]; then
        [[ "$(tail -n 1 "$HISTORY_FILE")" == "$dir" ]] && return
    fi
    echo "$dir" >> "$HISTORY_FILE"
}

my_terminal() {
    local term="${MY_TERMINAL:-xterm}"
    case "$term" in
        alacritty) alacritty --working-directory "$PWD" ;;
        gnome-terminal) gnome-terminal --working-directory="$PWD" ;;
        konsole) konsole --workdir "$PWD" ;;
        kitty) kitty --directory="$PWD" ;;
        foot) foot --working-directory="$PWD" ;;
        *) xterm -e bash -c "cd \"$PWD\" && exec $SHELL" ;;
    esac
}

# ===============================================================
# Inline help file (cached, regenerated when script changes)
# [FIX helpfile] invalidate cache if the script is newer than the file
# ===============================================================
_ff_ensure_helpfile() {
    local helpfile="$TMP_OMNISH_DIR/help.txt"
    if [[ ! -s "$helpfile" ]] || [[ "${SCRIPT_PATH:-}" -nt "$helpfile" ]]; then
        help > "$helpfile" 2>/dev/null
    fi
    printf '%s' "$helpfile"
}

fzf_binds() {
    local path="$1"
    local header_text margin_preview dua_key helpfile
    header_text=$(f_header_text)
    margin_preview=$(cat "$MARGIN_PREVIEW" 2>/dev/null || echo 60)
    dua_key="ctrl-u"
    helpfile="$(_ff_ensure_helpfile)"

    local hidepreview=''
    [[ -f "$CACHE_OMNISH_DIR/hidepreview" ]] && hidepreview=':hidden'

    local result
    result=$(safe_ls "$path" | fzf --ansi --multi --no-bold \
        --margin=0,2 \
        --border \
        --pointer='▶' \
        --marker='✓' \
        --header "$header_text" \
        --prompt "omnish 🔍: " \
        --bind 'tab:toggle+down' \
        --bind 'shift-tab:toggle+up' \
        --bind 'right:accept' \
        --bind 'enter:accept' \
        --bind 'left:top+up+accept' \
        --bind 'ctrl-r,f5:top+accept' \
        --bind "?:preview(cat \"$helpfile\" 2>/dev/null || echo 'help unavailable')" \
        --bind "ctrl-h:change-preview(cat \"$helpfile\" 2>/dev/null || echo 'help unavailable')+show-preview" \
        --bind "f1:execute(bash \"$SCRIPT_PATH\" --show-help {})" \
        --bind "ctrl-x:execute(bash \"$SCRIPT_PATH\" --system-menu)+top+accept" \
        --bind "ctrl-o:execute(bash \"$SCRIPT_PATH\" --xdg-open {})+top+accept" \
        --bind "ctrl-v:execute(bash \"$SCRIPT_PATH\" --move-file {})+top+accept" \
        --bind "ctrl-y:execute(bash \"$SCRIPT_PATH\" --copy-file {})+top+accept" \
        --bind "alt-n:execute(bash \"$SCRIPT_PATH\" --create-file {})+top+accept" \
        --bind "ctrl-n:execute(bash \"$SCRIPT_PATH\" --create-directory {})+top+accept" \
        --bind "ctrl-s:execute(bash \"$SCRIPT_PATH\" --create-symlink {})+top+accept" \
        --bind "ctrl-d,ctrl-e:execute(bash \"$SCRIPT_PATH\" --delete-file {})+top+accept" \
        --bind "${dua_key}:execute(bash \"$SCRIPT_PATH\" --dua \"$PWD\")+top+accept" \
        --bind "alt-u:execute(bash \"$SCRIPT_PATH\" --undo)+top+accept" \
        --bind "alt-t:execute(bash \"$SCRIPT_PATH\" --trash-view)+top+accept" \
        --bind "ctrl-g:execute({ [ ! -f \"$TMP_OMNISH_DIR/grep\" ] && bash \"$SCRIPT_PATH\" --search-term; } || rm -f \"$TMP_OMNISH_DIR/grep\")+top+accept" \
        --bind "alt-a:toggle+execute-silent(bash \"$SCRIPT_PATH\" --mark-file {})" \
        --bind "alt-x:select-all+execute-silent(bash \"$SCRIPT_PATH\" --mark-all-only)" \
        --bind "ctrl-a:toggle-all+execute-silent(bash \"$SCRIPT_PATH\" --mark-all-toggle)" \
        --bind "alt-h:execute-silent({ [ ! -f \"$CACHE_OMNISH_DIR/showhidden\" ] && touch \"$CACHE_OMNISH_DIR/showhidden\"; } || rm -f \"$CACHE_OMNISH_DIR/showhidden\")+top+accept" \
        --bind "alt-l:execute-silent({ [ ! -f \"$CACHE_OMNISH_DIR/longfilemanager\" ] && touch \"$CACHE_OMNISH_DIR/longfilemanager\"; } || rm -f \"$CACHE_OMNISH_DIR/longfilemanager\")+top+accept" \
        --bind "ctrl-p:toggle-preview+execute-silent({ [ ! -f \"$CACHE_OMNISH_DIR/hidepreview\" ] && touch \"$CACHE_OMNISH_DIR/hidepreview\"; } || rm -f \"$CACHE_OMNISH_DIR/hidepreview\")+top+accept" \
        --bind "esc:execute(echo \"$PWD\" > \"$CACHE_OMNISH_DIR/last_folder\"; echo 130 > \"$TMP_OMNISH_DIR/signal\")+abort" \
        --bind "ctrl-q:execute(echo \"$PWD\" > \"$CACHE_OMNISH_DIR/last_folder\"; echo 130 > \"$TMP_OMNISH_DIR/signal\")+abort" \
        --bind "ctrl-c:execute(echo \"$PWD\" > \"$CACHE_OMNISH_DIR/last_folder\"; echo 130 > \"$TMP_OMNISH_DIR/signal\")+abort" \
        --preview "bash \"$SCRIPT_PATH\" --preview-file \"$path/{}\"" \
        --preview-window "right:${margin_preview}:noborder${hidepreview}" \
        --expect=enter,right 2>&1)

    selected=$(clean_path "$result" | sed 's|^\./||g')
    if [[ -f "$TMP_OMNISH_DIR/signal" ]]; then
        local code
        code=$(cat "$TMP_OMNISH_DIR/signal")
        rm -f "$TMP_OMNISH_DIR/signal"
        (( code == 130 )) && return 1
    fi
    return 0
}

handle_selected() {
    local path="$1"
    local file mime
    file=$(clean_path "$path" | sed 's|^\./||g')
    [[ -e "$file" ]] || return
    mime=$(file -b --mime -- "$file" 2>/dev/null)
    case "$mime" in
        text/*|*json|*xml|*script*)
            "${EDITOR:-vi}" -- "$file" ;;
        *)
            nohup "${OMNI_OPENER:-xdg-open}" "$file" &>/dev/null & disown ;;
    esac
}

# ===============================================================
# fzf_main — main loop for the fzf backend
# ===============================================================
fzf_main() {
    local target="${1:-$PWD}"

    # [FIX errors] stderr is redirected to debug.log by 00-config.sh,
    # so user-visible errors must go to /dev/tty explicitly.
    if [[ ! -d "$target" ]]; then
        printf 'omnish: %s: not a directory\n' "$target" >/dev/tty 2>/dev/null || \
        printf 'omnish: %s: not a directory\n' "$target" >&2
        exit 1
    fi
    if ! command -v fzf >/dev/null 2>&1; then
        printf 'omnish: fzf required (install fzf or use OMNISH_BACKEND=loop)\n' >/dev/tty 2>/dev/null || \
        printf 'omnish: fzf required\n' >&2
        exit 1
    fi

    get_term_size
    builtin cd "$target" || exit 1
    add_to_history "$PWD"

    # [FIX Bug 1+2] install the trap HERE (not in 10-utils.sh at module scope),
    # and make INT/TERM actually exit the shell.
    trap 'cleanup' EXIT
    trap 'cleanup; exit 130' INT
    trap 'cleanup; exit 143' TERM

    local key sel raw_sel mark_lines
    while :; do
        selected=""

        # [FIX P0-1] reload marks from disk so subcommands (--mark-file,
        # --copy-file, etc.) which rewrote the file are reflected next pass.
        if declare -F _reload_marks >/dev/null 2>&1; then
            _reload_marks
        else
            marked_files=()
            [[ -f "$MARKED_FILES_FILE" ]] && \
                mapfile -t marked_files < "$MARKED_FILES_FILE" 2>/dev/null
            ((${#marked_files[@]})) && [[ -z "${marked_files[0]}" ]] && marked_files=()
        fi

        fzf_binds "$PWD" || break

        key="$(head -n1 <<< "$selected")"
        raw_sel="$(tail -n +2 <<< "$selected")"

        mark_lines=$(printf '%s\n' "$raw_sel" | wc -l)
        if (( mark_lines > 1 )); then
            continue
        fi

        [[ -z "$raw_sel" ]] && continue

        sel=$(clean_path "$raw_sel" | sed 's|^\./||g')
        [[ -z "$sel" ]] && continue

        if [[ -f "$TMP_OMNISH_DIR/last_folder" ]]; then
            local d
            d=$(cat "$CACHE_OMNISH_DIR/last_folder" 2>/dev/null)
            [[ -d "$d" ]] && builtin cd "$d"
            rm -f "$TMP_OMNISH_DIR/last_folder"
            add_to_history "$PWD"
            continue
        fi
        if [[ -f "$TMP_OMNISH_DIR/last_dir" ]]; then
            local h
            h=$(cat "$TMP_OMNISH_DIR/last_dir" 2>/dev/null)
            [[ -d "$h" ]] && builtin cd "$h"
            rm -f "$TMP_OMNISH_DIR/last_dir"
            continue
        fi

        if [[ "$sel" == "  $PWD" ]]; then
            if [[ -z "$key" && "$PWD" != "/" ]]; then
                builtin cd .. ||:
                add_to_history "$PWD"
            fi
            continue
        fi

        if [[ -d "$PWD/$sel" ]]; then
            builtin cd "$PWD/$sel" || continue
            add_to_history "$PWD"
            continue
        fi

        if [[ -f "$PWD/$sel" && ( "$key" == "enter" || "$key" == "right" ) ]]; then
            handle_selected "$PWD/$sel"
        fi
    done
}