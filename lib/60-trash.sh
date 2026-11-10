# omnish — trash system (P1: reversible delete)
# Trash batches preserve original absolute paths in NUL-delimited metadata.
# Legacy batches without metadata remain restorable to the current directory.

# ===============================================================
# Trash metadata helpers
# ===============================================================
_trash_metadata_dir() {
    printf '%s/.omnish-meta' "$1"
}

_trash_batch_has_metadata() {
    local batch_dir="$1"
    local marker="$batch_dir/.omnish-meta/.format"
    local format batch_id
    [[ -f "$marker" ]] || return 1
    IFS= read -r format < "$marker" || return 1
    batch_id="${batch_dir##*/}"
    [[ "$format" == "OMNISH_TRASH_META_V1:$batch_id" ]]
}

_trash_get_original_path() {
    local batch_dir="$1"
    local stored_name="$2"
    local meta_dir="$batch_dir/.omnish-meta"
    local meta_file fd record_name original

    TRASH_ORIGINAL_PATH=""
    _trash_batch_has_metadata "$batch_dir" || return 1
    for meta_file in "$meta_dir"/item.*; do
        [[ -f "$meta_file" ]] || continue
        if ! exec {fd}<"$meta_file"; then continue; fi
        if ! IFS= read -r -d '' record_name <&"$fd"; then
            exec {fd}<&-; continue
        fi
        if ! IFS= read -r -d '' original <&"$fd"; then
            exec {fd}<&-; continue
        fi
        exec {fd}<&-
        if [[ "$record_name" == "$stored_name" ]]; then
            TRASH_ORIGINAL_PATH="$original"
            return 0
        fi
    done
    return 1
}

_trash_remove_metadata_entry() {
    local batch_dir="$1" stored_name="$2"
    local meta_dir="$batch_dir/.omnish-meta"
    local meta_file fd record_name original

    _trash_batch_has_metadata "$batch_dir" || return 0
    for meta_file in "$meta_dir"/item.*; do
        [[ -f "$meta_file" ]] || continue
        if ! exec {fd}<"$meta_file"; then continue; fi
        if ! IFS= read -r -d '' record_name <&"$fd"; then
            exec {fd}<&-; continue
        fi
        if ! IFS= read -r -d '' original <&"$fd"; then
            exec {fd}<&-; continue
        fi
        exec {fd}<&-
        if [[ "$record_name" == "$stored_name" ]]; then
            rm -f -- "$meta_file"
            return $?
        fi
    done
    return 1
}

