# omnish — bubble-dua (integrated disk usage analysis)
# Inspired by dust (bootandy) and dua-cli (Byron).
# Two views:
#   flat  — first-level sizes (default, fast, batched)
#   tree  — recursive, sorted by size, with percentage bars (dust-like)
# Filters (tree mode): depth, max lines, min percentage, excludes.
#
# Configurable via omnish.conf:
#   DUA_TREE_DEPTH=3        recursion depth for tree view
#   DUA_TREE_LINES=30       max lines displayed in tree view
#   DUA_MIN_PCT=1           hide entries below this % of total
#   DUA_EXCLUDES=".git node_modules .cache"   space-separated dir names to skip
#   DUA_MODE=flat|tree      initial mode (default: flat)
#   DUA_BAR_WIDTH=12        bar width in characters
#
# [FIX 1] --ansi missing in fzf call → tree mode showed literal ^[[... codes.
# [FIX 2] awk printed float pct → bash printf '%3d%%' failed ("invalid number"),
#         pct always displayed as 0%. Now awk uses int().
# [FIX 3] Empty directory caused infinite loop in _dua_interactive (continue
#         without changing cur when history was empty).
# [FIX 4] _dua_scan with empty results printed a stray "0B\t" line.
# [FIX 5] _dua_scan forked du per entry (N forks). Now uses xargs -0 -r du
#         batch (~3 forks total). Huge speedup on proot.
# [FIX 6] _dua_scan was missing -x → crossed mount points (e.g. /proc).
# [FIX 7] _dua_preview was missing -x → same problem in preview.
# [FIX 8] _dua_preview hardcoded head -15; now uses $DUA_TREE_LINES.
# [FIX 9] ctrl-d only; added ctrl-e for consistency with 70-fzf.sh.
# [FIX 10] _dua_preview du could hang for minutes on huge dirs; capped
#          with `timeout 3` (already a coreutils dep).
# [FIX 11] Percent color now also colors the pct number (cosmetic).

DUA_TREE_DEPTH="${DUA_TREE_DEPTH:-3}"
DUA_TREE_LINES="${DUA_TREE_LINES:-30}"
DUA_MIN_PCT="${DUA_MIN_PCT:-1}"
DUA_EXCLUDES="${DUA_EXCLUDES:-.git node_modules .cache .venv target}"
DUA_MODE="${DUA_MODE:-flat}"
DUA_BAR_WIDTH="${DUA_BAR_WIDTH:-12}"

# ===============================================================
# Helpers
# ===============================================================
_dua_human() {
    local b=${1:-0}
    # Guard against non-numeric input (e.g. empty, float, garbage)
    [[ "$b" =~ ^[0-9]+$ ]] || b=0
    if   (( b >= 1073741824 )); then
        printf '%d.%dG' $(( b / 1073741824 )) $(( (b % 1073741824) * 10 / 1073741824 ))
    elif (( b >= 1048576 )); then
        printf '%d.%dM' $(( b / 1048576 ))    $(( (b % 1048576)    * 10 / 1048576 ))
    elif (( b >= 1024 )); then
        printf '%d.%dK' $(( b / 1024 ))       $(( (b % 1024)       * 10 / 1024 ))
    else
        printf '%dB' "$b"
    fi
}

