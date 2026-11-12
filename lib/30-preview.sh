# omnish — file preview engine
# Generic preview: dirs, text, images, pdf, markdown, archives.
# Everything else: file(1) + strings.
#
# [FIX 1] Termux detection: `TERMUX_VERSION` alone is unreliable — it can be
#         empty in proot but LINES still small. Cap by actual LINES too.
# [FIX 2] `width` was set but never used → now used for folding long lines
#         to the preview pane width (from MARGIN_PREVIEW).
# [FIX 3] Directory header was showing `ls -lha | head -n 2` = "." and ".."
#         (useless). Replaced with entry count + total size.
# [FIX 4] `directory_view`: eza ignored `showhidden` (bug); `-1` and `-l`
#         were passed together (conflict); `*` (exec) stripped in the ls
#         branch but not the eza branch (inconsistent).
# [FIX 5] `strings` isn't guaranteed (binutils). Added od(1) fallback and
#         graceful empty fallback.
# [FIX 6] Symlinks: show target at the top of the preview (readlink).
# [FIX 7] `file -b --mime` was called twice (once for type, once for MIME
#         check). Consolidated into one call for the text/JSON/XML test.
# [FIX 8] MIME check now catches application/json, application/xml,
#         *javascript*, *script* — not just ^text/ (which misses them).
# [FIX 9] `bat` and `glow` now respect pane width (--terminal-width / -w).
# [FIX 10] PDF preview: fold lines to pane width before head -n.
# [FIX 11] `xdg_open` validates path exists and opener is available.
# [FIX 12] `chafa` size respects pane height (was hardcoded -s 50).
# [FIX 13] Special files (fifo, socket, device): show type via stat(1)
#          instead of opaque "(special file)".
# [FIX 14] `_preview_file`: use MARGIN_PREVIEW to compute actual pane width
#          (fzf sets $COLUMNS to terminal width, not pane width).

# ===============================================================
# Compute preview dimensions from MARGIN_PREVIEW
# ===============================================================
_preview_dims() {
    local term_lines="${LINES:-24}" term_cols="${COLUMNS:-80}"
    (( term_lines > 0 )) || term_lines=24
    (( term_cols  > 0 )) || term_cols=80

    # [FIX 14] Pane width = MARGIN_PREVIEW (chars or "N%") if set
    local pane_w="$term_cols"
    local margin="${OMNISH_PREVIEW_WIDTH:-}"
    if [[ -z "$margin" && -r "${MARGIN_PREVIEW:-}" ]]; then
        margin=$(<"$MARGIN_PREVIEW")
    fi
    if [[ -n "$margin" ]]; then
        if [[ "$margin" =~ ^([0-9]+)%$ ]]; then
            pane_w=$(( term_cols * ${BASH_REMATCH[1]} / 100 ))
        elif [[ "$margin" =~ ^[0-9]+$ ]]; then
            pane_w="$margin"
        fi
    fi
    (( pane_w < 20 ))  && pane_w=20
    (( pane_w > 400 )) && pane_w=$term_cols

    # [FIX 1] Preview lines: cap by actual terminal height, then by Termux
    local pane_h=$(( term_lines - 2 ))
    (( pane_h < 5 ))  && pane_h=5
    (( pane_h > 50 )) && pane_h=50
    if [[ -n "${TERMUX_VERSION:-}" ]] && (( pane_h > 20 )); then
        pane_h=20
    fi

    printf '%d %d\n' "$pane_h" "$pane_w"
}

