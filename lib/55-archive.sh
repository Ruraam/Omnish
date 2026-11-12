# omnish — Quick Archive
# Smart compression and read-only virtual archive browsing.

archive_is_supported() {
    case "${1##*/}" in
        *.tar|*.tar.gz|*.tgz|*.tar.zst|*.tzst|*.tar.xz|*.txz|*.tar.bz2|*.tbz2|*.zip|*.deb|*.apk|*.lpk) return 0 ;;
        *) return 1 ;;
    esac
}
_archive_kind() {
    case "${1##*/}" in
        *.deb) printf deb ;;
        *.zip|*.apk) printf zip ;;
        *.tar|*.tar.gz|*.tgz|*.tar.zst|*.tzst|*.tar.xz|*.txz|*.tar.bz2|*.tbz2) printf tar ;;
        *.lpk) tar -tf "$1" >/dev/null 2>&1 && { printf tar; return; }
               command -v unzip >/dev/null 2>&1 && unzip -Z1 "$1" >/dev/null 2>&1 && { printf zip; return; }
               printf unknown ;;
        *) printf unknown ;;
    esac
}
_archive_list_to() {
    local archive="$1" kind
    kind=$(_archive_kind "$archive")
    case "$kind" in
        tar) tar -tf "$archive" ;;
        zip) command -v unzip >/dev/null 2>&1 || return 127; unzip -Z1 "$archive" ;;
        deb) command -v dpkg-deb >/dev/null 2>&1 || return 127; dpkg-deb --fsys-tarfile "$archive" | tar -tf - ;;
        *) return 1 ;;
    esac
}
_archive_stream_member() {
    local archive="$1" member="$2" kind
    kind=$(_archive_kind "$archive")
    case "$kind" in
        tar) tar -xOf "$archive" -- "$member" ;;
        zip) unzip -p "$archive" "$member" ;;
        deb) dpkg-deb --fsys-tarfile "$archive" | tar -xOf - -- "$member" ;;
        *) return 1 ;;
    esac
}
# Archive contents are never extracted. Only selected regular files are streamed.
archive_browse() {
    local archive="$1" index="$TMP_OMNISH_DIR/archive-index.$$"
    local prefix='' selected rel child entry parent kind idx i
    local -a members=() options=() paths=()
    [[ -f "$archive" ]] || { status_msg "archive not found"; return 1; }
    kind=$(_archive_kind "$archive")
    [[ "$kind" != unknown ]] || { status_msg "unsupported archive"; return 1; }
    _archive_list_to "$archive" > "$index" || { rm -f -- "$index"; status_msg "cannot read archive"; return 1; }
    mapfile -t members < "$index"; rm -f -- "$index"
    while :; do
        options=(); paths=()
        [[ -n "$prefix" ]] && { options+=(".."); paths+=(".."); }
        local -A seen=()
        for rel in "${members[@]}"; do
            rel="${rel#./}"
            [[ -z "$rel" || "$rel" == /* ]] && continue
            case "/$rel/" in */../*) continue ;; esac
            [[ "$rel" == "$prefix"* ]] || continue
            child="${rel#"$prefix"}"; [[ -n "$child" ]] || continue
            if [[ "$child" == */* ]]; then
                entry="${child%%/*}/"; [[ -n "${seen[$entry]:-}" ]] && continue
                seen["$entry"]=1; options+=("[DIR] $entry"); paths+=("$prefix$entry")
            elif [[ "$child" == */ ]]; then
                entry="$child"; [[ -n "${seen[$entry]:-}" ]] && continue
                seen["$entry"]=1; options+=("[DIR] $entry"); paths+=("$prefix$entry")
            else
                options+=("$child"); paths+=("$prefix$child")
            fi
        done
        (("${#options[@]}" > 0)) || { status_msg "empty archive directory"; return 0; }
        selected=$(_omnish_select "Quick Archive — ${archive##*/} — /${prefix}" < <(printf '%s\n' "${options[@]}")) || return 0
        idx=-1
        for i in "${!options[@]}"; do [[ "${options[i]}" == "$selected" ]] && { idx=$i; break; }; done
        ((idx >= 0)) || return 0
        rel="${paths[idx]}"
        if [[ "$rel" == ".." ]]; then
            parent="${prefix%/}"
            if [[ "$parent" == */* ]]; then prefix="${parent%/*}/"; else prefix=''; fi
        elif [[ "$selected" == "[DIR] "* ]]; then
            prefix="$rel"
        elif command -v less >/dev/null 2>&1; then
            _archive_stream_member "$archive" "$rel" 2>/dev/null | less -R
        else
            _archive_stream_member "$archive" "$rel" 2>/dev/null | head -n 200
            printf '\n[preview limited to 200 lines]\n'
            read -rsn 1 -p "Press any key…" </dev/tty 2>/dev/null || :
        fi
    done
}
_archive_size() {
    if [[ -d "$1" && ! -L "$1" ]]; then du -sk -- "$1" 2>/dev/null | awk '{print $1 * 1024}'
    elif stat -c '%s' -- "$1" >/dev/null 2>&1; then stat -c '%s' -- "$1"
    else stat -f '%z' -- "$1" 2>/dev/null; fi
}
quick_archive() {
    local -a sources=() formats=("tar.gz — compatible" "tar.zst — fast + compact" "zip — universal")
    local source bytes total=0 ratio=80 estimate ext base output format rc
    if (("${#marked_files[@]}")); then sources=("${marked_files[@]}")
    elif [[ -n "${1:-}" && ( -e "$1" || -L "$1" ) ]]; then sources=("$1"); fi
    (("${#sources[@]}")) || { status_msg "mark files first, then press Z"; return 1; }
    for source in "${sources[@]}"; do
        [[ -e "$source" || -L "$source" ]] || { status_msg "missing source"; return 1; }
        bytes=$(_archive_size "$source"); [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
        total=$((total + bytes))
    done
    format=$(_omnish_select "Quick Archive — ${#sources[@]} item(s), source $(_human_size "$total")" < <(printf '%s\n' "${formats[@]}")) || return 0
    if [[ "$format" == tar.gz* ]]; then ext=tar.gz; ratio=75
    elif [[ "$format" == tar.zst* ]]; then ext=tar.zst; ratio=70
    elif [[ "$format" == zip* ]]; then ext=zip; ratio=85
    else return 1; fi
    estimate=$((total * ratio / 100))
    base="${sources[0]##*/}"; base="${base%.*}"; [[ -n "$base" ]] || base=archive
    output="$PWD/$base.$ext"; cmd_reply="$output"
    cmd_line "Save as [$output]: "; [[ -n "$cmd_reply" ]] && output="$cmd_reply"
    [[ "$output" == /* ]] || output="$PWD/$output"
    [[ "$output" == *".$ext" ]] || output="$output.$ext"
    for source in "${sources[@]}"; do [[ "$output" == "$source" ]] && { status_msg "output cannot replace source"; return 1; }; done
    if [[ -e "$output" ]]; then cmd_yes_no "Overwrite '${output##*/}'?"; [[ "$cmd_reply" == yes ]] || return 0; fi
    if [[ "$ext" == tar.gz ]]; then
        tar -czf "$output" -- "${sources[@]}"
    elif [[ "$ext" == tar.zst ]]; then
        command -v zstd >/dev/null 2>&1 || { status_msg "install zstd"; return 1; }
        tar --zstd -cf "$output" -- "${sources[@]}"
    else
        command -v zip >/dev/null 2>&1 || { status_msg "install zip"; return 1; }
        zip -qr "$output" -- "${sources[@]}"
    fi
    rc=$?
    if ((rc == 0)); then
        status_msg "created ${output##*/}; estimated $(_human_size "$estimate") (approx.)"
        marked_files=(); sync_marked_files
    else
        [[ -f "$output" ]] && rm -f -- "$output"; status_msg "compression failed (rc=$rc)"; return "$rc"
    fi
}
