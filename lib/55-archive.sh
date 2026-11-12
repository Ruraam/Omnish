# omnish — Quick Archive
# Smart compression and read-only virtual archive browsing.

archive_is_supported() {
    case "${1##*/}" in
        *.tar|*.tar.*|*.tgz|*.tzst|*.txz|*.tbz2|*.zip|*.deb|*.apk|*.lpk|*.rar|*.7z|*.iso|*.cab|*.ar) return 0 ;;
        *) [[ -f "$1" ]] && [[ "$(_archive_kind "$1")" != unknown ]] ;;
    esac
}
_archive_magic_hex() {
    od -An -tx1 -N "\${3:-8}" -j "\${2:-0}" -- "$1" 2>/dev/null | tr -d ' \n'
}
_archive_libarchive_valid() {
    command -v bsdtar >/dev/null 2>&1 && bsdtar -tf "$1" >/dev/null 2>&1
}
_archive_kind() {
    local archive="$1" name="\${1##*/}" magic
    [[ -f "$archive" && -r "$archive" ]] || { printf unknown; return; }
    magic="$(_archive_magic_hex "$archive" 0 8)"
    if [[ "$magic" == 68737173 ]]; then
        if command -v unsquashfs >/dev/null 2>&1; then printf lpk
        else printf unknown; fi
        return
    fi
    case "$magic" in
        504b0304*|504b0506*|504b0708*)
            if command -v unzip >/dev/null 2>&1 && unzip -Z1 "$archive" >/dev/null 2>&1; then printf zip
            else printf unknown; fi
            return ;;
        213c617263683e0a)
            if command -v dpkg-deb >/dev/null 2>&1 && dpkg-deb --info "$archive" >/dev/null 2>&1; then printf deb
            elif _archive_libarchive_valid "$archive"; then printf libarchive
            else printf unknown; fi
            return ;;
        1f8b*)
            if tar -tzf "$archive" >/dev/null 2>&1; then printf tar; else printf unknown; fi
            return ;;
        28b52ffd*)
            if tar --zstd -tf "$archive" >/dev/null 2>&1; then printf tar
            elif _archive_libarchive_valid "$archive"; then printf libarchive
            else printf unknown; fi
            return ;;
        fd377a585a00*)
            if tar -tJf "$archive" >/dev/null 2>&1; then printf tar; else printf unknown; fi
            return ;;
        425a68*)
            if tar -tjf "$archive" >/dev/null 2>&1; then printf tar; else printf unknown; fi
            return ;;
    esac
    if [[ "$(_archive_magic_hex "$archive" 257 5)" == 7573746172 ]] || [[ "$name" == *.tar ]]; then
        if tar -tf "$archive" >/dev/null 2>&1; then printf tar; else printf unknown; fi
        return
    fi
    case "$magic" in
        377abcaf271c*|526172211a0700*|526172211a070100*|4d534346*)
            if _archive_libarchive_valid "$archive"; then printf libarchive; else printf unknown; fi
            return ;;
    esac
    if [[ "$(_archive_magic_hex "$archive" 32769 5)" == 4344303031 ]]; then
        if _archive_libarchive_valid "$archive"; then printf libarchive; else printf unknown; fi
        return
    fi
    if [[ "$name" == *.lpk ]]; then
        if tar -tf "$archive" >/dev/null 2>&1; then printf tar
        elif command -v unzip >/dev/null 2>&1 && unzip -Z1 "$archive" >/dev/null 2>&1; then printf zip
        else printf unknown; fi
        return
    fi

    # Keep compatibility with older variants, but validate the suffix hint
    # with the matching reader before accepting the container.
    case "$name" in
        *.zip|*.apk)
            if command -v unzip >/dev/null 2>&1 && unzip -Z1 "$archive" >/dev/null 2>&1; then printf zip; else printf unknown; fi
            return ;;
        *.rar|*.7z|*.iso|*.cab|*.ar)
            if _archive_libarchive_valid "$archive"; then printf libarchive; else printf unknown; fi
            return ;;
        *.deb)
            if command -v dpkg-deb >/dev/null 2>&1 && dpkg-deb --info "$archive" >/dev/null 2>&1; then printf deb; else printf unknown; fi
            return ;;
    esac
    printf unknown
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
        awk 'NF >= 6 { $1=$2=$3=$4=$5=""; sub(/^[[:space:]]+/, ""); if (substr($0,1,2) == "./") $0=substr($0,3); sub(/^squashfs-root\/?/, ""); if ($0 != "") print }' "$listing"
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

