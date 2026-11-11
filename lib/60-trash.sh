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
    local dir target f
    local trashed=0 failed=0
    local total=$#

    mkdir -p "$OMNI_TRASH" 2>/dev/null
    # [FIX 2] mktemp -d guarantees uniqueness across same-second calls
    dir=$(mktemp -d "$OMNI_TRASH/$(date +%Y%m%d-%H%M%S)-XXXXXX" 2>/dev/null) \
        || { status_msg "cannot create trash dir"; return 1; }

    (( total > 3 )) && spinner_begin "trashing $total item(s)"

    for f in "$@"; do
        [[ -e "$f" || -L "$f" ]] || continue

        # [FIX 3] basename collision → unique suffix
        target="$dir/$(basename -- "$f")"
        if [[ -e "$target" || -L "$target" ]]; then
            target="$dir/$(basename -- "$f").$$.$RANDOM"
        fi

        if mv -- "$f" "$target" 2>/dev/null; then
            ((trashed++))
        elif cp -a -- "$f" "$target" 2>/dev/null && rm -rf -- "$f" 2>/dev/null; then
            ((trashed++))
        else
            ((failed++))
        fi
    done

    (( total > 3 )) && spinner_end

    # [FIX 1] Clean up empty batch dir + explicit return
    if (( trashed == 0 )); then
        rmdir -- "$dir" 2>/dev/null
        (( failed > 0 )) && { status_msg "trash failed"; return 1; }
        return 0
    fi

    # A partial move is not success: callers must keep the selection so the
    # failed items remain visible and retryable. Successfully moved items stay
    # in this batch and can still be restored with one undo operation.
    if (( failed > 0 )); then
        status_msg "trashed $trashed item(s); $failed failed"
        return 1
    fi
    return 0
}

# ===============================================================
# undo_trash — restore the most recent batch
# ===============================================================
undo_trash() {
    local latest
    latest=$(ls -1t "$OMNI_TRASH" 2>/dev/null | head -1)
    [[ -z "$latest" ]] && { status_msg "trash is empty"; return 1; }

    local batch_dir="$OMNI_TRASH/$latest"

    # [FIX 5] Empty batch (or batch removed) → clean silently
    if [[ ! -d "$batch_dir" ]] \
       || ! find "$batch_dir" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
        rmdir -- "$batch_dir" 2>/dev/null
        status_msg "batch '$latest' was empty, removed"
        return 0
    fi

    local total restored=0 skipped=0 failed=0 f base
    total=$(find "$batch_dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    (( total > 5 )) && spinner_begin "restoring $total item(s)"

    # [FIX 4] Per-file check + mv (mv -n skips silently, we want to know)
    while IFS= read -r -d '' f; do
        base=$(basename -- "$f")
        if [[ -e "./$base" || -L "./$base" ]]; then
            ((skipped++))
            continue
        fi
        if mv -- "$f" ./ 2>/dev/null; then
            ((restored++))
        else
            ((failed++))
        fi
    done < <(find "$batch_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

    (( total > 5 )) && spinner_end

    # Try to remove the now-empty batch dir
    rmdir -- "$batch_dir" 2>/dev/null

    # [FIX 6] Detailed report
    if (( failed == 0 && skipped == 0 )); then
        status_msg "restored $restored item(s) from '$latest'"
    elif (( failed == 0 )); then
        status_msg "restored $restored, skipped $skipped (exist)"
    else
        status_msg "restored $restored, skipped $skipped, failed $failed"
    fi
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
            ((i++))
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
    local f batch base batch_dir
    # [FIX 8] {1} inside the quotes so spaces in filenames work
    f=$(find "$OMNI_TRASH" -mindepth 2 -maxdepth 2 2>/dev/null \
        | sed "s|$OMNI_TRASH/||" | head -200 \
        | fzf --header "Trash: $OMNI_TRASH | Enter: restore | Esc: quit" \
              --preview "ls -la -- \"$OMNI_TRASH/{1}\" 2>/dev/null" \
              --preview-window 'right:50%:wrap')
    [[ -z "$f" ]] && return
    batch="${f%%/*}"; base="${f#*/}"
    batch_dir="$OMNI_TRASH/$batch"

    # [FIX 9] Existence check
    if [[ ! -e "$batch_dir/$base" && ! -L "$batch_dir/$base" ]]; then
        status_msg "not found: $batch/$base"
        return 1
    fi

    if [[ -e "./$base" || -L "./$base" ]]; then
        cmd_yes_no "'$base' exists in cwd. Overwrite?"
        if [[ $cmd_reply == yes ]]; then
            rm -rf -- "./$base"
        else
            status_msg "cancelled"
            return 1
        fi
    fi

    spinner_begin "restoring $base"
    if mv -- "$batch_dir/$base" ./ 2>/dev/null; then
        spinner_end
        status_msg "restored: $base"
        rmdir -- "$batch_dir" 2>/dev/null
    else
        spinner_end
        status_msg "restore failed"
    fi
}