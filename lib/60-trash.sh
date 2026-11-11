# omnish — trash system (P1: reversible delete)
# Progress feedback via 25-progress.sh on bulk operations.
#
# [FIX 1] trash() always returns 0 on success. Before: it returned 1 whenever
#         total <= 3 (from `(( total > 3 )) && spinner_end` short-circuit),
#         so every caller doing `trash "$f" && ...` treated success as failure.
# [FIX 2] Batch dir created with mktemp -d. Before: two trash calls in the
#         same second shared the same dir, overwriting files silently.
# [FIX 3] Basename collision within a batch: file.txt appears twice → the
#         second write overwrote the first (data loss). Now appends .PID.RANDOM.
# [FIX 4] undo_trash: `mv -n` returns 0 when skipping an existing file, so
#         "restored" was reported even when the file was left in trash.
#         Replaced with per-file existence check + mv.
# [FIX 5] undo_trash: empty batch caused `mv -n -- "$dir/"*` → mv error on
#         literal `*` → "restore failed (name conflict?)" misleading message.
#         Empty batch is now detected and cleaned silently.
# [FIX 6] undo_trash: reports restored/skipped/failed counts instead of a
#         generic message.
# [FIX 7] empty_trash small case: `rm -rf "$OMNI_TRASH"/*` was nullglob-unsafe.
#         Replaced with `find -mindepth 1 -delete` (recursive, safe).
# [FIX 8] trash_view: preview placeholder {1} was outside the quotes, so
#         filenames with spaces broke `ls -la`. Now quoted correctly.
# [FIX 9] trash_view: existence check + overwrite prompt before mv (was: mv
#         silently failed, generic "restore failed" message).
# [FIX 10] trash(): reports actual trashed count (was: $# regardless of
#          existence checks inside the loop).

