# omnish — bash loop backend (P4)
# Replaces fzf for the main navigation pane.
# Same contract as 70-fzf.sh: provides loop_main().
#
# [FIX 1] Trap INT/TERM now exit (Ctrl-C terminates cleanly, no hang).
# [FIX 2] Fatal errors go to /dev/tty (stderr is logged to disk by 00-config).
# [FIX 3] _loop_ensure_helpfile invalidates cache when the script changes.
# [FIX 4] loop_read_dir no longer mutates global $PWD for the root dir.
# [FIX 5] Alt-<char> detection actually works (was: unreachable branch).
# [FIX 6] loop_quit no longer triple-cleans (relies on EXIT trap).
# [FIX 7] loop_cd previous-dir restore works (flag survives loop_read_dir).
# [FIX 8] loop_with_terminal guards against empty path.
# [FIX 9] Marks persistence: marked_files is the source of truth, loaded
#         from disk at startup and after every operation; loop_marks is
#         rebuilt from it, so marks survive backend switches and cwd changes.

# ===============================================================
# Terminal state
# ===============================================================
loop_setup_terminal() {
    printf '\e[?1049h\e[?7l\e[?25l\e[2J'
    stty -echo 2>/dev/null
}

loop_reset_terminal() {
    printf '\e[?7h\e[?25h\e[2J\e[;r\e[?1049l'
    stty echo 2>/dev/null
}

loop_clear_scroll() {
    local bottom="${LINES:-24}"
    [[ "$bottom" =~ ^[0-9]+$ ]] || bottom=24
    (( bottom > 1 )) && (( bottom-- )) || bottom=1

    # Clear the complete content area from its real origin. The old cursor
    # sequence used row=1, column=LINES-1, which left stale content behind
    # and made the list pane appear blank or partially overwritten.
    printf '\e[1;1H\e[J\e[1;%sr' "$bottom"
}

loop_hide_cursor() { printf '\e[?25l'; }
loop_show_cursor() { printf '\e[?25h'; }

# ===============================================================
# Inline help (cached, invalidated when script changes)
# ===============================================================
_loop_ensure_helpfile() {
    local helpfile="$TMP_OMNISH_DIR/help.txt"
    if [[ ! -s "$helpfile" ]] || [[ "${SCRIPT_PATH:-}" -nt "$helpfile" ]]; then
        help > "$helpfile" 2>/dev/null
    fi
    printf '%s' "$helpfile"
}