_trash_batch_has_payload() {
    local batch_dir="$1" item has_metadata=0
    _trash_batch_has_metadata "$batch_dir" && has_metadata=1
    while IFS= read -r -d '' item; do
        if (( has_metadata )) && [[ "${item##*/}" == ".omnish-meta" ]]; then
            continue
        fi
        return 0
    done < <(find "$batch_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    return 1
}

_trash_cleanup_batch() {
    local batch_dir="$1"
    _trash_batch_has_payload "$batch_dir" && return 1
    if _trash_batch_has_metadata "$batch_dir"; then
        rm -rf -- "$batch_dir/.omnish-meta" 2>/dev/null || return 1
    fi
    rmdir -- "$batch_dir" 2>/dev/null
}

# ===============================================================
# trash — move files to a new timestamped batch dir
# ===============================================================
trash() {
    local dir meta_dir marker f source original stored target target_name
    local meta_file suffix trashed=0 failed=0
    local total=$#

    mkdir -p -- "$OMNI_TRASH" 2>/dev/null || {
        status_msg "cannot create trash directory"
        return 1
    }
    dir=$(mktemp -d "$OMNI_TRASH/$(date +%Y%m%d-%H%M%S)-XXXXXX" 2>/dev/null) || {
        status_msg "cannot create trash batch"
        return 1
    }

    # Create and identify our metadata area before moving any user data.
    meta_dir="$dir/.omnish-meta"
    marker="$meta_dir/.format"
    if ! mkdir -m 700 -- "$meta_dir" 2>/dev/null; then
        rmdir -- "$dir" 2>/dev/null
        status_msg "cannot initialise trash metadata"
        return 1
    fi
    printf 'OMNISH_TRASH_META_V1:%s\n' "${dir##*/}" > "$marker" || {
        rm -rf -- "$meta_dir"
        rmdir -- "$dir" 2>/dev/null
        status_msg "cannot initialise trash metadata"
        return 1
    }

    if (( total > 3 )); then spinner_begin "trashing $total item(s)"; fi

    for f in "$@"; do
        [[ -e "$f" || -L "$f" ]] || continue
        source="$f"
        while [[ "$source" != "/" && "$source" == */ ]]; do
            source="${source%/}"
        done
        [[ -n "$source" ]] || source="/"

        if [[ "$source" == /* ]]; then
            original="$source"
        else
            original="$PWD/$source"
        fi

        stored="${source##*/}"
        [[ -n "$stored" ]] || { failed=$((failed + 1)); continue; }

        # Keep every payload name unique, including repeated basenames.
        target="$dir/$stored"
        suffix=0
        while [[ -e "$target" || -L "$target" ]]; do
            suffix=$((suffix + 1))
            target="$dir/$stored.$$.$RANDOM.$suffix"
        done
        target_name="${target##*/}"

        # Prepare the sidecar before moving the item. Interrupted operations
        # leave harmless metadata whose payload is absent and therefore skipped.
        meta_file=$(mktemp "$meta_dir/item.XXXXXX" 2>/dev/null) || {
            failed=$((failed + 1)); continue
        }
        if ! printf '%s\0%s\0' "$target_name" "$original" > "$meta_file"; then
            rm -f -- "$meta_file"
            failed=$((failed + 1))
            continue
        fi

        if mv -- "$source" "$target" 2>/dev/null; then
            trashed=$((trashed + 1))
        elif cp -a -- "$source" "$target" 2>/dev/null; then
            if rm -rf -- "$source" 2>/dev/null; then
                trashed=$((trashed + 1))
            else
                rm -rf -- "$target" 2>/dev/null
                rm -f -- "$meta_file"
                failed=$((failed + 1))
            fi
        else
            rm -f -- "$meta_file"
            failed=$((failed + 1))
        fi
    done

    if (( total > 3 )); then spinner_end; fi
    if (( trashed == 0 )); then _trash_cleanup_batch "$dir" 2>/dev/null || true; fi

    if (( failed > 0 )); then
        status_msg "trashed $trashed item(s), failed $failed"
        return 1
    fi
    (( trashed > 0 )) && status_msg "trashed $trashed item(s)"
    return 0
}

# ===============================================================
# undo_trash — restore the most recent batch
# ===============================================================
undo_trash() {
    local latest
    latest=$(ls -1t "$OMNI_TRASH" 2>/dev/null | head -1)
    [[ -n "$latest" ]] || { status_msg "trash is empty"; return 1; }

    local batch_dir="$OMNI_TRASH/$latest"
    [[ -d "$batch_dir" ]] || { status_msg "trash batch not found"; return 1; }
    if ! _trash_batch_has_payload "$batch_dir"; then
        _trash_cleanup_batch "$batch_dir" 2>/dev/null || true
        status_msg "trash batch was empty"
        return 0
    fi

    local total=0 restored=0 skipped=0 failed=0 missing=0
    local f base destination parent has_metadata=0
    _trash_batch_has_metadata "$batch_dir" && has_metadata=1

    while IFS= read -r -d '' f; do
        if (( has_metadata )) && [[ "${f##*/}" == ".omnish-meta" ]]; then continue; fi
        total=$((total + 1))
    done < <(find "$batch_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    if (( total > 5 )); then spinner_begin "restoring $total item(s)"; fi

    while IFS= read -r -d '' f; do
        if (( has_metadata )) && [[ "${f##*/}" == ".omnish-meta" ]]; then continue; fi
        base="${f##*/}"

        if (( has_metadata )); then
            if ! _trash_get_original_path "$batch_dir" "$base"; then
                failed=$((failed + 1)); continue
            fi
            destination="$TRASH_ORIGINAL_PATH"
            [[ "$destination" == /* ]] || { failed=$((failed + 1)); continue; }
            parent="${destination%/*}"
            [[ -n "$parent" ]] || parent="/"
            if [[ ! -d "$parent" ]]; then
                missing=$((missing + 1)); continue
            fi
        else
            # Compatibility for batches created before path metadata existed.
            destination="./$base"
        fi

        if [[ -e "$destination" || -L "$destination" ]]; then
            skipped=$((skipped + 1)); continue
        fi

        # -n prevents a late destination race from overwriting user data.
        # mv -n can return success when skipping, so check whether source remains.
        if mv -T -n -- "$f" "$destination" 2>/dev/null \
           && [[ ! -e "$f" && ! -L "$f" ]]; then
            restored=$((restored + 1))
            if (( has_metadata )); then
                _trash_remove_metadata_entry "$batch_dir" "$base" 2>/dev/null || true
            fi
        else
            failed=$((failed + 1))
        fi
    done < <(find "$batch_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

    if (( total > 5 )); then spinner_end; fi
    _trash_cleanup_batch "$batch_dir" 2>/dev/null || true

    if (( missing > 0 )); then
        status_msg "restored $restored; kept $missing (original directory missing); skipped $skipped; failed $failed"
        return 1
    elif (( failed > 0 )); then
        status_msg "restored $restored; skipped $skipped; failed $failed"
        return 1
    elif (( skipped > 0 )); then
        status_msg "restored $restored; skipped $skipped (destination exists)"
    else
        status_msg "restored $restored item(s) to their original locations"
    fi
}

# ===============================================================
# empty_trash — permanently delete everything in the trash
# ===============================================================
empty_trash() {
    local count total
    count=$(find "$OMNI_TRASH" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    if (( count == 0 )); then status_msg "trash is empty"; return 0; fi

    cmd_yes_no "Empty trash ($count batches)?"
    [[ $cmd_reply == yes ]] || { status_msg "cancelled"; return 0; }
    total=$(find "$OMNI_TRASH" -type f 2>/dev/null | wc -l)

    if (( total > 100 )); then
        progress_begin "$total" "emptying trash"
        local f i=0
        while IFS= read -r -d '' f; do
            rm -f -- "$f" 2>/dev/null || true
            i=$((i + 1))
            progress_set "$i"
        done < <(find "$OMNI_TRASH" -type f -print0 2>/dev/null)
        progress_set "$total"
        progress_end
        find "$OMNI_TRASH" -mindepth 1 -type d -empty -delete 2>/dev/null
    elif (( total > 0 )); then
        spinner_begin "emptying trash"
        find "$OMNI_TRASH" -mindepth 1 -delete 2>/dev/null
        spinner_end
    else
        find "$OMNI_TRASH" -mindepth 1 -type d -empty -delete 2>/dev/null
    fi

    if find "$OMNI_TRASH" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
        status_msg "trash could not be completely emptied"
        return 1
    fi
    status_msg "trash emptied"
}

# ===============================================================
# trash_view — browse trash, restore individual items
# ===============================================================
trash_view() {
    local f relative batch base batch_dir destination parent overwrite=0 rc
    local selection_file

    # Use NUL records end-to-end: valid filenames may contain spaces, quotes,
    # tabs, or newlines. Command substitution cannot safely carry NUL bytes.
    selection_file=$(mktemp "${TMPDIR:-/tmp}/omnish-trash.XXXXXX") || {
        status_msg "cannot create temporary selection file"
        return 1
    }

    if ! {
        while IFS= read -r -d '' batch_dir; do
            if _trash_batch_has_metadata "$batch_dir"; then
                find "$batch_dir" -mindepth 1 -maxdepth 1 \
                    ! -path "$batch_dir/.omnish-meta" -print0 2>/dev/null
            else
                find "$batch_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null
            fi
        done < <(find "$OMNI_TRASH" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    } | head -z -n 200 \
      | fzf --read0 --print0 \
            --header "Trash: $OMNI_TRASH | Enter: restore | Esc: quit" \
            --preview 'ls -la -- {} 2>/dev/null' \
            --preview-window 'right:50%:wrap' > "$selection_file"; then
        rm -f -- "$selection_file"
        return 0
    fi

    if ! IFS= read -r -d '' f < "$selection_file"; then
        rm -f -- "$selection_file"
        return 0
    fi
    rm -f -- "$selection_file"

    relative="${f#"$OMNI_TRASH"/}"
    batch="${relative%%/*}"
    base="${relative#*/}"
    batch_dir="$OMNI_TRASH/$batch"

    if [[ ! -e "$batch_dir/$base" && ! -L "$batch_dir/$base" ]]; then
        status_msg "not found: $relative"
        return 1
    fi

    if _trash_batch_has_metadata "$batch_dir"; then
        if ! _trash_get_original_path "$batch_dir" "$base"; then
            status_msg "cannot read original path; item kept in trash"
            return 1
        fi
        destination="$TRASH_ORIGINAL_PATH"
        [[ "$destination" == /* ]] || {
            status_msg "invalid original path; item kept in trash"
            return 1
        }
    else
        # Compatibility for batches created before origin metadata existed.
        destination="./$base"
    fi

    parent="${destination%/*}"
    [[ -n "$parent" ]] || parent="/"
    if [[ ! -d "$parent" ]]; then
        status_msg "original directory is missing; item kept in trash"
        return 1
    fi

    if [[ -e "$destination" || -L "$destination" ]]; then
        cmd_yes_no "'$base' already exists at the restore location. Overwrite?"
        [[ $cmd_reply == yes ]] || { status_msg "cancelled"; return 1; }
        overwrite=1
    fi

    spinner_begin "restoring $base"
    if (( overwrite )); then
        if mv -T -f -- "$batch_dir/$base" "$destination" 2>/dev/null; then
            rc=0
        else
            rc=$?
        fi
    else
        if mv -T -n -- "$batch_dir/$base" "$destination" 2>/dev/null; then
            if [[ -e "$batch_dir/$base" || -L "$batch_dir/$base" ]]; then
                rc=1
            else
                rc=0
            fi
        else
            rc=$?
        fi
    fi
    spinner_end

    if (( rc == 0 )); then
        if _trash_batch_has_metadata "$batch_dir"; then
            _trash_remove_metadata_entry "$batch_dir" "$base" 2>/dev/null || true
        fi
        status_msg "restored: $base"
        _trash_cleanup_batch "$batch_dir" 2>/dev/null || true
    else
        status_msg "restore failed; item kept in trash"
        return 1
    fi
}
