# omnish — Quick Transfer
# Local HTTP sharing with optional croc / Magic Wormhole integrations.

_transfer_err() {
    printf 'omnish transfer: %s\n' "$*" 2>/dev/null >/dev/tty || printf 'omnish transfer: %s\n' "$*" >&2
}

_transfer_private_dir() {
    local root="${TMP_OMNISH_DIR:-${TMPDIR:-/tmp}}"
    mkdir -p -- "$root" 2>/dev/null || return 1
    umask 077
    mktemp -d "$root/omnish-transfer.XXXXXX"
}

_transfer_random_port() {
    local min="${OMNISH_TRANSFER_PORT_MIN:-40000}" max="${OMNISH_TRANSFER_PORT_MAX:-49999}" span
    [[ "$min" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]] || return 2
    (( min >= 1024 && max <= 65535 && min <= max )) || return 2
    span=$((max - min + 1))
    printf '%s\n' "$((min + (RANDOM * 32768 + RANDOM) % span))"
}

_transfer_local_ip() {
    local ip
    if command -v ip >/dev/null 2>&1; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
        [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { printf '%s\n' "$ip"; return 0; }
    fi
    if command -v hostname >/dev/null 2>&1; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { printf '%s\n' "$ip"; return 0; }
    fi
    return 1
}

_transfer_stage_files() {
    local stage="$1" src base dest n=1
    shift
    (( $# > 0 )) || return 2
    for src in "$@"; do
        [[ -f "$src" && ! -L "$src" ]] || { _transfer_err "only regular files can be shared: $src"; return 1; }
        base=$(basename -- "$src")
        dest="$stage/$base"
        while [[ -e "$dest" ]]; do dest="$stage/$n-$base"; ((n+=1)); done
        if ln -- "$src" "$dest" 2>/dev/null; then :; else cp -- "$src" "$dest" || return 1; fi
    done
}

_transfer_qr() {
    local url="$1"
    if command -v qrencode >/dev/null 2>&1; then qrencode -t ANSIUTF8 -m 1 "$url" </dev/tty >/dev/tty 2>&1 || :; fi
    printf '\nOpen on your phone:\n%s\n' "$url" >/dev/tty 2>/dev/null || printf '\n%s\n' "$url"
}

_transfer_http_server() {
    local stage="$1" port="$2" ip="$3" server_pid='' url="http://$ip:$port/"
    local server_output=/dev/stderr old_int_trap old_term_trap
    local server_rc=0 interrupted=0 ready=0 attempt

    # Fail before spawning a server when another process already owns the
    # requested TCP port. This is a preflight check; a concurrent bind can
    # still win the small interval before our server starts.
    if ( exec 3<>"/dev/tcp/$ip/$port" ) 2>/dev/null; then
        _transfer_err "TCP port $port is already in use on $ip"
        return 1
    fi

    if command -v python3 >/dev/null 2>&1; then
        if ( : >/dev/tty ) 2>/dev/null; then server_output=/dev/tty; fi
        (cd -- "$stage" && exec python3 -m http.server "$port" --bind "$ip") >"$server_output" 2>&1 &
        server_pid=$!
    elif command -v busybox >/dev/null 2>&1; then
        if ( : >/dev/tty ) 2>/dev/null; then server_output=/dev/tty; fi
        (cd -- "$stage" && exec busybox httpd -f -p "$ip:$port" -h "$stage") >"$server_output" 2>&1 &
        server_pid=$!
    else
        _transfer_err "python3 or busybox is required for local HTTP sharing"
        return 127
    fi

    # Wait for a real TCP listener, not merely a live PID (which can be a
    # server that has already failed to bind because the port is occupied).
    for ((attempt=0; attempt<30; attempt++)); do
        if ! kill -0 "$server_pid" 2>/dev/null; then
            wait "$server_pid" 2>/dev/null || :
            _transfer_err "HTTP server exited before becoming ready"
            return 1
        fi
        if ( exec 3<>"/dev/tcp/$ip/$port" ) 2>/dev/null; then
            ready=1
            break
        fi
        sleep 0.1
    done
    if (( ! ready )); then
        kill "$server_pid" 2>/dev/null || :
        wait "$server_pid" 2>/dev/null || :
        _transfer_err "HTTP server did not become ready"
        return 1
    fi

    clear </dev/tty 2>/dev/null || :
    printf 'Quick Transfer — local HTTP\n\n' >/dev/tty 2>/dev/null || :
    _transfer_qr "$url"
    printf '\nServer is running. Press Ctrl+C to stop sharing.\n' >/dev/tty 2>/dev/null || :

    # Preserve signal handlers installed by the caller; restore them after
    # reaping the child so Quick Transfer does not alter the parent shell.
    old_int_trap=$(trap -p INT || :)
    old_term_trap=$(trap -p TERM || :)
    trap 'interrupted=1; kill "$server_pid" 2>/dev/null || :' INT TERM

    if wait "$server_pid"; then
        server_rc=0
    else
        server_rc=$?
    fi

    if (( interrupted )); then
        kill "$server_pid" 2>/dev/null || :
        wait "$server_pid" 2>/dev/null || :
        server_rc=0
    fi

    trap - INT TERM
    [[ -n "$old_int_trap" ]] && eval "$old_int_trap"
    [[ -n "$old_term_trap" ]] && eval "$old_term_trap"
    return "$server_rc"
}
_transfer_http() {
    local -a files=("$@")
    local stage ip port
    stage=$(_transfer_private_dir) || { _transfer_err "cannot create private staging directory"; return 1; }
    _transfer_stage_files "$stage" "${files[@]}" || { rm -rf -- "$stage"; return 1; }
    ip=$(_transfer_local_ip) || { _transfer_err "cannot determine a LAN IPv4 address"; rm -rf -- "$stage"; return 1; }
    port=$(_transfer_random_port) || { _transfer_err "invalid transfer port range"; rm -rf -- "$stage"; return 1; }
    local rc=0
    if _transfer_http_server "$stage" "$port" "$ip"; then
        rc=0
    else
        rc=$?
    fi
    rm -rf -- "$stage"
    return "$rc"
}

_transfer_croc() {
    local code
    code=$(printf '%04x%04x%04x%04x' "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM")
    printf 'croc transfer code: %s\n' "$code" 2>/dev/null >/dev/tty || :
    CROC_SECRET="$code" croc send "$@"
}

_transfer_wormhole() { wormhole send "$@"; }

quick_transfer() {
    local selected="${1:-}"
    local -a files=()
    local choice
    if (( ${#marked_files[@]} > 0 )); then files=("${marked_files[@]}"); elif [[ -n "$selected" && -f "$selected" ]]; then files=("$selected"); else
        _transfer_err "mark one or more regular files, or select a file first"; return 1
    fi
    choice=$(_omnish_select "Send ${#files[@]} file(s)" < <(
        printf '%s\n' "Local HTTP (zero-dependency)"
        command -v croc >/dev/null 2>&1 && printf '%s\n' "croc (encrypted)"
        command -v wormhole >/dev/null 2>&1 && printf '%s\n' "Magic Wormhole"
        printf '%s\n' "Cancel"
    )) || return 0
    case "$choice" in
        "Local HTTP (zero-dependency)") _transfer_http "${files[@]}" ;;
        "croc (encrypted)") _transfer_croc "${files[@]}" ;;
        "Magic Wormhole") _transfer_wormhole "${files[@]}" ;;
        *) return 0 ;;
    esac
}
