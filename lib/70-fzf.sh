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
#
# [FIX layout 1] fzf_binds neutralises FZF_DEFAULT_OPTS/FZF_DEFAULT_COMMAND
#                so a user's shell config (e.g. --height=30%) can no longer
#                shrink/hide the file manager pane.
# [FIX layout 2] fzf_binds passes --height=100% and --layout=reverse
#                explicitly, and no longer swallows fzf stderr into $selected
#                (the old trailing `2>&1` polluted the selection buffer with
#                fzf warnings).
# [FIX layout 3] f_header_text shrinks to a single line on short terminals
#                (LINES < 32) to leave room for the file list.
# [FIX trap]     fzf_main restores the terminal (cursor + alt-screen) on
#                exit/INT/TERM in addition to cleanup.

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

    # [FIX layout 3] short terminals get a compact one-line header so the
    # file list has room to breathe; tall terminals keep the boxed header.
    local lines=${LINES:-0}
    (( lines < 1 )) && lines=$(tput lines 2>/dev/null) && [[ -n "$lines" ]] || lines=24

    local columns=${COLUMNS:-0}
    if (( lines < 32 || columns < 100 )); then
        printf 'omnish v%s | ?:help | ^X:sys | ^D:trash | %s' \
            "$OMNISH_VERSION" "$marked_status"
    else
        cat <<EOF
╭─ omnish v${OMNISH_VERSION} ─────────────────────────╮
 Tab/⇧Tab: multi-select | ?/F1: help | F5: reload
 ^X: system menu | ^U: dua | ^Y/^V: copy/move | ^D: trash
 ^H: help pane | alt-u: undo | alt-t: trash-view
 Preview: $preview_status | Files: $marked_status
╰─────────────────────────────────────────────────────╯
EOF
    fi
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
            if [[ -e "$f" || -L "$f" ]]; then
                if [[ -L "$f" ]]; then all_files+=("$PWD/${f#./}")
                else all_files+=("$(realpath -- "$f")"); fi
            fi
        done < <(find . -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    else
        while IFS= read -r -d '' f; do
            if [[ -e "$f" || -L "$f" ]]; then
                if [[ -L "$f" ]]; then all_files+=("$PWD/${f#./}")
                else all_files+=("$(realpath -- "$f")"); fi
            fi
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
        *)
            local shell="$SHELL"
            [[ -n "$shell" ]] || shell=bash
            xterm -e "$shell" -lc 'cd -- "$1"; exec "$2" -i' omnish "$PWD" "$shell" ;;
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

# ===============================================================
# [FIX trap] Terminal restoration used by fzf_main traps.
# Defined here (not in the entrypoint) so subcommands spawned by fzf
# via `execute(...)` don't touch the parent terminal state.
# ===============================================================
_omnish_term_restore() {
    [[ -t 0 || -t 1 || -t 2 ]] || return 0
    tput cnorm >/dev/tty 2>/dev/null || printf '\033[?25h' >/dev/tty 2>/dev/null || true
    tput rmcup >/dev/tty 2>/dev/null || true
}

# Return the adaptive preview width in columns. Explicit user widths are
# honored (and capped to the current layout); the default follows the same
# portrait/landscape split as the loop backend.
fzf_preview_width() {
    local columns="${1:-${COLUMNS:-80}}"
    local lines="${2:-${LINES:-24}}"
    local requested
    if (( $# >= 3 )); then
        requested="$3"
    else
        requested="${OMNISH_PREVIEW_WIDTH:-}"
    fi
    local max_preview width

    if (( columns > lines )); then
        max_preview=$(( columns * 60 / 100 ))
    else
        max_preview=$(( columns * 50 / 100 ))
    fi
    (( max_preview < 1 )) && max_preview=1

    case "$requested" in
        *%)
            if [[ "$requested" =~ ^([0-9]+)%$ ]]; then
                width=$(( columns * ${BASH_REMATCH[1]} / 100 ))
            else
                width=$max_preview
            fi
            ;;
        *)
            if [[ "$requested" =~ ^[0-9]+$ ]]; then
                width=$requested
            else
                width=$max_preview
            fi
            ;;
    esac

    (( width < 1 )) && width=1
    (( width > max_preview )) && width=$max_preview
    printf '%s\n' "$width"
}