# ===============================================================
# _preview_file — main entry
# ===============================================================
_preview_file() {
    local path="$1"
    local file
    file=$(clean_path "$path" | sed 's|^\./||g')
    [[ -e "$file" || -L "$file" ]] || { echo "(inaccessible: $file)"; return; }

    local sizeline width
    read -r sizeline width < <(_preview_dims)

    # [FIX 6] Show symlink target first
    if [[ -L "$file" ]]; then
        local target
        target=$(readlink -f "$file" 2>/dev/null) || target=$(readlink "$file" 2>/dev/null)
        printf '\e[33m→ %s\e[m\n\n' "${target:-?}"
    fi

    if [[ -d "$file" ]]; then
        # [FIX 3] Show entry count + total size instead of useless `ls | head -2`
        local count size
        count=$(find "$file" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
        size=$(du -sh -- "$file" 2>/dev/null | cut -f1)
        printf '\e[36mDirectory: %s\e[m  (%s entries, %s)\n\n' \
            "${file##*/}" "$count" "${size:-?}"
        directory_view "$file" "$sizeline"
        return
    fi

    # [FIX 13] Special files: show type
    if [[ ! -f "$file" ]]; then
        stat --printf='%F\n' -- "$file" 2>/dev/null || echo "(special file)"
        return
    fi

    local file_ext="${file##*.}"; file_ext="${file_ext,,}"
    printf '\e[36mFile: %s\e[m\n\n' "${file##*/}"

    case "$file_ext" in
        png|jpg|jpeg|gif|webp|bmp|svg)
            if command -v chafa >/dev/null 2>&1; then
                # [FIX 12] Scale image to fit pane
                local img_h=$(( sizeline - 2 ))
                (( img_h < 5 )) && img_h=5
                chafa -s "${width}x${img_h}" -- "$file" 2>/dev/null && return
            fi
            ;;
        pdf)
            if command -v pdftotext >/dev/null 2>&1; then
                # [FIX 10] Fold to pane width before limiting lines
                pdftotext -l 1 -nopgbrk -q -- "$file" - 2>/dev/null \
                    | fold -s -w "$width" 2>/dev/null \
                    | head -n "$sizeline" && return
            fi
            ;;
        md|markdown)
            if command -v glow >/dev/null 2>&1; then
                # [FIX 9] glow respects pane width
                env COLORTERM=8bit glow -s dark -w "$width" -- "$file" 2>/dev/null \
                    | head -n "$sizeline" && return
            fi
            ;;
    esac

    # Fallback: type + content
    # [FIX 7] Single file(1) call for MIME
    local mime
    mime=$(file -b --mime -- "$file" 2>/dev/null)
    file -b -- "$file" 2>/dev/null
    printf '\n'

    # [FIX 8] Broader text detection
    if [[ "$mime" == text/* ]] \
        || [[ "$mime" == *json* ]] \
        || [[ "$mime" == *xml* ]] \
        || [[ "$mime" == *script* ]] \
        || [[ "$mime" == *javascript* ]]; then
        if command -v bat >/dev/null 2>&1; then
            # [FIX 9] bat respects pane width
            env COLORTERM=8bit bat --paging=never --color=always --style=plain \
                --terminal-width="$width" -- "$file" 2>/dev/null \
                | head -n "$sizeline"
        else
            # [FIX 2] Use `width` for folding long lines
            fold -s -w "$width" -- "$file" 2>/dev/null \
                | head -n "$sizeline"
        fi
    else
        # [FIX 5] `strings` may not exist (binutils). Fallback to od.
        if command -v strings >/dev/null 2>&1; then
            strings -n 10 -- "$file" 2>/dev/null \
                | fold -s -w "$width" 2>/dev/null \
                | head -n "$sizeline"
        elif command -v od >/dev/null 2>&1; then
            od -c -- "$file" 2>/dev/null | head -n "$sizeline"
        else
            local fsize
            fsize=$(stat -c %s -- "$file" 2>/dev/null || echo '?')
            printf '(binary, %s bytes)\n' "$fsize"
        fi
    fi
}

# ===============================================================
# directory_view — list a directory's contents
# ===============================================================
directory_view() {
    local dir="$1"
    local max_lines="${2:-0}"     # 0 = unlimited
    local long='' showhidden=''
    [[ -f "$CACHE_OMNISH_DIR/longfilemanager" ]] && long='-l'
    [[ -f "$CACHE_OMNISH_DIR/showhidden" ]] && showhidden='-a'

    local output
    if command -v eza >/dev/null 2>&1; then
        # [FIX 4] Don't pass -1 AND -l (conflict); respect $showhidden
        if [[ -n "$long" ]]; then
            output=$(eza -l $showhidden --classify --group-directories-first --color=always --icons -- "$dir" 2>/dev/null)
        else
            output=$(eza -1 $showhidden --classify --group-directories-first --color=always --icons -- "$dir" 2>/dev/null)
        fi
    else
        if [[ -n "$long" ]]; then
            output=$(ls -l $showhidden --classify --group-directories-first --color=always -- "$dir" 2>/dev/null)
        else
            output=$(ls -1 $showhidden --classify --group-directories-first --color=always -- "$dir" 2>/dev/null)
        fi
    fi

    # [FIX 4] Strip * @ | = (exec/symlink/fifo/socket) and trailing / consistently
    output=$(printf '%s\n' "$output" | sed 's/[*@|=]$//; s|/$||')

    if (( max_lines > 0 )); then
        printf '%s\n' "$output" | head -n "$max_lines"
    else
        printf '%s\n' "$output"
    fi
}

# ===============================================================
# xdg_open — launch the file with the system opener
# ===============================================================
xdg_open() {
    local path="$1"
    local file
    file=$(clean_path "$path" | sed 's|^\./||g')

    # [FIX 11] Validate path and opener
    [[ -e "$file" || -L "$file" ]] || { status_msg "not found: ${file##*/}"; return 1; }

    local opener="${OMNI_OPENER:-xdg-open}"
    if ! command -v "$opener" >/dev/null 2>&1; then
        status_msg "opener not found: $opener"
        return 1
    fi

    nohup "$opener" -- "$file" &>/dev/null &
    disown
    return 0
}