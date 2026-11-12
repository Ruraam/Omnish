# omnish — Quick Archive
# Smart compression and read-only virtual archive browsing.

archive_is_supported() {
    case "${1##*/}" in
        *.tar|*.tar.*|*.tgz|*.tzst|*.txz|*.tbz2|*.zip|*.deb|*.apk|*.lpk) return 0 ;;
        *) return 1 ;;
    esac
}
_archive_kind() {
    case "${1##*/}" in
        *.deb) printf deb ;;
        *.zip|*.apk) printf zip ;;
        *.tar|*.tar.*|*.tgz|*.tzst|*.txz|*.tbz2) printf tar ;;
        *.lpk)
            if [[ "$(head -c 4 -- "$1" 2>/dev/null)" == hsqs ]] && command -v unsquashfs >/dev/null 2>&1; then
                printf lpk
            elif tar -tf "$1" >/dev/null 2>&1; then
                printf tar
            elif command -v unzip >/dev/null 2>&1 && unzip -Z1 "$1" >/dev/null 2>&1; then
                printf zip
            else
                printf unknown
            fi
            ;;
        *) printf unknown ;;
    esac
}
# ULPM LPK v5: zstd-compressed SquashFS with an optional 104-byte
# Ed25519 trailer. Omnish only reads the container; it never verifies trust,
# installs, extracts, or modifies the package.
_archive_lpk_prepare_view() {
    local archive="$1" view="$2" size footer_size=104 footer_magic
    command -v unsquashfs >/dev/null 2>&1 || return 127
    [[ "$(head -c 4 -- "$archive" 2>/dev/null)" == hsqs ]] || return 1
    size="$(stat -c '%s' -- "$archive" 2>/dev/null || stat -f '%z' -- "$archive" 2>/dev/null)" || return 1
    [[ "$size" =~ ^[0-9]+$ ]] || return 1
    footer_magic=''
    if (( size >= footer_size )); then
        footer_magic="$(tail -c "$footer_size" -- "$archive" 2>/dev/null | head -c 8)"
    fi
    if [[ "$footer_magic" == ULPM_SIG ]]; then
        (( size > footer_size )) || return 1
        head -c "$((size - footer_size))" -- "$archive" > "$view" || return 1
    else
        cp -- "$archive" "$view" || return 1
    fi
    [[ "$(head -c 4 -- "$view" 2>/dev/null)" == hsqs ]] || { rm -f -- "$view"; return 1; }
    unsquashfs -s "$view" >/dev/null 2>&1 || { rm -f -- "$view"; return 1; }
}

_archive_lpk_list() {
    local archive="$1" view listing rc tmpdir
    tmpdir="${TMP_OMNISH_DIR:-${TMPDIR:-/tmp}}"
    mkdir -p -- "$tmpdir" || return 1
    view="$(mktemp "$tmpdir/omnish-lpk-view.XXXXXX")" || return 1
    listing="$view.list"
    if ! _archive_lpk_prepare_view "$archive" "$view"; then
        rm -f -- "$view" "$listing"
        return 1
    fi
    if unsquashfs -lln "$view" > "$listing" 2>/dev/null; then
        awk 'NF >= 6 { $1=$2=$3=$4=$5=""; sub(/^[[:space:]]+/, ""); if (substr($0,1,2) == "./") $0=substr($0,3); if ($0 != "") print }' "$listing"
        rc=$?
    else
        rc=1
    fi
    rm -f -- "$view" "$listing"
    return "$rc"
}