# ===============================================================
# Marks <-> disk bridge
# marked_files is authoritative (persisted, cross-dir).
# loop_marks is a visual overlay indexed by loop_list position.
# ===============================================================
loop_reload_marks_from_disk() {
    marked_files=()
    [[ -f "$MARKED_FILES_FILE" ]] && mapfile -t marked_files < "$MARKED_FILES_FILE" 2>/dev/null
    ((${#marked_files[@]})) && [[ -z "${marked_files[0]}" ]] && marked_files=()
}

loop_rebuild_visual_marks() {
    loop_marks=()
    ((${#marked_files[@]})) || return
    declare -A mark_set=()
    local p
    for p in "${marked_files[@]}"; do mark_set["$p"]=1; done
    local i real
    for i in "${!loop_list[@]}"; do
        [[ -z "${loop_list[i]}" || "${loop_list[i]}" == "empty" ]] && continue
        real=$(realpath "${loop_list[i]}" 2>/dev/null) || continue
        [[ -n "${mark_set[$real]:-}" ]] && loop_marks[$i]="${loop_list[i]}"
    done
}

# ===============================================================
# Directory listing
# [FIX 4] Use a local base instead of mutating $PWD (was: PWD=""
#         at /, breaking every other function that used $PWD).
# ===============================================================
loop_read_dir() {
    local dirs=() files=() item prev_idx=0 idx=0
    loop_find_previous=0

    local base="$PWD"
    [[ "$base" == "/" ]] && base=""

    local -a entries=()
    local had_nullglob=0 had_dotglob=0
    shopt -q nullglob && had_nullglob=1
    shopt -q dotglob && had_dotglob=1

    shopt -s nullglob
    if [[ -f "$CACHE_OMNISH_DIR/showhidden" ]]; then
        shopt -s dotglob
    else
        shopt -u dotglob
    fi
    entries=("$base"/*)

    # Do not leak shell-option changes into the rest of the application.
    (( had_dotglob )) && shopt -s dotglob || shopt -u dotglob
    (( had_nullglob )) && shopt -s nullglob || shopt -u nullglob

    for item in "${entries[@]}"; do
        [[ -e "$item" || -L "$item" ]] || continue
        if [[ -d "$item" ]]; then
            dirs+=("$item")
            [[ "$item" == "$OLDPWD" ]] && prev_idx=$idx
            ((idx++))
        else
            files+=("$item")
        fi
    done

    loop_list=("${dirs[@]}" "${files[@]}")
    [[ ${#loop_list[@]} -eq 0 ]] && loop_list=("empty")
    ((loop_total=${#loop_list[@]}-1))
    loop_prev_idx=$prev_idx
}

# ===============================================================
# Render one line
# ===============================================================
loop_print_line() {
    local i="$1"
    local avail="$2"
    [[ -z "${loop_list[i]:-}" ]] && return

    local entry="${loop_list[i]}"
    local name="${entry##*/}"
    local color='' suffix=''

    if [[ "$entry" == "empty" ]]; then
        printf '\e[2m(empty)\e[m'
        return
    fi

    if   [[ -d "$entry" ]]; then color='\e[1;34m'; suffix='/'
    elif [[ -L "$entry" && ! -e "$entry" ]]; then color='\e[1;31;7m'
    elif [[ -L "$entry" ]]; then color='\e[1;36m'
    elif [[ -x "$entry" ]]; then color='\e[1;32m'
    elif [[ -b "$entry" || -c "$entry" ]]; then color='\e[33m'
    elif [[ -p "$entry" || -S "$entry" ]]; then color='\e[35m'
    else color='\e[0m'
    fi

    (( i == loop_scroll )) && color+=$'\e[7m'

    local mark=''
    [[ -n "${loop_marks[i]:-}" ]] && mark='*'

    local max=$(( avail - 3 ))
    (( max < 1 )) && max=1
    local display="$name$suffix"
    (( ${#display} > max )) && display="${display:0:max-1}…"

    printf '\e[K%b%s%s\e[m' "$color" "$display" "$mark"
}

# ===============================================================
# Preview pane (with inline help support)
# ===============================================================
loop_draw_preview() {
    local col="$1" width="$2" lines="$3"
    local tmpf="$TMP_OMNISH_DIR/loop_preview.$"
    : > "$tmpf" || return 1

    if (( ${loop_show_help:-0} )); then
        local helpfile
        helpfile="$(_loop_ensure_helpfile)"
        [[ -r "$helpfile" ]] && cp -- "$helpfile" "$tmpf" 2>/dev/null
    else
        local entry="${loop_list[loop_scroll]:-}"
        if [[ -n "$entry" && "$entry" != "empty" ]]; then
            _preview_file "$entry" > "$tmpf" 2>/dev/null
        fi
    fi

    # Clear only the preview pane before repainting it. This prevents stale
    # lines from a longer previous preview remaining visible.
    local clear_row
    for (( clear_row=0; clear_row<lines; clear_row++ )); do
        printf '\e[%s;%sH\e[K' "$((clear_row+1))" "$col"
    done

    local row=0 line visible
    while IFS= read -r line && (( row < lines )); do
        visible=$(printf '%s' "$line" | sed 's/\x1b\[[0-9;]*m//g')
        (( ${#visible} > width )) && line="${visible:0:width-1}…"
        printf '\e[%s;%sH%s\e[K' "$((row+1))" "$col" "$line"
        ((row++))
    done < "$tmpf"
    rm -f -- "$tmpf"
}

# ===============================================================
# Full redraw
# ===============================================================
loop_draw() {
    local full="${1:-}"
    if [[ "$full" == "full" ]]; then
        loop_read_dir
        loop_rebuild_visual_marks
    fi

    get_term_size
    [[ "${LINES:-}" =~ ^[0-9]+$ ]] || LINES=24
    [[ "${COLUMNS:-}" =~ ^[0-9]+$ ]] || COLUMNS=80
    (( LINES > 0 )) || LINES=24
    (( COLUMNS > 0 )) || COLUMNS=80
    loop_clear_scroll

    # Keep both panes usable even on compact terminals.
    local split=$(( COLUMNS * 45 / 100 ))
    (( split < 1 )) && split=1
    (( split >= COLUMNS )) && split=$(( COLUMNS / 2 ))
    local list_w=$(( split - 2 ))
    local prev_w=$(( COLUMNS - split - 2 ))
    local rows=$(( LINES - 2 ))
    (( list_w < 1 )) && list_w=1
    (( prev_w < 1 )) && prev_w=1
    (( rows < 1 )) && rows=1

    local start=0
    if (( loop_total + 1 > rows )); then
        if (( loop_scroll < rows/2 )); then
            start=0
        elif (( loop_total - loop_scroll < rows/2 )); then
            (( start = loop_total - rows + 1 ))
        else
            (( start = loop_scroll - rows/2 ))
        fi
    fi

    local i row=0
    for (( i=start; i<=loop_total && row<rows; i++ )); do
        printf '\e[%s;1H' "$((row+1))"
        loop_print_line "$i" "$list_w"
        ((row++))
    done

    for (( row=0; row<rows; row++ )); do
        printf '\e[%s;%sH\e[2m│\e[m' "$((row+1))" "$split"
    done

    if [[ ! -f "$CACHE_OMNISH_DIR/hidepreview" ]]; then
        loop_draw_preview "$((split+2))" "$prev_w" "$rows"
    fi

    loop_status_line
    loop_hide_cursor
}

# ===============================================================
# Status line
# ===============================================================
loop_status_line() {
    local path="${PWD:-/}"
    local mark_info=''
    local mark_count=0
    local k
    for k in "${!loop_marks[@]}"; do
        [[ -n "${loop_marks[k]:-}" ]] && ((mark_count++))
    done
    (( mark_count > 0 )) && mark_info="[${mark_count} marked] "
    (( ${loop_show_help:-0} )) && mark_info="[HELP] ${mark_info}"

    printf '\e[%s;1H\e[7m%-*.*s\e[m' \
        "$LINES" "$COLUMNS" "$COLUMNS" \
        " ${mark_info}($((loop_scroll+1))/$((loop_total+1))) $path"
}

# ===============================================================
# Key handler
# [FIX 5] Alt-<char> now works: single-char read distinguishes
#         ESC[..., ESCO..., and Alt-<char>.
# ===============================================================
loop_handle_key() {
    local k="$1"

    if [[ "$k" == $'\e' ]]; then
        local c1='' c2=''
        if IFS= read -rsn 1 -t 0.05 c1 2>/dev/null; then
            if [[ "$c1" == '[' || "$c1" == 'O' ]]; then
                if IFS= read -rsn 1 -t 0.05 c2 2>/dev/null; then
                    case "${c1}${c2}" in
                        '[A'|'OA') k='UP' ;;
                        '[B'|'OB') k='DOWN' ;;
                        '[C'|'OC') k='RIGHT' ;;
                        '[D'|'OD') k='LEFT' ;;
                        '[Z')      k='SHIFT_TAB' ;;
                        *)         k='ESC' ;;
                    esac
                else
                    k='ESC'
                fi
            else
                k="ALT_${c1}"
            fi
        else
            k='ESC'
        fi
    fi

    case "$k" in
        # === Navigation ===
        j|DOWN)  (( loop_scroll < loop_total )) && (( loop_scroll++ )) ; loop_show_help=0 ; loop_draw ;;
        k|UP)    (( loop_scroll > 0 )) && (( loop_scroll-- )) ; loop_show_help=0 ; loop_draw ;;
        g)       loop_scroll=0 ; loop_show_help=0 ; loop_draw ;;
        G)       loop_scroll=$loop_total ; loop_show_help=0 ; loop_draw ;;
        l|RIGHT|'')  loop_open_selected ;;
        h|LEFT|$'\177'|BACKSPACE) loop_go_parent ;;
        e|F5)    loop_draw full ;;

        q|ESC)   loop_quit ;;

        # === Multi-select ===
        $'\t')
                 loop_mark_current_silent
                 (( loop_scroll < loop_total )) && (( loop_scroll++ ))
                 loop_show_help=0
                 loop_draw
                 ;;
        SHIFT_TAB)
                 loop_mark_current_silent
                 (( loop_scroll > 0 )) && (( loop_scroll-- ))
                 loop_show_help=0
                 loop_draw
                 ;;

        # === Inline help ===
        $'\x08')
                 if (( ${loop_show_help:-0} )); then loop_show_help=0; else loop_show_help=1; fi
                 loop_draw
                 ;;

        # === View toggles ===
        .)       if [[ -f "$CACHE_OMNISH_DIR/showhidden" ]]; then rm -f "$CACHE_OMNISH_DIR/showhidden"; else touch "$CACHE_OMNISH_DIR/showhidden"; fi
                 loop_scroll=0 ; loop_show_help=0 ; loop_draw full ;;
        ALT_h)   if [[ -f "$CACHE_OMNISH_DIR/showhidden" ]]; then rm -f "$CACHE_OMNISH_DIR/showhidden"; else touch "$CACHE_OMNISH_DIR/showhidden"; fi
                 loop_show_help=0 ; loop_draw full ;;
        ALT_l)   if [[ -f "$CACHE_OMNISH_DIR/longfilemanager" ]]; then rm -f "$CACHE_OMNISH_DIR/longfilemanager"; else touch "$CACHE_OMNISH_DIR/longfilemanager"; fi
                 loop_show_help=0 ; loop_draw full ;;
        $'\x10')  if [[ -f "$CACHE_OMNISH_DIR/hidepreview" ]]; then rm -f "$CACHE_OMNISH_DIR/hidepreview"; else touch "$CACHE_OMNISH_DIR/hidepreview"; fi
                 loop_draw ;;

        # === Marking ===
        $'\x00'|' '|ALT_a)  loop_mark_current ;;
        ALT_x)              loop_mark_all_only ;;
        $'\x01')            loop_mark_all_toggle ;;
        c)                  marked_files=(); sync_marked_files; loop_marks=(); loop_draw ;;

        # === File ops ===
        $'\x19')  loop_with_terminal "copy_file" ;;
        $'\x16')  loop_with_terminal "move_file" ;;
        $'\x04')  loop_with_terminal "delete_file" ;;
        $'\x0e')  loop_with_terminal "create_directory" ;;
        ALT_n)    loop_with_terminal "create_file" ;;
        $'\x13')  loop_with_terminal "create_symlink" ;;
        $'\x0f')  loop_open_external ;;
        r)        loop_rename_current ;;
        p)        loop_paste ;;

        # === Disk usage ===
        $'\x15')  loop_dua ;;

        # === System menu ===
        $'\x18')
                 loop_reset_terminal
                 _sys_menu
                 loop_setup_terminal
                 loop_show_help=0
                 loop_draw full
                 ;;

        # === Trash ===
        ALT_u)    loop_undo_trash ;;
        ALT_t)    loop_trash_view ;;

        # === Search ===
        $'\x07')  loop_grep ;;
        /)        loop_search ;;

        # === Shell / external ===
        '!')      loop_shell ;;

        # === Misc ===
        x)        loop_stat_current ;;
        X)        loop_toggle_executable ;;
        '~')      loop_cd "$HOME" ;;
        -)        loop_cd "$OLDPWD" ;;
        :\ )      loop_go_dir ;;

        [1-9])    local fav="OMNI_FAV$k"
                  [[ -n "${!fav:-}" ]] && loop_cd "${!fav}" ;;

        *)        : ;;
    esac
}