fzf_binds() {
    local path="$1"
    local header_text margin_preview
    header_text=$(f_header_text)
    margin_preview=$(fzf_preview_width "$COLUMNS" "$LINES")

    local hidepreview=''
    [[ -f "$CACHE_OMNISH_DIR/hidepreview" ]] && hidepreview=':hidden'

    # Keep the side preview available on typical 80-column terminals;
    # hide it only when the terminal is genuinely too narrow or too short.
    local preview_window
    if (( COLUMNS < 70 || LINES < 10 )); then
        preview_window='hidden'
    else
        preview_window="right:${margin_preview}:noborder${hidepreview}"
    fi

    # [FIX layout 1] Neutralise FZF_DEFAULT_OPTS / FZF_DEFAULT_COMMAND so a
    # shell-level `--height=30%` or custom default command can't shrink or
    # hijack the file manager pane. We pass every option explicitly below.
    # [FIX layout 2] --height=100% + --layout=reverse make the pane occupy
    # the whole terminal with the prompt at the top — the standard file
    # manager layout (ranger/lf/yazi/nnn). No trailing 2>&1 anymore: fzf
    # warnings must not end up in $selected.
    local result fzf_status=0
    result=$(safe_ls "$path" | \
        OMNISH_PREVIEW_BASE="$path" \
        FZF_DEFAULT_OPTS='' \
        FZF_DEFAULT_COMMAND='' \
        fzf --ansi --multi --no-bold \
            --height=100% \
            --layout=reverse \
            --margin=0,2 \
            --border \
            --pointer='▶' \
            --marker='✓' \
            --header "$header_text" \
            --prompt "omnish 🔍: " \
            --bind 'tab:toggle+down+execute-silent(bash "$OMNISH_ENTRYPOINT" --mark-file {})' \
            --bind 'shift-tab:toggle+up+execute-silent(bash "$OMNISH_ENTRYPOINT" --mark-file {})' \
            --bind 'space:toggle+execute-silent(bash "$OMNISH_ENTRYPOINT" --mark-file {})' \
            --bind 'right:accept' \
            --bind 'enter:accept' \
            --bind 'left:top+up+accept' \
            --bind 'ctrl-r,f5:top+accept' \
            --bind '?:preview(cat "$TMP_OMNISH_DIR/help.txt" 2>/dev/null || echo "help unavailable")' \
            --bind 'ctrl-h:change-preview(cat "$TMP_OMNISH_DIR/help.txt" 2>/dev/null || echo "help unavailable")+show-preview' \
            --bind 'f1:execute(bash "$OMNISH_ENTRYPOINT" --show-help {})' \
            --bind 'f2,ctrl-space:execute(bash "$OMNISH_ENTRYPOINT" --scratchpad {})' \
            --bind 'ctrl-x:execute(bash "$OMNISH_ENTRYPOINT" --system-menu)+top+accept' \
            --bind 'ctrl-o:execute(bash "$OMNISH_ENTRYPOINT" --xdg-open {})+top+accept' \
            --bind 'ctrl-v:execute(bash "$OMNISH_ENTRYPOINT" --move-file {})+top+accept' \
            --bind 'ctrl-y:execute(bash "$OMNISH_ENTRYPOINT" --copy-file {})+top+accept' \
            --bind 'alt-n:execute(bash "$OMNISH_ENTRYPOINT" --create-file {})+top+accept' \
            --bind 'ctrl-n:execute(bash "$OMNISH_ENTRYPOINT" --create-directory {})+top+accept' \
            --bind 'ctrl-s:execute(bash "$OMNISH_ENTRYPOINT" --create-symlink {})+top+accept' \
            --bind 'ctrl-d,ctrl-e:execute(bash "$OMNISH_ENTRYPOINT" --delete-file {})+top+accept' \
            --bind 'ctrl-u:execute(bash "$OMNISH_ENTRYPOINT" --dua "$PWD")+top+accept' \
            --bind 'alt-u:execute(bash "$OMNISH_ENTRYPOINT" --undo)+top+accept' \
            --bind 'alt-t:execute(bash "$OMNISH_ENTRYPOINT" --trash-view)+top+accept' \
            --bind 'ctrl-g:execute({ [ ! -f "$TMP_OMNISH_DIR/grep" ] && bash "$OMNISH_ENTRYPOINT" --search-term; } || rm -f "$TMP_OMNISH_DIR/grep")+top+accept' \
            --bind 'alt-a:toggle+execute-silent(bash "$OMNISH_ENTRYPOINT" --mark-file {})' \
            --bind 'alt-x:select-all+execute-silent(bash "$OMNISH_ENTRYPOINT" --mark-all-only)' \
            --bind 'ctrl-a:toggle-all+execute-silent(bash "$OMNISH_ENTRYPOINT" --mark-all-toggle)' \
            --bind 'alt-h:execute-silent({ [ ! -f "$CACHE_OMNISH_DIR/showhidden" ] && touch "$CACHE_OMNISH_DIR/showhidden"; } || rm -f "$CACHE_OMNISH_DIR/showhidden")+top+accept' \
            --bind 'alt-l:execute-silent({ [ ! -f "$CACHE_OMNISH_DIR/longfilemanager" ] && touch "$CACHE_OMNISH_DIR/longfilemanager"; } || rm -f "$CACHE_OMNISH_DIR/longfilemanager")+top+accept' \
            --bind 'ctrl-p:toggle-preview+execute-silent({ [ ! -f "$CACHE_OMNISH_DIR/hidepreview" ] && touch "$CACHE_OMNISH_DIR/hidepreview"; } || rm -f "$CACHE_OMNISH_DIR/hidepreview")+top+accept' \
            --bind 'esc:abort,ctrl-q:abort,ctrl-c:abort' \
            --preview 'OMNISH_PREVIEW_BACKEND=fzf bash "$OMNISH_ENTRYPOINT" --preview-file "$OMNISH_PREVIEW_BASE"/{}' \
            --preview-window "$preview_window" \
            --expect=enter,right) || fzf_status=$?

    # fzf returns 130 for abort (Esc, Ctrl-Q or Ctrl-C). Propagate that
    # cancellation to fzf_main instead of restarting an empty selection.
    (( fzf_status == 130 )) && return 1

    selected=$(clean_path "$result" | sed 's|^\\./||g')
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

    # [FIX trap] The EXIT trap now also restores the terminal (cursor +
    # alt-screen) so a crash cannot leave the user's terminal unusable.
    # INT/TERM only call `exit`; the EXIT trap does the actual cleanup
    # exactly once (avoids double-cleanup of $TMP_OMNISH_DIR).
    # This trap lives here — NOT in the entrypoint — because subcommands
    # invoked by fzf via `execute(...)` (--mark-file, --copy-file, etc.)
    # must not touch the parent terminal or wipe $TMP_OMNISH_DIR.
    trap 'cleanup; _omnish_term_restore' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

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