# ===============================================================
# trash — move files to a new timestamped batch dir
# ===============================================================
trash() {
    local dir target f stored original manifest
    local trashed=0 failed=0 total=$#
    mkdir -p -- "$OMNI_TRASH" 2>/dev/null || {
        status_msg "cannot create trash directory"
        return 1
    }

    dir=$(mktemp -d "$OMNI_TRASH/$(date +%Y%m%d-%H%M%S)-XXXXXX" 2>/dev/null) \
        || { status_msg "cannot create trash dir"; return 1; }
    manifest="$dir/.omnish-manifest"
    : > "$manifest" || { rmdir -- "$dir" 2>/dev/null; status_msg "cannot create trash manifest"; return 1; }
    chmod 600 -- "$manifest" 2>/dev/null || {
        rm -f -- "$manifest"; rmdir -- "$dir" 2>/dev/null
        status_msg "cannot secure trash manifest"
        return 1
    }

    (( total > 3 )) && spinner_begin "trashing $total item(s)"

    for f in "$@"; do
        [[ -e "$f" || -L "$f" ]] || continue

        # Preserve the lexical source path (including a symlink itself).
        if [[ "$f" == /* ]]; then original="$f"; else original="$PWD/$f"; fi

        stored="$(basename -- "$f")"
        target="$dir/$stored"
        if [[ -e "$target" || -L "$target" ]]; then
            stored="$stored.$$.$RANDOM"
            target="$dir/$stored"
            while [[ -e "$target" || -L "$target" ]]; do
                stored="$(basename -- "$f").$$.$RANDOM"
                target="$dir/$stored"
            done
        fi

        # Record the source before moving it. A stale record is harmless if
        # the move fails; a moved file without a record would be harder to find.
        if ! printf '%s\0%s\0' "$stored" "$original" >> "$manifest"; then
            ((++failed))
            continue
        fi

        if mv -- "$f" "$target" 2>/dev/null; then
            ((++trashed))
        elif cp -a -- "$f" "$target" 2>/dev/null && rm -rf -- "$f" 2>/dev/null; then
            ((++trashed))
        else
            ((++failed))
        fi
    done

    (( total > 3 )) && spinner_end

    if (( trashed == 0 )); then
        rm -f -- "$manifest"
        rmdir -- "$dir" 2>/dev/null
        (( failed > 0 )) && { status_msg "trash failed"; return 1; }
        return 0
    fi

    if (( failed > 0 )); then
        status_msg "trashed $trashed item(s); $failed failed"
        return 1
    fi
    return 0
}

# ===============================================================
# undo_trash — restore the most recent batch to its original paths
# ===============================================================
undo_trash() {
    local latest
    latest=$(ls -1t "$OMNI_TRASH" 2>/dev/null | head -1)
    [[ -z "$latest" ]] && { status_msg "trash is empty"; return 1; }

    local batch_dir="$OMNI_TRASH/$latest"
    [[ -d "$batch_dir" ]] || { status_msg "trash batch not found"; return 1; }

    local manifest="$batch_dir/.omnish-manifest"
    local stored original source_path
    local total=0 restored=0 skipped=0 failed=0 f base destination_dir
    while IFS= read -r -d '' f; do
        [[ "$f" == "$manifest" ]] && continue
        ((++total))
    done < <(find "$batch_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

    if (( total == 0 )); then
        rm -f -- "$manifest"
        rmdir -- "$batch_dir" 2>/dev/null
        status_msg "trash is empty"
        return 0
    fi
    (( total > 5 )) && spinner_begin "restoring $total item(s)"

    while IFS= read -r -d '' f; do
        [[ "$f" == "$manifest" ]] && continue
        base=$(basename -- "$f")
        original="$PWD/$base"
        # Linear lookup avoids treating an arbitrary filename as an array
        # subscript (names may contain shell metacharacters).
        if [[ -r "$manifest" ]]; then
            while IFS= read -r -d '' stored && IFS= read -r -d '' source_path; do
                if [[ "$stored" == "$base" ]]; then
                    original="$source_path"
                    break
                fi
            done < "$manifest"
        fi
        destination_dir="${original%/*}"
        [[ -n "$destination_dir" ]] || destination_dir="/"

        # Legacy batches have no manifest and restore to the current directory.
        if [[ ! -d "$destination_dir" ]]; then
            ((++skipped))
            continue
        fi
        if [[ -e "$original" || -L "$original" ]]; then
            ((++skipped))
            continue
        fi
        if mv -- "$f" "$original" 2>/dev/null; then
            ((++restored))
        else
            ((++failed))
        fi
    done < <(find "$batch_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

    (( total > 5 )) && spinner_end

    # Keep the manifest and any conflicted files so a later retry remains safe.
    if ! find "$batch_dir" -mindepth 1 ! -name '.omnish-manifest' -print -quit 2>/dev/null | grep -q .; then
        rm -f -- "$manifest"
        rmdir -- "$batch_dir" 2>/dev/null
    fi

    if (( failed == 0 && skipped == 0 )); then
        status_msg "restored $restored item(s) from '$latest'"
    elif (( failed == 0 )); then
        status_msg "restored $restored, skipped $skipped (destination unavailable or exists)"
    else
        status_msg "restored $restored, skipped $skipped, failed $failed"
    fi
    (( failed == 0 && skipped == 0 ))
}

# ===============================================================
# empty_trash — permanently delete everything in the trash
# ===============================================================
empty_trash() {
    local count total
    count=$(find "$OMNI_TRASH" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    if (( count == 0 )); then
        status_msg "trash is empty"; return 0
    fi

    cmd_yes_no "Empty trash ($count batches)?"
    [[ $cmd_reply == yes ]] || { status_msg "cancelled"; return 0; }

    total=$(find "$OMNI_TRASH" -type f 2>/dev/null | wc -l)

    if (( total > 100 )); then
        # Progress bar: count files, not just batches
        progress_begin "$total" "emptying trash"
        local f i=0
        # Process substitution (not pipe) so progress_set updates the parent shell
        while IFS= read -r -d '' f; do
            rm -f -- "$f" 2>/dev/null
            ((++i))
            progress_set "$i"
        done < <(find "$OMNI_TRASH" -type f -print0 2>/dev/null)
        progress_set "$total"
        progress_end
        find "$OMNI_TRASH" -mindepth 1 -type d -empty -delete 2>/dev/null
    elif (( total > 0 )); then
        spinner_begin "emptying trash"
        # [FIX 7] find -delete is nullglob-safe and recursive (implicit -depth)
        find "$OMNI_TRASH" -mindepth 1 -delete 2>/dev/null
        spinner_end
    else
        find "$OMNI_TRASH" -mindepth 1 -type d -empty -delete 2>/dev/null
    fi

    status_msg "trash emptied"
}

# ===============================================================
# trash_view — browse trash, restore individual items
# ===============================================================
trash_view() {
    local f batch base batch_dir manifest original destination_dir
    f=$(find "$OMNI_TRASH" -mindepth 2 -maxdepth 2 ! -name '.omnish-manifest' 2>/dev/null \
        | sed "s|$OMNI_TRASH/||" | head -200 \
        | fzf --header "Trash: $OMNI_TRASH | Enter: restore | Esc: quit" \
              --preview 'ls -la -- "$OMNI_TRASH/{}" 2>/dev/null' \
              --preview-window 'right:50%:wrap')
    [[ -z "$f" ]] && return

    batch="${f%%/*}"
    base="${f#*/}"
    batch_dir="$OMNI_TRASH/$batch"
    manifest="$batch_dir/.omnish-manifest"
    original="$PWD/$base"

    if [[ -r "$manifest" ]]; then
        local stored source
        while IFS= read -r -d '' stored && IFS= read -r -d '' source; do
            if [[ "$stored" == "$base" ]]; then
                original="$source"
                break
            fi
        done < "$manifest"
    fi

    [[ -e "$batch_dir/$base" || -L "$batch_dir/$base" ]] || {
        status_msg "not found: $batch/$base"
        return 1
    }

    destination_dir="${original%/*}"
    [[ -n "$destination_dir" ]] || destination_dir="/"
    if [[ ! -d "$destination_dir" ]]; then
        status_msg "original directory no longer exists: $destination_dir"
        return 1
    fi
    if [[ -e "$original" || -L "$original" ]]; then
        status_msg "restore conflict: $original already exists"
        return 1
    fi

    spinner_begin "restoring $base"
    if mv -- "$batch_dir/$base" "$original" 2>/dev/null; then
        spinner_end
        status_msg "restored: $original"
        if ! find "$batch_dir" -mindepth 1 ! -name '.omnish-manifest' -print -quit 2>/dev/null | grep -q .; then
            rm -f -- "$manifest"
            rmdir -- "$batch_dir" 2>/dev/null
        fi
    else
        spinner_end
        status_msg "restore failed"
        return 1
    fi
}