# Reject archive member paths that could escape the virtual archive root.
# Browsing is read-only, but filtering unsafe names also keeps navigation sane.
_archive_member_is_safe() {
    local member="${1#./}"
    [[ -n "$member" && "$member" != /* ]] || return 1
    case "/$member/" in
        */../*) return 1 ;;
    esac
    return 0
}
_archive_list_to() {
    local archive="$1" kind
    kind=$(_archive_kind "$archive")
    case "$kind" in
        tar) tar -tf "$archive" ;;
        zip) command -v unzip >/dev/null 2>&1 || return 127; unzip -Z1 "$archive" ;;
        deb) command -v dpkg-deb >/dev/null 2>&1 || return 127; dpkg-deb --fsys-tarfile "$archive" | tar -tf - ;;
        libarchive) bsdtar -tf "$archive" ;;
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
        libarchive) bsdtar -xOf "$archive" "$member" ;;
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
            _archive_member_is_safe "$rel" || continue
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
    local source source_dir source_name bytes total=0 ratio=80 estimate ext base output format rc archive_tmpdir archive_target
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
    if [[ -e "$output" || -L "$output" ]]; then
        [[ ! -d "$output" ]] || { status_msg "output path is a directory"; return 1; }
        cmd_yes_no "Overwrite archive?"; [[ "$cmd_reply" == yes ]] || return 0
    fi

    # Build beside the destination, then atomically replace it only after the
    # complete archive has been created. A failed compression never destroys
    # a previously existing archive.
    archive_tmpdir="$(mktemp -d "${output%/*}/.omnish-archive.XXXXXX")" || {
        status_msg "cannot create temporary archive directory"
        return 1
    }
    archive_target="$archive_tmpdir/${output##*/}"
    if [[ "$ext" == tar.gz ]]; then
        if tar -czf "$archive_target" "${tar_args[@]}"; then rc=0; else rc=$?; fi
    elif [[ "$ext" == tar.zst ]]; then
        if ! command -v zstd >/dev/null 2>&1; then
            rm -rf -- "$archive_tmpdir"; status_msg "install zstd"; return 1
        fi
        if tar --zstd -cf "$archive_target" "${tar_args[@]}"; then rc=0; else rc=$?; fi
    else
        if ! command -v zip >/dev/null 2>&1; then
            rm -rf -- "$archive_tmpdir"; status_msg "install zip"; return 1
        fi
        rc=0
        for source in "${sources[@]}"; do
            source_dir="${source%/*}"; [[ "$source_dir" == "$source" ]] && source_dir="$PWD"
            [[ -n "$source_dir" ]] || source_dir=/
            source_name="${source##*/}"
            (cd -- "$source_dir" && zip -qr "$archive_target" "./$source_name") || { rc=$?; break; }
        done
    fi
    if ((rc == 0)) && mv -f -- "$archive_target" "$output"; then
        rm -rf -- "$archive_tmpdir"
        status_msg "created ${output##*/}; estimated $(_human_size "$estimate") (approx.)"
        marked_files=(); sync_marked_files
    else
        rm -rf -- "$archive_tmpdir"
        (( rc != 0 )) || rc=$?
        status_msg "compression failed (rc=$rc)"
        return "$rc"
    fi
}
