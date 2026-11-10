# omnish — file operations
# Each op uses cmd_line / cmd_yes_no (P0) instead of whiptail.
# Progress feedback via 25-progress.sh: progress_begin/tick/end or spinner_begin/end.
#
# [FIX 1] rsync progress pipe: stderr was sent to /dev/null and `\r` never
#         matched `read -r`, so the bar stayed at 0%. Fixed with 2>&1,
#         tr '\r' '\n', and PIPESTATUS for the exit code.
# [FIX 2] copy_file single: rsync/cp failure now detected (was: reported
#         "copied" regardless of rc).
# [FIX 3] move_file single: mv failure now detected.
# [FIX 4] _copy_marked / _move_marked: total count captured before
#         generate_mark_file() clears the array (was: "copied 0 item(s)").
# [FIX 5] _delete_marked: marks are only cleared on full success, so a
#         partial failure can be retried without losing the selection.
# [FIX 6] delete_file: removed dead *"..."* pattern (safe_ls no longer
#         emits "..."; the header is "  $PWD" and never matches the glob
#         anyway, so it was dead code hiding a real condition).
# [FIX 7] copy_file: suggested name now handles dotfiles (.gitignore →
#         .gitignore_copy) instead of producing _copy.gitignore.
# [FIX 8] _reload_marks at the start of each marked-aware op
#         (defence-in-depth; the entry-point already loads it, but this
#         guarantees correctness if a function is called directly).
# [FIX 9] create_symlink: passes -- to realpath (paths starting with -).