# ===============================================================
# Actions
# ===============================================================
loop_open_selected() {
    local entry="${loop_list[loop_scroll]:-}"
    [[ -z "$entry" || "$entry" == "empty" ]] && return
    if [[ -d "$entry" ]]; then
        loop_cd "$entry"
    elif [[ -f "$entry" ]]; then
        loop_open_external
    fi
}

loop_go_parent() {
    local old="$PWD"
    [[ "$old" == "/" ]] && return
    loop_find_previous=1
    loop_cd "${old%/*}"
}

# [FIX 7] preserve loop_find_previous across loop_draw full
loop_cd() {
    local target="$1"
    [[ -d "$target" ]] || return
    local restore_prev=$loop_find_previous
    builtin cd "$target" 2>/dev/null || return
    loop_scroll=0
    loop_show_help=0
    loop_draw full
    (( restore_prev == 1 )) && {
        loop_scroll=$loop_prev_idx
        loop_find_previous=0
        loop_draw
    }
}

# [FIX 6] rely on EXIT trap for terminal reset + cleanup
loop_quit() {
    exit 0
}

# ===============================================================
# Marks toggle (source of truth = marked_files)
# ===============================================================
loop_toggle_mark() {
    local entry="${loop_list[loop_scroll]:-}"
    [[ -z "$entry" || "$entry" == "empty" ]] && return
    local real
    real=$(realpath "$entry" 2>/dev/null) || real="$entry"

    local -a new_marked=()
    local found=0 p
    for p in "${marked_files[@]}"; do
        if [[ "$p" == "$real" ]]; then found=1; else new_marked+=("$p"); fi
    done
    (( found == 0 )) && new_marked+=("$real")
    marked_files=("${new_marked[@]}")
    sync_marked_files
    loop_rebuild_visual_marks
}