_archive_lpk_stream_member() {
    local archive="$1" member="$2" view rc tmpdir
    tmpdir="${TMP_OMNISH_DIR:-${TMPDIR:-/tmp}}"
    mkdir -p -- "$tmpdir" || return 1
    view="$(mktemp "$tmpdir/omnish-lpk-view.XXXXXX")" || return 1
    if ! _archive_lpk_prepare_view "$archive" "$view"; then
        rm -f -- "$view"
        return 1
    fi
    member="${member#./}"
    [[ -n "$member" && "$member" != /* ]] || { rm -f -- "$view"; return 1; }
    case "/$member/" in */../*) rm -f -- "$view"; return 1 ;; esac
    if unsquashfs -cat "$view" "$member"; then rc=0; else rc=$?; fi
    rm -f -- "$view"
    return "$rc"
}

_archive_list_to() {
    local archive="$1" kind
    kind=$(_archive_kind "$archive")
    case "$kind" in
        tar) tar -tf "$archive" ;;
        zip) command -v unzip >/dev/null 2>&1 || return 127; unzip -Z1 "$archive" ;;
        deb) command -v dpkg-deb >/dev/null 2>&1 || return 127; dpkg-deb --fsys-tarfile "$archive" | tar -tf - ;;
        lpk) _archive_lpk_list "$archive" ;;
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
        lpk) _archive_lpk_stream_member "$archive" "$member" ;;
        *) return 1 ;;
    esac
}
# Archive contents are never extracted. Only selected regular files are streamed.
archive_browse() {
    local archive="$1" index="$TMP_OMNISH_DIR/archive-index.$$"
    local prefix='' selected rel child entry parent kind idx i member_path
    local -a members=() options=() paths=()
    [[ -f "$archive" ]] || { status_msg "archive not found"; return 1; }
    kind=$(_archive_kind "$archive")
    [[ "$kind" != unknown ]] || { status_msg "unsupported archive"; return 1; }
    [[ "$kind" != lpk ]] || status_msg "ULPM LPK read-only view; embedded signature is not verified"
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
        else
            member_path="$rel"
            for entry in "${members[@]}"; do
                [[ "${entry#./}" == "$rel" ]] && { member_path="$entry"; break; }
            done
            if command -v less >/dev/null 2>&1; then
                _archive_stream_member "$archive" "$member_path" 2>/dev/null | less -R
            else
                _archive_stream_member "$archive" "$member_path" 2>/dev/null | head -n 200
                printf '\n[preview limited to 200 lines]\n'
                read -rsn 1 -p "Press any key…" </dev/tty 2>/dev/null || :
            fi
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
    local source source_dir source_name bytes total=0 ratio=80 estimate ext base output format rc
    local -a tar_args=()
    if (("${#marked_files[@]}")); then sources=("${marked_files[@]}")
    elif [[ -n "${1:-}" && ( -e "$1" || -L "$1" ) ]]; then sources=("$1"); fi
    (("${#sources[@]}")) || { status_msg "mark files first, then press Z"; return 1; }
    if declare -F _fileops_has_duplicate_basenames >/dev/null 2>&1 && _fileops_has_duplicate_basenames "${sources[@]}"; then
        status_msg "duplicate basenames in selection; archive separately"
        return 1
    fi
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
    for source in "${sources[@]}"; do
        [[ "$output" == "$source" ]] && { status_msg "output cannot replace source"; return 1; }
        [[ -d "$source" && ! -L "$source" && "$output" == "${source%/}/"* ]] && { status_msg "archive output cannot be inside a selected directory"; return 1; }
        source_dir="${source%/*}"; [[ "$source_dir" == "$source" ]] && source_dir="$PWD"
        [[ -n "$source_dir" ]] || source_dir=/
        source_name="${source##*/}"
        tar_args+=(-C "$source_dir" "./$source_name")
    done
    if [[ -e "$output" ]]; then
        cmd_yes_no "Overwrite archive?"; [[ "$cmd_reply" == yes ]] || return 0
        rm -f -- "$output" || { status_msg "cannot replace existing archive"; return 1; }
    fi
    if [[ "$ext" == tar.gz ]]; then
        if tar -czf "$output" "${tar_args[@]}"; then rc=0; else rc=$?; fi
    elif [[ "$ext" == tar.zst ]]; then
        command -v zstd >/dev/null 2>&1 || { status_msg "install zstd"; return 1; }
        if tar --zstd -cf "$output" "${tar_args[@]}"; then rc=0; else rc=$?; fi
    else
        command -v zip >/dev/null 2>&1 || { status_msg "install zip"; return 1; }
        rc=0
        for source in "${sources[@]}"; do
            source_dir="${source%/*}"; [[ "$source_dir" == "$source" ]] && source_dir="$PWD"
            [[ -n "$source_dir" ]] || source_dir=/
            source_name="${source##*/}"
            (cd -- "$source_dir" && zip -qr "$output" "./$source_name") || { rc=$?; break; }
        done
    fi
    if ((rc == 0)); then
        status_msg "created ${output##*/}; estimated $(_human_size "$estimate") (approx.)"
        marked_files=(); sync_marked_files
    else
        [[ -f "$output" ]] && rm -f -- "$output"; status_msg "compression failed (rc=$rc)"; return "$rc"
    fi
}