# ===============================================================
# Marks reload (defence-in-depth, mirrors the entry-point fix)
# ===============================================================
_reload_marks() {
    marked_files=()
    [[ -f "${MARKED_FILES_FILE:-}" ]] && \
        mapfile -t marked_files < "$MARKED_FILES_FILE" 2>/dev/null
    ((${#marked_files[@]})) && [[ -z "${marked_files[0]}" ]] && marked_files=()
}

# ===============================================================
delete() {
    # [P1] Internal cache always rm; user files go to trash
    local file="$1"
    [[ -e "$file" || -L "$file" ]] || return 1
    case "$file" in
        "$MARKED_FILES_FILE"|"$CACHE_OMNISH_DIR"/*|"$TMP_OMNISH_DIR"/*)
            rm -f -- "$file" 2>/dev/null; return $? ;;
    esac
    if [[ ${OMNI_USE_TRASH:-1} == 1 ]]; then
        trash "$file" && return 0
        return 1
    fi
    local parent
    parent=$(dirname -- "$file")
    [[ -w "$parent" && -x "$parent" ]] && rm -rf -- "$file" 2>/dev/null && return 0
    return 1
}

delete_file() {
    _reload_marks
    local path="$1"
    local file
    file=$(clean_path "$path" | sed 's|^\./||g')

    _delete_marked() {
        (( ${#marked_files[@]} == 0 )) && { status_msg "no files marked"; return; }
        cmd_yes_no "Trash ${#marked_files[@]} item(s)?"
        [[ $cmd_reply == yes ]] || { status_msg "cancelled"; return; }
        local failed=0 f total
        total=${#marked_files[@]}
        (( total > 3 )) && spinner_begin "trashing $total item(s)"
        for f in "${marked_files[@]}"; do
            delete "$f" 2>/dev/null || ((failed++))
        done
        (( total > 3 )) && spinner_end
        # [FIX 5] only clear marks on full success
        if (( failed == 0 )); then
            generate_mark_file
            status_msg "trashed $total item(s)"
        else
            status_msg "$failed of $total failed (marks kept)"
        fi
    }

    # [FIX 6] dead *"..."* pattern removed
    if [[ ! -e "$file" && ! -L "$file" ]]; then
        (( ${#marked_files[@]} > 0 )) && _delete_marked
        return
    fi

    if (( ${#marked_files[@]} > 0 )); then
        _delete_marked
    else
        cmd_yes_no "Trash '${file##*/}'?"
        if [[ $cmd_reply == yes ]]; then
            if delete "$file" 2>/dev/null; then
                status_msg "trashed"
            else
                status_msg "failed"
            fi
        fi
    fi
}

create_directory() {
    cmd_line "mkdir: " dirs
    local name
    name=$(clean_path "$cmd_reply" | sed 's|^\./||g')
    [[ -z "$name" ]] && return 1
    if [[ -e "$PWD/$name" ]]; then
        messages "Error" "'${name##*/}' exists"; return 1
    fi
    if mkdir -p -- "$name" 2>/dev/null; then
        status_msg "created: $name"
    else
        messages "Warn" "mkdir failed"
    fi
}

create_file() {
    cmd_line "touch: "
    local name
    name=$(clean_path "$cmd_reply" | sed 's|^\./||g')
    [[ -z "$name" ]] && return 1
    if [[ -e "$PWD/$name" ]]; then
        messages "Error" "'${name##*/}' exists"; return 1
    fi
    if touch -- "$name" 2>/dev/null; then
        status_msg "created: $name"
    else
        messages "Warn" "touch failed"
    fi
}

copy_file() {
    _reload_marks
    local path="$1"
    local file
    file=$(clean_path "$path" | sed 's|^\./||g')

    _copy_marked() {
        (( ${#marked_files[@]} == 0 )) && { status_msg "no files marked"; return; }
        [[ -w "$PWD" ]] || { status_msg "no write access"; return; }

        local existing=() f base
        local -A seen=()
        for f in "${marked_files[@]}"; do
            base=${f##*/}
            if [[ ${seen[$base]+present} ]]; then
                status_msg "duplicate destination name: $base"
                return 1
            fi
            seen[$base]=1
            [[ -e "$PWD/$base" || -L "$PWD/$base" ]] && existing+=("$base")
        done

        if (( ${#existing[@]} > 0 )); then
            cmd_yes_no "Overwrite ${#existing[@]} existing file(s)?"
            [[ $cmd_reply == yes ]] || { status_msg "cancelled"; return; }
        fi

        # [FIX 4] capture count before generate_mark_file clears the array
        local total=${#marked_files[@]}
        spinner_begin "copying $total item(s)"
        if cp -rf -- "${marked_files[@]}" "$PWD" 2>/dev/null; then
            spinner_end
            generate_mark_file
            status_msg "copied $total item(s)"
        else
            spinner_end
            status_msg "copy failed (marks kept)"
        fi
    }

    if (( ${#marked_files[@]} > 0 )); then
        _copy_marked
        return
    fi

    [[ -e "$file" || -L "$file" ]] || { status_msg "nothing selected"; return; }
    local base="${file##*/}"
    # [FIX 7] dotfile-friendly suggested name
    local suggested
    if [[ "$base" == *.* && "$base" != .* && "${base%.*}" != "" ]]; then
        suggested="${base%.*}_copy.${base##*.}"      # foo.txt → foo_copy.txt
    else
        suggested="${base}_copy"                       # foo, .gitignore → …_copy
    fi

    cmd_line "copy '${base}' as: "
    local name="$cmd_reply"
    [[ -z "$name" ]] && return

    if [[ -e "$PWD/$name" ]]; then
        cmd_yes_no "Overwrite '$name'?"
        [[ $cmd_reply == yes ]] || return
    fi

    # [FIX 1+2] Single-file copy with proper progress pipe & error detection
    if command -v rsync >/dev/null 2>&1; then
        progress_begin 100 "copy $(basename "$file")"
        rsync -a --info=progress2 --no-inc-recursive --out-format='' \
            -- "$file" "$PWD/$name" 2>&1 \
            | tr '\r' '\n' \
            | grep --line-buffered -oE '[0-9]+%' \
            | while IFS= read -r pct; do
                progress_set "${pct%\%}"
              done
        local rc="${PIPESTATUS[0]}"
        progress_set 100
        progress_end
        if (( rc == 0 )); then
            status_msg "copied to $name"
        else
            status_msg "copy failed (rc=$rc)"
        fi
    else
        spinner_begin "copy $(basename "$file")"
        if cp -rf -- "$file" "$PWD/$name" 2>/dev/null; then
            spinner_end
            status_msg "copied to $name"
        else
            spinner_end
            status_msg "copy failed"
        fi
    fi
}

move_file() {
    _reload_marks
    local path="$1"
    local file
    file=$(clean_path "$path" | sed 's|^\./||g')

    _move_marked() {
        (( ${#marked_files[@]} == 0 )) && { status_msg "no files marked"; return; }
        [[ -w "$PWD" ]] || { status_msg "no write access"; return; }

        local existing=() f base
        local -A seen=()
        for f in "${marked_files[@]}"; do
            base=${f##*/}
            if [[ ${seen[$base]+present} ]]; then
                status_msg "duplicate destination name: $base"
                return 1
            fi
            seen[$base]=1
            [[ -e "$PWD/$base" || -L "$PWD/$base" ]] && existing+=("$base")
        done

        if (( ${#existing[@]} > 0 )); then
            cmd_yes_no "Overwrite ${#existing[@]} existing?"
            [[ $cmd_reply == yes ]] || { status_msg "cancelled"; return; }
        fi

        # [FIX 4] capture count before generate_mark_file clears the array
        local total=${#marked_files[@]}
        spinner_begin "moving $total item(s)"
        if mv -f -- "${marked_files[@]}" "$PWD" 2>/dev/null; then
            spinner_end
            generate_mark_file
            status_msg "moved $total item(s)"
        else
            spinner_end
            status_msg "move failed (marks kept)"
        fi
    }

    if (( ${#marked_files[@]} > 0 )); then
        _move_marked
        return
    fi

    [[ -e "$file" || -L "$file" ]] || { status_msg "nothing selected"; return; }
    local base="${file##*/}"
    cmd_line "move '${base}' to: "
    local name="$cmd_reply"
    [[ -z "$name" || "$name" == "$base" ]] && return

    if [[ -e "$PWD/$name" ]]; then
        cmd_yes_no "Overwrite '$name'?"
        [[ $cmd_reply == yes ]] || return
    fi

    # [FIX 3] error detection
    spinner_begin "moving $(basename "$file")"
    if [[ -e "$PWD/$name" ]]; then
        mv -f -- "$file" "$PWD/$name" 2>/dev/null
    else
        mv -- "$file" "$PWD/$name" 2>/dev/null
    fi
    local rc=$?
    spinner_end
    if (( rc == 0 )); then
        status_msg "moved to $name"
    else
        status_msg "move failed (rc=$rc)"
    fi
}

create_symlink() {
    local path="$1"
    local file
    file=$(clean_path "$path" | sed 's|^\./||g')
    [[ -e "$file" || -L "$file" ]] || { status_msg "nothing selected"; return; }

    local base="${file##*/}"
    cmd_line "symlink '${base}' as: "
    local name="$cmd_reply"
    [[ -z "$name" ]] && return

    if [[ -e "$PWD/$name" ]]; then
        cmd_yes_no "Overwrite '$name'?"
        [[ $cmd_reply == yes ]] || return
        rm -rf -- "$PWD/$name"
    fi
    # [FIX 9] -- on realpath (paths starting with -)
    local target
    target=$(realpath -- "$file" 2>/dev/null) || target="$PWD/$file"
    if ln -s -- "$target" "$PWD/$name" 2>/dev/null; then
        status_msg "linked: $name"
    else
        status_msg "symlink failed"
    fi
}