loop_mark_current_silent() { loop_toggle_mark; }
loop_mark_current() {
    loop_toggle_mark
    loop_show_help=0
    loop_draw
}

loop_mark_all_only() {
    local cur_prefix="$PWD/"
    [[ "$PWD" == "/" ]] && cur_prefix="/"

    local -a kept=() p
    for p in "${marked_files[@]}"; do
        [[ "$p" == "$cur_prefix"* ]] || kept+=("$p")
    done

    local i real
    for (( i=0; i<=loop_total; i++ )); do
        [[ "${loop_list[i]}" == "empty" ]] && continue
        real=$(realpath "${loop_list[i]}" 2>/dev/null) || real="${loop_list[i]}"
        kept+=("$real")
    done
    marked_files=("${kept[@]}")
    sync_marked_files
    loop_rebuild_visual_marks
    loop_show_help=0
    loop_draw
}

loop_mark_all_toggle() {
    local cur_prefix="$PWD/"
    [[ "$PWD" == "/" ]] && cur_prefix="/"

    declare -A current_marked=()
    local p
    for p in "${marked_files[@]}"; do
        [[ "$p" == "$cur_prefix"* ]] && current_marked["$p"]=1
    done

    local -a current_reals=() i real
    for (( i=0; i<=loop_total; i++ )); do
        [[ "${loop_list[i]}" == "empty" ]] && continue
        real=$(realpath "${loop_list[i]}" 2>/dev/null) || real="${loop_list[i]}"
        current_reals+=("$real")
    done

    local marked_count=0
    for real in "${current_reals[@]}"; do
        [[ -n "${current_marked[$real]:-}" ]] && ((marked_count++))
    done

    if (( ${#current_reals[@]} > 0 && marked_count == ${#current_reals[@]} )); then
        # All current-dir entries marked → unmark current dir
        local -a new_marked=()
        for p in "${marked_files[@]}"; do
            [[ "$p" == "$cur_prefix"* ]] || new_marked+=("$p")
        done
        marked_files=("${new_marked[@]}")
    else
        # Not all marked → mark all current dir
        for real in "${current_reals[@]}"; do
            [[ -z "${current_marked[$real]:-}" ]] && marked_files+=("$real")
        done
    fi
    sync_marked_files
    loop_rebuild_visual_marks
    loop_show_help=0
    loop_draw
}

# ===============================================================
# Helpers
# ===============================================================
loop_current_path() {
    local entry="${loop_list[loop_scroll]:-}"
    [[ -z "$entry" || "$entry" == "empty" ]] && return
    # [FIX 4] avoid // for root
    printf '%s/%s' "${PWD%/}" "${entry##*/}"
}

# [FIX 8] guard against empty path
loop_with_terminal() {
    local fn="$1"
    local path
    path=$(loop_current_path)
    [[ -z "$path" ]] && { loop_draw; return; }
    loop_reset_terminal
    "$fn" "$path"
    loop_setup_terminal
    # $fn may have modified marked_files in-process; loop_draw full
    # rebuilds loop_marks from marked_files
    loop_show_help=0
    loop_draw full
}

loop_open_external() {
    local entry="${loop_list[loop_scroll]:-}"
    [[ -z "$entry" || "$entry" == "empty" ]] && return
    local mime
    mime=$(file -b --mime -- "$entry" 2>/dev/null)
    case "$mime" in
        text/*|*json|*xml|*script*)
            loop_reset_terminal
            "${EDITOR:-vi}" -- "$entry"
            loop_setup_terminal
            loop_show_help=0
            loop_draw full
            ;;
        *)
            nohup "${OMNI_OPENER:-xdg-open}" "$entry" &>/dev/null & disown
            ;;
    esac
}

loop_rename_current() {
    local entry="${loop_list[loop_scroll]:-}"
    [[ -z "$entry" || "$entry" == "empty" ]] && return
    local base="${entry##*/}"
    loop_show_help=0
    cmd_line "rename '${base}' to: "
    local new="$cmd_reply"
    [[ -z "$new" || "$new" == "$base" ]] && loop_draw && return
    if [[ -e "$PWD/$new" ]]; then
        status_msg "target exists"
        loop_draw && return
    fi
    mv -- "$entry" "$PWD/$new" 2>/dev/null && status_msg "renamed: $new"
    loop_draw full
}

loop_paste() {
    (( ${#marked_files[@]} == 0 )) && { status_msg "nothing marked"; loop_draw; return; }
    spinner_begin "pasting ${#marked_files[@]} item(s)"
    cp -rf -- "${marked_files[@]}" "$PWD" 2>/dev/null \
        && { spinner_end; status_msg "pasted ${#marked_files[@]}"; } \
        || { spinner_end; status_msg "paste failed"; }
    marked_files=()
    sync_marked_files
    loop_show_help=0
    loop_draw full
}

loop_dua() {
    loop_reset_terminal
    _dua_interactive "$PWD"
    loop_setup_terminal
    loop_show_help=0
    loop_draw full
}

loop_undo_trash() {
    loop_reset_terminal
    undo_trash
    loop_setup_terminal
    loop_show_help=0
    loop_draw full
}

loop_trash_view() {
    loop_reset_terminal
    trash_view
    loop_setup_terminal
    loop_show_help=0
    loop_draw full
}

loop_grep() {
    loop_reset_terminal
    search_term
    loop_setup_terminal
    loop_show_help=0
    loop_draw full
}

loop_search() {
    loop_show_help=0
    loop_show_cursor
    printf '\e[%s;1H\e[K/' "$LINES"
    local query='' ch
    while IFS= read -rsn 1 -t 2 ch; do
        case "$ch" in
            $'\e'|'') break ;;
            $'\177'|$'\b') query="${query%?}" ;;
            *) query+="$ch" ;;
        esac
        printf '\e[%s;1H\e[K/%s' "$LINES" "$query"
    done
    [[ -z "$query" ]] && { loop_draw; return; }

    local filtered=() item
    for item in "${loop_list[@]}"; do
        [[ "${item##*/}" == *"$query"* ]] && filtered+=("$item")
    done
    if (( ${#filtered[@]} > 0 )); then
        loop_list=("${filtered[@]}")
        (( loop_total=${#loop_list[@]}-1 ))
        loop_scroll=0
    fi
    loop_draw
}

loop_shell() {
    loop_reset_terminal
    ( cd "$PWD" && "${SHELL:-bash}" )
    loop_setup_terminal
    loop_show_help=0
    loop_draw full
}

loop_stat_current() {
    local entry="${loop_list[loop_scroll]:-}"
    [[ -z "$entry" || "$entry" == "empty" ]] && return
    loop_reset_terminal
    stat -- "$entry" 2>/dev/null || ls -la -- "$entry"
    read -rsn 1 -p "Press any key…"
    loop_setup_terminal
    loop_show_help=0
    loop_draw
}

loop_toggle_executable() {
    local entry="${loop_list[loop_scroll]:-}"
    [[ -f "$entry" && -w "$entry" ]] || return
    if [[ -x "$entry" ]]; then
        chmod -x -- "$entry" && status_msg "unset +x"
    else
        chmod +x -- "$entry" && status_msg "set +x"
    fi
    loop_show_help=0
    loop_draw
}

loop_go_dir() {
    loop_show_help=0
    loop_show_cursor
    cmd_line "go to: " dirs
    local dest="$cmd_reply"
    loop_hide_cursor
    [[ -z "$dest" ]] && { loop_draw; return; }
    dest="${dest/#\~/$HOME}"
    [[ -d "$dest" ]] && loop_cd "$(realpath "$dest")" || loop_draw
}

# ===============================================================
# Main loop
# [FIX 1] trap INT/TERM now exit
# [FIX 2] fatal errors go to /dev/tty
# [FIX 9] reload marked_files from disk at start
# ===============================================================
loop_main() {
    local target="${1:-$PWD}"

    if [[ ! -d "$target" ]]; then
        printf 'omnish: %s: not a directory\n' "$target" >/dev/tty 2>/dev/null || \
        printf 'omnish: %s: not a directory\n' "$target" >&2
        exit 1
    fi

    get_term_size
    builtin cd "$target" || exit 1

    loop_list=()
    loop_marks=()
    loop_scroll=0
    loop_total=0
    loop_prev_idx=0
    loop_find_previous=0
    loop_show_help=0

    # [FIX 9] load persisted marks from disk before first draw
    loop_reload_marks_from_disk

    # [FIX 1] INT/TERM must exit; EXIT fires on natural exit
    trap 'loop_reset_terminal; cleanup' EXIT
    trap 'loop_reset_terminal; cleanup; exit 130' INT
    trap 'loop_reset_terminal; cleanup; exit 143' TERM
    trap 'get_term_size; loop_draw' WINCH

    loop_setup_terminal
    loop_read_dir
    loop_rebuild_visual_marks
    loop_draw

    local k
    while :; do
        IFS= read -rsn 1 -t 0.05 k 2>/dev/null || { [[ -t 1 ]] || exit 1; continue; }
        [[ -t 1 ]] || exit 1
        loop_handle_key "$k"
    done
}