_dua_bar() {
    local pct="${1:-0}" width="${2:-$DUA_BAR_WIDTH}"
    [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
    local filled=$(( pct * width / 100 ))
    (( filled > width )) && filled=$width
    (( filled < 0 ))     && filled=0
    local i bar=''
    for (( i=0; i<filled; i++ ));       do bar+='█'; done
    for (( i=filled; i<width; i++ ));   do bar+='░'; done
    printf '%s' "$bar"
}

_dua_color_pct() {
    local pct="${1:-0}"
    [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
    if   (( pct >= 50 )); then printf '\033[1;31m'   # red
    elif (( pct >= 20 )); then printf '\033[1;33m'   # yellow
    elif (( pct >= 5  )); then printf '\033[1;32m'   # green
    else                       printf '\033[0;37m'   # gray
    fi
}

# ===============================================================
# Scan — flat (first level, batched, fast)
# Output: "<display>\t<full_path>"
# [FIX 5] Uses xargs -0 -r du (one batch, ~3 forks) instead of N forks.
# [FIX 6] Added -x (one-file-system) to avoid crossing mounts.
# [FIX 4] Returns early if nothing to display (no stray empty line).
# ===============================================================
_dua_scan() {
    local dir="${1:-$PWD}"
    [[ -d "$dir" ]] || { printf 'Error: not a directory\n' >&2; return 1; }

    local raw
    raw=$(
        find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null \
        | xargs -0 -r du -sblx -- 2>/dev/null \
        | LC_ALL=C sort -t$'\t' -k1,1rn
    )

    [[ -z "$raw" ]] && return 0

    while IFS=$'\t' read -r s p; do
        [[ -z "$p" ]] && continue
        printf '%s\t%s\n' "$(_dua_human "$s")" "$p"
    done <<< "$raw"
}

# ===============================================================
# Scan — tree (recursive, dust-like)
# Output: "<display>\t<full_path>"
# [FIX 2] awk now emits int(pct), not float, so bash printf '%3d%%' works.
# [FIX 11] pct number is colored too.
# ===============================================================
_dua_tree_scan() {
    local dir="${1:-$PWD}"
    local depth="${2:-$DUA_TREE_DEPTH}"
    local maxlines="${3:-$DUA_TREE_LINES}"
    local min_pct="${4:-$DUA_MIN_PCT}"
    local excludes="${5:-$DUA_EXCLUDES}"

    [[ -d "$dir" ]] || { printf 'Error: not a directory\n' >&2; return 1; }

    local total
    total=$(du -sblx -- "$dir" 2>/dev/null | cut -f1)
    [[ -z "$total" || "$total" -le 0 ]] && return 0

    local du_excl=() ex
    for ex in $excludes; do
        du_excl+=(--exclude="$ex")
    done

    du -blx --max-depth="$depth" "${du_excl[@]}" -- "$dir" 2>/dev/null \
    | LC_ALL=C sort -k1,1rn \
    | awk -v total="$total" -v dir="$dir" -v minpct="$min_pct" -v maxlines="$maxlines" '
        {
            size = $1
            path = substr($0, length($1) + 2)
            if (path == dir) next
            pct = (size * 100 / total)
            if (pct < minpct) next
            n++
            if (n > maxlines) exit
            rel = substr(path, length(dir) + 2)
            nparts = split(rel, parts, "/")
            d = nparts - 1
            indent = ""
            for (i = 0; i < d; i++) indent = indent "  "
            nparts = split(path, p, "/")
            name = p[nparts]
            printf "%d\t%d\t%s\t%s\t%s\n", size, int(pct), indent, name, path
        }' \
    | while IFS=$'\t' read -r size pct indent name path; do
        local human bar color reset
        human=$(_dua_human "$size")
        bar=$(_dua_bar "$pct")
        color=$(_dua_color_pct "$pct")
        reset=$'\033[0m'
        printf '%s %s%s %3d%%%s %s%s\t%s\n' \
            "$human" "$color" "$bar" "$pct" "$reset" "$indent" "$name" "$path"
    done
}

# ===============================================================
# Preview
# [FIX 7] -x added to du calls.
# [FIX 8] head uses $DUA_TREE_LINES instead of hardcoded 15.
# [FIX 10] `timeout 3` caps du on huge directories.
# ===============================================================
_dua_preview() {
    local path="${1%/}"
    [[ -z "$path" ]] && { echo "(empty)"; return; }
    [[ -e "$path" || -L "$path" ]] || { echo "(inaccessible: $path)"; return; }
    [[ -L "$path" ]] && printf '→ %s\n\n' "$(readlink -f "$path" 2>/dev/null)"

    local top_n="${DUA_TREE_LINES:-15}"
    (( top_n < 5 )) && top_n=5

    if [[ -d "$path" ]]; then
        printf '\033[1m📁 %s\033[0m\n\n' "$path"
        local total
        total=$(timeout 3 du -sblx -- "$path" 2>/dev/null | cut -f1)
        printf 'Total: \033[32m%s\033[0m\n\n' "$(_dua_human "${total:-0}")"
        printf '\033[1mTop %d:\033[0m\n' "$top_n"
        find "$path" -mindepth 1 -maxdepth 1 -print0 2>/dev/null \
            | xargs -0 -r du -sblx -- 2>/dev/null \
            | LC_ALL=C sort -t$'\t' -k1,1rn \
            | head -n "$top_n" \
            | while IFS=$'\t' read -r s p; do
                printf '  %8s  %s\n' "$(_dua_human "$s")" "$(basename -- "$p")"
            done
    elif [[ -f "$path" ]]; then
        printf '\033[1m📄 %s\033[0m\n\n' "$(basename -- "$path")"
        file -b -- "$path" 2>/dev/null
        printf '\n'
        stat --printf='Size: %s bytes\nMode: %A\nOwner: %U:%G\nMtime: %y\n' -- "$path" 2>/dev/null
        printf '\n\033[1mPreview:\033[0m\n'
        local mime
        mime=$(file -b --mime -- "$path" 2>/dev/null)
        if [[ "$mime" == text/* ]] || [[ "$mime" == *json* ]] \
           || [[ "$mime" == *xml* ]] || [[ "$mime" == *script* ]]; then
            head -c 2048 -- "$path" 2>/dev/null
        else
            echo "(binary)"
        fi
    else
        echo "(special)"
    fi
}

# ===============================================================
# Interactive
# [FIX 1] --ansi added to fzf call.
# [FIX 3] Empty directory no longer loops forever.
# [FIX 9] ctrl-e works like ctrl-d (trash).
# ===============================================================
# Native fallback for the loop backend: no fzf process or dependency.
_dua_interactive_loop() {
    local cur="${1:-$PWD}" mode="$DUA_MODE" depth="$DUA_TREE_DEPTH"
    local selection index path display
    local -a rows=()

    while :; do
        rows=()
        if [[ "$mode" == "tree" ]]; then
            mapfile -t rows < <(_dua_tree_scan "$cur" "$depth" "$DUA_TREE_LINES" 2>/dev/null)
        else
            mapfile -t rows < <(_dua_scan "$cur" 2>/dev/null)
        fi

        printf '\nDisk Usage [%s] %s\n' "$mode" "$cur"
        printf 'Enter N: open/descend | u: up | t: toggle view | +/-: depth | r: rescan | q: quit\n\n'
        if (("${#rows[@]}" == 0)); then
            printf '  (empty)\n'
        else
            local i
            for i in "${!rows[@]}"; do
                display="${rows[i]%%$'\t'*}"
                printf ' %3d) %s\n' "$((i + 1))" "$display"
            done
        fi
        printf '\nChoice: '
        IFS= read -r selection </dev/tty || return 0

        case "$selection" in
            q|Q|esc) return 0 ;;
            u|U)
                [[ "$cur" != "/" ]] && cur=$(dirname -- "$cur")
                continue ;;
            t|T)
                [[ "$mode" == "tree" ]] && mode="flat" || mode="tree"
                continue ;;
            +)
                (( depth < 10 )) && ((++depth))
                continue ;;
            -)
                (( depth > 1 )) && ((--depth))
                continue ;;
            r|R) continue ;;
        esac

        if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#rows[@]} )); then
            index=$((selection - 1))
            path="${rows[index]#*$'\t'}"
            [[ -e "$path" || -L "$path" ]] || { printf 'Not found: %s\n' "$path"; continue; }

            if [[ -d "$path" && ! -L "$path" ]]; then
                cur="$path"
            else
                if command -v less >/dev/null 2>&1; then
                    _dua_preview "$path" | less -R
                else
                    _dua_preview "$path"
                    printf '\nPress Enter to continue...'
                    IFS= read -r _ </dev/tty || true
                fi
            fi
        fi
    done
}

_dua_interactive() {
    local cur="${1:-$PWD}"
    if [[ "${OMNISH_BACKEND:-fzf}" != "fzf" ]] || ! command -v fzf >/dev/null 2>&1; then
        _dua_interactive_loop "$cur"
        return $?
    fi
    local history=()
    local mode="$DUA_MODE"
    local depth="$DUA_TREE_DEPTH"
    local maxlines="$DUA_TREE_LINES"
    local preview_w

    preview_w="${OMNISH_PREVIEW_WIDTH:-$(cat "$MARGIN_PREVIEW" 2>/dev/null || echo 60)}"

    while :; do
        local result key sel path listfile
        listfile="$TMP_OMNISH_DIR/dua_list.$$"

        # --- Phase 1: scan ---
        if [[ "$mode" == "tree" ]]; then
            spinner_begin "tree scan (depth=$depth)"
            _dua_tree_scan "$cur" "$depth" "$maxlines" > "$listfile" 2>/dev/null
            spinner_end
        else
            _dua_scan "$cur" > "$listfile" 2>/dev/null
        fi

        # [FIX 3] Empty dir: don't loop, pop history or return
        if [[ ! -s "$listfile" ]]; then
            rm -f "$listfile"
            if (( ${#history[@]} > 0 )); then
                status_msg "(empty)"
                cur="${history[-1]}"
                unset 'history[-1]'
                continue
            fi
            status_msg "(empty)"
            return 0
        fi

        # --- Phase 2: header ---
        local header
        if [[ "$mode" == "tree" ]]; then
            header="Disk Usage [tree depth=$depth lines=$maxlines] $cur
 Enter: descend | C-h: up | C-o: open | C-d/C-e: trash | C-r: rescan | C-t: flat | alt-d/D: depth | Esc: back"
        else
            header="Disk Usage [flat] $cur
 Enter: descend | C-h: up | C-o: open | C-d/C-e: trash | C-r: rescan | C-t: tree | Esc: back"
        fi

        # --- Phase 3: fzf [FIX 1] --ansi ---
        if ! result=$(
            fzf --ansi --delimiter=$'\t' --with-nth=1 --no-sort \
                --expect=ctrl-h,ctrl-d,ctrl-e,ctrl-o,ctrl-r,ctrl-t,alt-d,alt-D,esc \
                --header "$header" \
                --preview "bash \"$SCRIPT_PATH\" --dua-preview {2}" \
                --preview-window "right:${preview_w}:wrap" \
                < "$listfile"
        ); then
            rm -f "$listfile"
            if (( ${#history[@]} > 0 )); then
                cur="${history[-1]}"; unset 'history[-1]'
                continue
            fi
            return 0
        fi
        rm -f "$listfile"

        key=$(head -n1 <<< "$result")
        sel=$(tail -n +2 <<< "$result")
        path="${sel#*$'\t'}"
        [[ -z "$path" ]] && continue

        case "$key" in
            esc)
                if (( ${#history[@]} > 0 )); then
                    cur="${history[-1]}"; unset 'history[-1]'
                    continue
                fi
                return 0 ;;
            ctrl-h)
                if (( ${#history[@]} > 0 )); then
                    cur="${history[-1]}"; unset 'history[-1]'
                else
                    cur=$(dirname -- "$cur")
                fi
                continue ;;
            ctrl-r) continue ;;
            ctrl-t)
                [[ "$mode" == "flat" ]] && mode="tree" || mode="flat"
                continue ;;
            alt-d)
                (( depth < 10 )) && (( depth++ ))
                status_msg "depth=$depth"
                continue ;;
            alt-D)
                (( depth > 1 )) && (( depth-- ))
                status_msg "depth=$depth"
                continue ;;
        esac

        case "$key" in
            ctrl-d|ctrl-e)     # [FIX 9] both keys work
                cmd_yes_no "Trash '$(basename -- "$path")'?"
                if [[ $cmd_reply == yes ]]; then
                    if [[ ${OMNI_USE_TRASH:-1} == 1 ]]; then
                        trash "$path"
                    else
                        rm -rf -- "$path"
                    fi
                fi
                ;;
            ctrl-o)
                if [[ -d "$path" ]]; then
                    ( cd -- "$path" && "${SHELL:-bash}" ) || true
                else
                    "${EDITOR:-vi}" -- "$path" || true
                fi
                ;;
            *)
                if [[ -d "$path" && ! -L "$path" ]]; then
                    history+=("$cur"); cur="$path"
                elif [[ -f "$path" ]]; then
                    "${PAGER:-less}" -- "$path" || true
                fi
                ;;
        esac
    done
}