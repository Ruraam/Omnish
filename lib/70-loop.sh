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
    # Capture the exact state once. External tools may temporarily use the
    # terminal, but every return to the loop must preserve this original state.
    if [[ -z "${OMNISH_TTY_SAVED_STTY:-}" ]]; then
        OMNISH_TTY_SAVED_STTY=$(stty -g </dev/tty 2>/dev/null) || return 1
    fi
    printf '\e[?1049h\e[?7l\e[?25l\e[2J'
    stty -echo -icanon min 1 time 0 </dev/tty 2>/dev/null
}

loop_reset_terminal() {
    printf '\e[?7h\e[?25h\e[2J\e[;r\e[?1049l'
    if [[ -n "${OMNISH_TTY_SAVED_STTY:-}" ]]; then
        stty "${OMNISH_TTY_SAVED_STTY}" </dev/tty 2>/dev/null
    else
        stty sane </dev/tty 2>/dev/null
    fi
}

loop_clear_scroll() {
    local bottom=${LINES:-24}
    (( bottom > 1 )) && (( bottom-=1 )) || bottom=1
    printf '\e[1;%sH\e[J\e[1;%sr' "$bottom" "$bottom"
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
    return 0
}

# Keep symlinks as independently markable entries; canonicalize other paths.
_loop_mark_identity() {
    local path="$1"
    if [[ -L "$path" ]]; then
        printf '%s' "$path"
    else
        realpath -- "$path" 2>/dev/null || printf '%s' "$path"
    fi
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
        real=$(_loop_mark_identity "${loop_list[i]}") || continue
        [[ -n "${mark_set[$real]:-}" ]] && loop_marks[$i]="${loop_list[i]}"
    done
    return 0
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

    # Keep the caller's shell options intact. Also force dotglob off for
    # the default listing, even if the caller enabled it before this function.
    local nullglob_was_set=0 dotglob_was_set=0
    shopt -q nullglob && nullglob_was_set=1
    shopt -q dotglob && dotglob_was_set=1

    local -a entries=()
    shopt -s nullglob
    shopt -u dotglob
    [[ -f "$CACHE_OMNISH_DIR/showhidden" ]] && shopt -s dotglob
    entries=("$base"/*)

    if (( nullglob_was_set )); then shopt -s nullglob; else shopt -u nullglob; fi
    if (( dotglob_was_set )); then shopt -s dotglob; else shopt -u dotglob; fi

    for item in "${entries[@]}"; do
        [[ -e "$item" || -L "$item" ]] || continue
        if [[ -d "$item" ]]; then
            dirs+=("$item")
            [[ "$item" == "$OLDPWD" ]] && prev_idx=$idx
            ((idx+=1))
        else
            files+=("$item")
        fi
    done

    loop_list=("${dirs[@]}" "${files[@]}")
    [[ ${#loop_list[@]} -eq 0 ]] && loop_list=("empty")
    loop_total=$(( ${#loop_list[@]} - 1 ))
    loop_prev_idx=$prev_idx
    return 0
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
    local tmpf="$TMP_OMNISH_DIR/loop_preview.$$"

    if (( ${loop_show_help:-0} )); then
        local helpfile
        helpfile="$(_loop_ensure_helpfile)"
        [[ -r "$helpfile" ]] && cp "$helpfile" "$tmpf" 2>/dev/null
    else
        local entry="${loop_list[loop_scroll]:-}"
        [[ -z "$entry" || "$entry" == "empty" ]] && return
        _preview_file "$entry" > "$tmpf" 2>/dev/null
    fi

    local row=0 line
    while IFS= read -r line && (( row < lines )); do
        local visible
        visible=$(printf '%s' "$line" | sed 's/\x1b\[[0-9;]*m//g')
        (( ${#visible} > width )) && line="${visible:0:width-1}…"
        printf '\e[%s;%sH%s\e[K' "$((row+1))" "$col" "$line"
        ((row+=1))
    done < "$tmpf"
    rm -f "$tmpf"
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
    loop_clear_scroll

    # Responsive layout: reserve the preview pane only when it can remain
    # useful. Narrow/short terminals get the full width for the file list.
    local split list_w prev_w rows
    rows=$(( LINES - 2 ))
    (( rows < 1 )) && rows=1

    if (( COLUMNS >= 90 && LINES >= 10 )) && [[ ! -f "$CACHE_OMNISH_DIR/hidepreview" ]]; then
        split=$(( COLUMNS * 45 / 100 ))
        list_w=$(( split - 2 ))
        prev_w=$(( COLUMNS - split - 2 ))
        (( list_w < 1 )) && list_w=1
        (( prev_w < 1 )) && prev_w=1
        loop_preview_visible=1
    else
        split=0
        list_w=$(( COLUMNS - 2 ))
        (( list_w < 1 )) && list_w=1
        prev_w=0
        loop_preview_visible=0
    fi
    loop_list_width=$list_w
    loop_preview_width=$prev_w
    loop_rows=$rows

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
        ((row+=1))
    done

    if (( loop_preview_visible )); then
        for (( row=0; row<rows; row++ )); do
            printf '\e[%s;%sH\e[2m│\e[m' "$((row+1))" "$split"
        done
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
        [[ -n "${loop_marks[k]:-}" ]] && ((mark_count+=1))
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
        if IFS= read -rsn 1 -t 0.08 -u "$OMNISH_TTY_FD" c1 2>/dev/null; then
            if [[ "$c1" == '[' || "$c1" == 'O' ]]; then
                if IFS= read -rsn 1 -t 0.08 -u "$OMNISH_TTY_FD" c2 2>/dev/null; then
                    case "${c1}${c2}" in
                        '[A'|'OA') k='UP' ;;
                        '[B'|'OB') k='DOWN' ;;
                        '[C'|'OC') k='RIGHT' ;;
                        '[D'|'OD') k='LEFT' ;;
                        '[Z')      k='SHIFT_TAB' ;;
                        'OQ'|'[12~') k='F2' ;;
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
        j|DOWN)  (( loop_scroll < loop_total )) && (( loop_scroll+=1 )) ; loop_show_help=0 ; loop_draw ;;
        k|UP)    (( loop_scroll > 0 )) && loop_scroll=$(( loop_scroll - 1 )) ; loop_show_help=0 ; loop_draw ;;
        g)       loop_scroll=0 ; loop_show_help=0 ; loop_draw ;;
        G)       loop_scroll=$loop_total ; loop_show_help=0 ; loop_draw ;;
        l|RIGHT|'')  loop_open_selected ;;
        h|LEFT|$'\177'|BACKSPACE) loop_go_parent ;;
        e|F5)    loop_draw full ;;

        q|ESC)   loop_quit ;;

        # === Multi-select ===
        $'\t')
                 loop_mark_current_silent
                 (( loop_scroll < loop_total )) && (( loop_scroll+=1 ))
                 loop_show_help=0
                 loop_draw
                 ;;
        SHIFT_TAB)
                 loop_mark_current_silent
                 (( loop_scroll > 0 )) && loop_scroll=$(( loop_scroll - 1 ))
                 loop_show_help=0
                 loop_draw
                 ;;

        # === Scratchpad ===
        F2)      loop_reset_terminal
                 scratchpad_open "$(loop_current_path)"
                 loop_setup_terminal
                 loop_show_help=0
                 loop_draw full
                 ;;

        
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
    real=$(_loop_mark_identity "$entry")

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
        real=$(_loop_mark_identity "${loop_list[i]}")
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
        real=$(_loop_mark_identity "${loop_list[i]}")
        current_reals+=("$real")
    done

    local marked_count=0
    for real in "${current_reals[@]}"; do
        [[ -n "${current_marked[$real]:-}" ]] && ((marked_count+=1))
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
    _fileops_has_duplicate_basenames "${marked_files[@]}" && {
        status_msg "duplicate basenames in selection; paste separately"
        loop_draw
        return
    }

    local -a existing=()
    local f
    for f in "${marked_files[@]}"; do
        [[ -e "$PWD/${f##*/}" || -L "$PWD/${f##*/}" ]] && existing+=("${f##*/}")
    done
    if (( ${#existing[@]} > 0 )); then
        cmd_yes_no "Overwrite ${#existing[@]} existing item(s)?"
        [[ $cmd_reply == yes ]] || { status_msg "cancelled"; loop_draw; return; }
    fi

    local total=${#marked_files[@]}
    spinner_begin "pasting $total item(s)"
    if cp -rf -- "${marked_files[@]}" "$PWD" 2>/dev/null; then
        spinner_end
        status_msg "pasted $total item(s)"
        marked_files=()
        sync_marked_files
    else
        spinner_end
        status_msg "paste failed (marks kept)"
    fi
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
    while IFS= read -rsn 1 -t 2 -u "$OMNISH_TTY_FD" ch; do
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
        loop_total=$(( ${#loop_list[@]} - 1 ))
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
    read -rsn 1 -u "$OMNISH_TTY_FD" -p "Press any key…"
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
loop_flush_input() {
    [[ -n "${OMNISH_TTY_FD:-}" ]] || return 0
    local pending=""
    while IFS= read -rsn 1 -t 0.01 -u "$OMNISH_TTY_FD" pending 2>/dev/null; do
        pending=""
    done
    return 0
}

loop_process_resize() {
    (( ${loop_resize_pending:-0} )) || return 0
    loop_resize_pending=0
    get_term_size
    loop_draw
    return 0
}

loop_main() {
    local target="${1:-$PWD}"
    local OMNISH_TTY_FD

    if [[ ! -r /dev/tty || ! -w /dev/tty ]] || ! exec {OMNISH_TTY_FD}<>/dev/tty; then
        printf "omnish: interactive loop backend requires a controlling TTY\\n" >&2
        exit 1
    fi

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

    # Save the caller's exact termios state before entering raw mode. Keep it
    # in shell scope so both the EXIT trap and cleanup() can restore it.
    unset OMNISH_TTY_SAVED_STTY
    OMNISH_TTY_SAVED_STTY=$(stty -g </dev/tty 2>/dev/null) || {
        printf 'omnish: unable to read terminal settings\n' >/dev/tty 2>/dev/null
        exec {OMNISH_TTY_FD}>&-
        exit 1
    }

    # [FIX 1] INT/TERM must exit; EXIT fires on natural exit
    loop_resize_pending=0
    trap 'loop_reset_terminal; cleanup; exec {OMNISH_TTY_FD}>&-' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'loop_resize_pending=1' WINCH

    loop_setup_terminal
    loop_read_dir
    loop_rebuild_visual_marks
    loop_draw

    local k
    while :; do
        loop_process_resize
        IFS= read -rsn 1 -t 0.05 -u "$OMNISH_TTY_FD" k 2>/dev/null || continue
        loop_handle_key "$k"
    done
}\x00'|F2) loop_reset_terminal
                 scratchpad_open "$(loop_current_path)"
                 loop_setup_terminal
                 loop_show_help=0
                 loop_draw full
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
    real=$(_loop_mark_identity "$entry")

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
        real=$(_loop_mark_identity "${loop_list[i]}")
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
        real=$(_loop_mark_identity "${loop_list[i]}")
        current_reals+=("$real")
    done

    local marked_count=0
    for real in "${current_reals[@]}"; do
        [[ -n "${current_marked[$real]:-}" ]] && ((marked_count+=1))
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
    _fileops_has_duplicate_basenames "${marked_files[@]}" && {
        status_msg "duplicate basenames in selection; paste separately"
        loop_draw
        return
    }

    local -a existing=()
    local f
    for f in "${marked_files[@]}"; do
        [[ -e "$PWD/${f##*/}" || -L "$PWD/${f##*/}" ]] && existing+=("${f##*/}")
    done
    if (( ${#existing[@]} > 0 )); then
        cmd_yes_no "Overwrite ${#existing[@]} existing item(s)?"
        [[ $cmd_reply == yes ]] || { status_msg "cancelled"; loop_draw; return; }
    fi

    local total=${#marked_files[@]}
    spinner_begin "pasting $total item(s)"
    if cp -rf -- "${marked_files[@]}" "$PWD" 2>/dev/null; then
        spinner_end
        status_msg "pasted $total item(s)"
        marked_files=()
        sync_marked_files
    else
        spinner_end
        status_msg "paste failed (marks kept)"
    fi
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
    while IFS= read -rsn 1 -t 2 -u "$OMNISH_TTY_FD" ch; do
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
        loop_total=$(( ${#loop_list[@]} - 1 ))
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
    read -rsn 1 -u "$OMNISH_TTY_FD" -p "Press any key…"
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
loop_flush_input() {
    [[ -n "${OMNISH_TTY_FD:-}" ]] || return 0
    local pending=""
    while IFS= read -rsn 1 -t 0.01 -u "$OMNISH_TTY_FD" pending 2>/dev/null; do
        pending=""
    done
    return 0
}

loop_process_resize() {
    (( ${loop_resize_pending:-0} )) || return 0
    loop_resize_pending=0
    get_term_size
    loop_draw
    return 0
}

loop_main() {
    local target="${1:-$PWD}"
    local OMNISH_TTY_FD

    if [[ ! -r /dev/tty || ! -w /dev/tty ]] || ! exec {OMNISH_TTY_FD}<>/dev/tty; then
        printf "omnish: interactive loop backend requires a controlling TTY\\n" >&2
        exit 1
    fi

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

    # Save the caller's exact termios state before entering raw mode. Keep it
    # in shell scope so both the EXIT trap and cleanup() can restore it.
    unset OMNISH_TTY_SAVED_STTY
    OMNISH_TTY_SAVED_STTY=$(stty -g </dev/tty 2>/dev/null) || {
        printf 'omnish: unable to read terminal settings\n' >/dev/tty 2>/dev/null
        exec {OMNISH_TTY_FD}>&-
        exit 1
    }

    # [FIX 1] INT/TERM must exit; EXIT fires on natural exit
    loop_resize_pending=0
    trap 'loop_reset_terminal; cleanup; exec {OMNISH_TTY_FD}>&-' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'loop_resize_pending=1' WINCH

    loop_setup_terminal
    loop_read_dir
    loop_rebuild_visual_marks
    loop_draw

    local k
    while :; do
        loop_process_resize
        IFS= read -rsn 1 -t 0.05 -u "$OMNISH_TTY_FD" k 2>/dev/null || continue
        loop_handle_key "$k"
    done
}\x08')
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
    real=$(_loop_mark_identity "$entry")

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
        real=$(_loop_mark_identity "${loop_list[i]}")
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
        real=$(_loop_mark_identity "${loop_list[i]}")
        current_reals+=("$real")
    done

    local marked_count=0
    for real in "${current_reals[@]}"; do
        [[ -n "${current_marked[$real]:-}" ]] && ((marked_count+=1))
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
    _fileops_has_duplicate_basenames "${marked_files[@]}" && {
        status_msg "duplicate basenames in selection; paste separately"
        loop_draw
        return
    }

    local -a existing=()
    local f
    for f in "${marked_files[@]}"; do
        [[ -e "$PWD/${f##*/}" || -L "$PWD/${f##*/}" ]] && existing+=("${f##*/}")
    done
    if (( ${#existing[@]} > 0 )); then
        cmd_yes_no "Overwrite ${#existing[@]} existing item(s)?"
        [[ $cmd_reply == yes ]] || { status_msg "cancelled"; loop_draw; return; }
    fi

    local total=${#marked_files[@]}
    spinner_begin "pasting $total item(s)"
    if cp -rf -- "${marked_files[@]}" "$PWD" 2>/dev/null; then
        spinner_end
        status_msg "pasted $total item(s)"
        marked_files=()
        sync_marked_files
    else
        spinner_end
        status_msg "paste failed (marks kept)"
    fi
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
    while IFS= read -rsn 1 -t 2 -u "$OMNISH_TTY_FD" ch; do
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
        loop_total=$(( ${#loop_list[@]} - 1 ))
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
    read -rsn 1 -u "$OMNISH_TTY_FD" -p "Press any key…"
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
loop_flush_input() {
    [[ -n "${OMNISH_TTY_FD:-}" ]] || return 0
    local pending=""
    while IFS= read -rsn 1 -t 0.01 -u "$OMNISH_TTY_FD" pending 2>/dev/null; do
        pending=""
    done
    return 0
}

loop_process_resize() {
    (( ${loop_resize_pending:-0} )) || return 0
    loop_resize_pending=0
    get_term_size
    loop_draw
    return 0
}

loop_main() {
    local target="${1:-$PWD}"
    local OMNISH_TTY_FD

    if [[ ! -r /dev/tty || ! -w /dev/tty ]] || ! exec {OMNISH_TTY_FD}<>/dev/tty; then
        printf "omnish: interactive loop backend requires a controlling TTY\\n" >&2
        exit 1
    fi

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

    # Save the caller's exact termios state before entering raw mode. Keep it
    # in shell scope so both the EXIT trap and cleanup() can restore it.
    unset OMNISH_TTY_SAVED_STTY
    OMNISH_TTY_SAVED_STTY=$(stty -g </dev/tty 2>/dev/null) || {
        printf 'omnish: unable to read terminal settings\n' >/dev/tty 2>/dev/null
        exec {OMNISH_TTY_FD}>&-
        exit 1
    }

    # [FIX 1] INT/TERM must exit; EXIT fires on natural exit
    loop_resize_pending=0
    trap 'loop_reset_terminal; cleanup; exec {OMNISH_TTY_FD}>&-' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'loop_resize_pending=1' WINCH

    loop_setup_terminal
    loop_read_dir
    loop_rebuild_visual_marks
    loop_draw

    local k
    while :; do
        loop_process_resize
        IFS= read -rsn 1 -t 0.05 -u "$OMNISH_TTY_FD" k 2>/dev/null || continue
        loop_handle_key "$k"
    done
}\x00'|F2) loop_reset_terminal
                 scratchpad_open "$(loop_current_path)"
                 loop_setup_terminal
                 loop_show_help=0
                 loop_draw full
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
    real=$(_loop_mark_identity "$entry")

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
        real=$(_loop_mark_identity "${loop_list[i]}")
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
        real=$(_loop_mark_identity "${loop_list[i]}")
        current_reals+=("$real")
    done

    local marked_count=0
    for real in "${current_reals[@]}"; do
        [[ -n "${current_marked[$real]:-}" ]] && ((marked_count+=1))
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
    _fileops_has_duplicate_basenames "${marked_files[@]}" && {
        status_msg "duplicate basenames in selection; paste separately"
        loop_draw
        return
    }

    local -a existing=()
    local f
    for f in "${marked_files[@]}"; do
        [[ -e "$PWD/${f##*/}" || -L "$PWD/${f##*/}" ]] && existing+=("${f##*/}")
    done
    if (( ${#existing[@]} > 0 )); then
        cmd_yes_no "Overwrite ${#existing[@]} existing item(s)?"
        [[ $cmd_reply == yes ]] || { status_msg "cancelled"; loop_draw; return; }
    fi

    local total=${#marked_files[@]}
    spinner_begin "pasting $total item(s)"
    if cp -rf -- "${marked_files[@]}" "$PWD" 2>/dev/null; then
        spinner_end
        status_msg "pasted $total item(s)"
        marked_files=()
        sync_marked_files
    else
        spinner_end
        status_msg "paste failed (marks kept)"
    fi
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
    while IFS= read -rsn 1 -t 2 -u "$OMNISH_TTY_FD" ch; do
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
        loop_total=$(( ${#loop_list[@]} - 1 ))
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
    read -rsn 1 -u "$OMNISH_TTY_FD" -p "Press any key…"
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
loop_flush_input() {
    [[ -n "${OMNISH_TTY_FD:-}" ]] || return 0
    local pending=""
    while IFS= read -rsn 1 -t 0.01 -u "$OMNISH_TTY_FD" pending 2>/dev/null; do
        pending=""
    done
    return 0
}

loop_process_resize() {
    (( ${loop_resize_pending:-0} )) || return 0
    loop_resize_pending=0
    get_term_size
    loop_draw
    return 0
}

loop_main() {
    local target="${1:-$PWD}"
    local OMNISH_TTY_FD

    if [[ ! -r /dev/tty || ! -w /dev/tty ]] || ! exec {OMNISH_TTY_FD}<>/dev/tty; then
        printf "omnish: interactive loop backend requires a controlling TTY\\n" >&2
        exit 1
    fi

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

    # Save the caller's exact termios state before entering raw mode. Keep it
    # in shell scope so both the EXIT trap and cleanup() can restore it.
    unset OMNISH_TTY_SAVED_STTY
    OMNISH_TTY_SAVED_STTY=$(stty -g </dev/tty 2>/dev/null) || {
        printf 'omnish: unable to read terminal settings\n' >/dev/tty 2>/dev/null
        exec {OMNISH_TTY_FD}>&-
        exit 1
    }

    # [FIX 1] INT/TERM must exit; EXIT fires on natural exit
    loop_resize_pending=0
    trap 'loop_reset_terminal; cleanup; exec {OMNISH_TTY_FD}>&-' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'loop_resize_pending=1' WINCH

    loop_setup_terminal
    loop_read_dir
    loop_rebuild_visual_marks
    loop_draw

    local k
    while :; do
        loop_process_resize
        IFS= read -rsn 1 -t 0.05 -u "$OMNISH_TTY_FD" k 2>/dev/null || continue
        loop_handle_key "$k"
    done
}