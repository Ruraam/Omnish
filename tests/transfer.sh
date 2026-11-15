#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/omnish-transfer-test.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
trap 'rc=$?; printf "FAIL: transfer test line %s: %s (exit %s)\n" "$LINENO" "$BASH_COMMAND" "$rc" >&2' ERR
source "$ROOT/lib/56-transfer.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# A VPN default route must not cause us to advertise its tunnel address.
mkdir -p "$WORK/mock-ip"
cat > "$WORK/mock-ip/ip" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-4 route get 1.1.1.1" ]]; then
    printf '%s\n' '1.1.1.1 dev tun0 src 10.8.0.4 uid 1000'
elif [[ "$*" == "-o -4 addr show scope global" ]]; then
    printf '%s\n' '2: tun0 inet 10.8.0.4/24 scope global tun0'
    printf '%s\n' '3: wlan0 inet 192.168.1.44/24 scope global wlan0'
fi
EOF
chmod +x "$WORK/mock-ip/ip"
lan_ip=$(PATH="$WORK/mock-ip:$PATH" _transfer_local_ip) || fail "LAN address detection failed behind VPN"
[[ "$lan_ip" == "192.168.1.44" ]] || fail "VPN tunnel address was selected instead of LAN address: $lan_ip"

# When multiple physical interfaces exist, prefer the private LAN address
# over a public address selected by the default route.
cat > "$WORK/mock-ip/ip" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-4 route get 1.1.1.1" ]]; then
    printf '%s\n' '1.1.1.1 dev eth0 src 203.0.113.10 uid 1000'
elif [[ "$*" == "-o -4 addr show scope global" ]]; then
    printf '%s\n' '2: eth0 inet 203.0.113.10/24 scope global eth0'
    printf '%s\n' '3: wlan0 inet 192.168.1.44/24 scope global wlan0'
fi
EOF
lan_ip=$(PATH="$WORK/mock-ip:$PATH" _transfer_local_ip) || fail "multi-interface address detection failed"
[[ "$lan_ip" == "192.168.1.44" ]] || fail "public default-route address won over private LAN address: $lan_ip"

# No usable interface must fail instead of advertising loopback/tunnel data.
cat > "$WORK/mock-ip/ip" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-4 route get 1.1.1.1" ]]; then
    printf '%s\n' '1.1.1.1 dev wg0 src 10.7.0.2 uid 1000'
fi
EOF
if PATH="$WORK/mock-ip:$PATH" _transfer_local_ip >/dev/null; then
    fail "address detection accepted a machine without a usable interface"
fi





OMNISH_TRANSFER_PORT_MIN=41000
OMNISH_TRANSFER_PORT_MAX=41010
for _ in {1..50}; do
    port=$(_transfer_random_port)
    [[ "$port" =~ ^[0-9]+$ ]] || fail "random port was not numeric"
    (( port >= 41000 && port <= 41010 )) || fail "random port escaped configured range"
done

mkdir -p "$WORK/stage"
printf 'one\n' > "$WORK/one.txt"
printf 'two\n' > "$WORK/two.txt"
_transfer_stage_files "$WORK/stage" "$WORK/one.txt" "$WORK/two.txt"
[[ "$(cat "$WORK/stage/one.txt")" == one ]] || fail "staged first file mismatch"
[[ "$(cat "$WORK/stage/two.txt")" == two ]] || fail "staged second file mismatch"

# Staged payloads must be independent snapshots, not hard links to originals.
printf 'original snapshot\n' > "$WORK/snapshot.txt"
_transfer_stage_files "$WORK/stage" "$WORK/snapshot.txt"
printf 'changed after staging\n' > "$WORK/snapshot.txt"
[[ "$(cat "$WORK/stage/snapshot.txt")" == "original snapshot" ]] || fail "staged payload changed with its source file"

# Files with identical basenames must remain distinct and retain their contents.
mkdir -p "$WORK/source-a" "$WORK/source-b"
printf 'collision A\n' > "$WORK/source-a/report.txt"
printf 'collision B\n' > "$WORK/source-b/report.txt"
_transfer_stage_files "$WORK/stage" "$WORK/source-a/report.txt" "$WORK/source-b/report.txt"
[[ "$(cat "$WORK/stage/report.txt")" == "collision A" ]] || fail "first duplicate-basename file was overwritten"
[[ "$(cat "$WORK/stage/1-report.txt")" == "collision B" ]] || fail "second duplicate-basename file was not renamed safely"

# Shell metacharacters, spaces and leading dashes must be treated as filename data.
printf 'special filename\n' > "$WORK/- report [1].txt"
_transfer_stage_files "$WORK/stage" "$WORK/- report [1].txt"
[[ "$(cat "$WORK/stage/- report [1].txt")" == "special filename" ]] || fail "special-character filename was not staged intact"
# A dangling destination symlink must count as occupied; never follow it outside staging.
printf 'outside sentinel\n' > "$WORK/outside-sentinel.txt"
ln -s "$WORK/outside-sentinel.txt.missing" "$WORK/stage/dangling.txt"
printf 'safe staged payload\n' > "$WORK/dangling.txt"
_transfer_stage_files "$WORK/stage" "$WORK/dangling.txt"
[[ "$(cat "$WORK/outside-sentinel.txt")" == "outside sentinel" ]] || fail "staging modified a file outside its directory"
[[ ! -e "$WORK/outside-sentinel.txt.missing" ]] || fail "staging followed a dangling symlink outside its directory"
[[ "$(cat "$WORK/stage/1-dangling.txt")" == "safe staged payload" ]] || fail "dangling symlink collision was not safely renamed"
if _transfer_stage_files "$WORK/stage" "$WORK/missing.txt"; then fail "missing file was accepted"; fi
ln -s "$WORK/one.txt" "$WORK/link.txt"
if _transfer_stage_files "$WORK/stage" "$WORK/link.txt"; then fail "symlink was accepted"; fi

mkdir -p "$WORK/bin"
cat > "$WORK/bin/croc" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CROC_ARGS"
printf '%s\n' "${CROC_SECRET:-}" > "$CROC_SECRET_OUT"
EOF
chmod +x "$WORK/bin/croc"
export CROC_ARGS="$WORK/croc.args" CROC_SECRET_OUT="$WORK/croc.secret"
PATH="$WORK/bin:$PATH" _transfer_croc "$WORK/one.txt"
grep -Eq '^send ' "$WORK/croc.args" || fail "croc send command was not invoked"
grep -Eq '^[[:xdigit:]]{16}$' "$WORK/croc.secret" || fail "croc did not receive a valid 16-character secret"
grep -Fq -- "$WORK/one.txt" "$WORK/croc.args" || fail "croc did not receive selected path"

printf 'DEBUG: Croc integration passed\n' >&2

# An occupied port must be rejected before a second server is spawned.
if command -v python3 >/dev/null 2>&1; then
    occupied_port=43123
    python3 -c 'import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", 43123)); s.listen(); print("ready", flush=True); time.sleep(10)' >"$WORK/occupied-port.log" 2>&1 &
    occupied_pid=$!
    ready=0
    for _ in {1..50}; do
        if grep -q '^ready$' "$WORK/occupied-port.log"; then ready=1; break; fi
        kill -0 "$occupied_pid" 2>/dev/null || break
        sleep 0.1
    done
    (( ready )) || { cat "$WORK/occupied-port.log" >&2; fail "could not start occupied-port fixture"; }
    printf 'DEBUG: occupied fixture ready\n' >&2
    # Capture the diagnostic instead of allowing _transfer_err to write to /dev/tty.
    _transfer_err() { printf 'omnish transfer: %s\n' "$*" >&2; }
    if _transfer_http_server "$WORK/stage" "$occupied_port" 127.0.0.1 >"$WORK/occupied-server.log" 2>&1; then
        kill "$occupied_pid" 2>/dev/null || :
        wait "$occupied_pid" 2>/dev/null || :
        fail "HTTP server accepted an already occupied port"
    else
        server_rc=$?
    fi
    printf 'DEBUG: occupied server returned %s\n' "$server_rc" >&2
    grep -Fq "TCP port $occupied_port is already in use" "$WORK/occupied-server.log" || { cat "$WORK/occupied-server.log" >&2; fail "occupied-port rejection did not explain the collision"; }
    printf 'DEBUG: occupied rejection message verified\n' >&2
    kill "$occupied_pid" 2>/dev/null || :
    wait "$occupied_pid" 2>/dev/null || :
    printf 'DEBUG: occupied fixture stopped\n' >&2
fi

printf 'DEBUG: occupied-port test passed\n' >&2

# Exercise a real HTTP server without requiring a controlling terminal.
if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    mkdir -p "$WORK/tmp-root"
    printf 'http lifecycle payload\n' > "$WORK/http-payload.txt"
    OMNISH_TRANSFER_PORT_MIN=42000
    OMNISH_TRANSFER_PORT_MAX=42999
    http_port=$(_transfer_random_port)
    export TMP_OMNISH_DIR="$WORK/tmp-root" TEST_HTTP_PORT="$http_port" TEST_HTTP_FILE="$WORK/http-payload.txt"
    bash -c '
        source "$1/lib/56-transfer.sh"
_transfer_local_ip() { echo 127.0.0.1; }
_transfer_random_port() { echo "$TEST_HTTP_PORT"; }
        _transfer_http "$TEST_HTTP_FILE"
    ' _ "$ROOT" >"$WORK/http-server.log" 2>&1 &
    http_pid=$!

    ready=0
    for _ in {1..50}; do
        if curl --fail --silent "http://127.0.0.1:$http_port/http-payload.txt" -o "$WORK/http-download.txt"; then
            ready=1
            break
        fi
        kill -0 "$http_pid" 2>/dev/null || break
        sleep 0.1
    done
    (( ready )) || { cat "$WORK/http-server.log" >&2; fail "HTTP server did not serve staged file"; }
    cmp -s "$WORK/http-payload.txt" "$WORK/http-download.txt" || fail "HTTP download content mismatch"

    kill -TERM "$http_pid"
    wait "$http_pid" || :
    [[ -z "$(find "$WORK/tmp-root" -mindepth 1 -maxdepth 1 -name 'omnish-transfer.*' -print -quit)" ]] || fail "staging directory leaked after SIGTERM"
    if curl --fail --silent --max-time 1 "http://127.0.0.1:$http_port/" >/dev/null; then
        fail "HTTP server remained reachable after shutdown"
    fi
fi

printf 'DEBUG: Python HTTP test passed\n' >&2

# Exercise the BusyBox httpd fallback with Python deliberately hidden from PATH.
if command -v busybox >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    mkdir -p "$WORK/busybox-bin" "$WORK/busybox-stage"
    busybox_path=$(command -v busybox)
    ln -s "$busybox_path" "$WORK/busybox-bin/busybox"
    ln -s "$busybox_path" "$WORK/busybox-bin/sleep"
    printf 'busybox fallback payload\n' > "$WORK/busybox-stage/busybox-payload.txt"
    busybox_port=43087
    PATH="$WORK/busybox-bin" /bin/bash -c '
        source "$1/lib/56-transfer.sh"
        _transfer_http_server "$2" "$3" 127.0.0.1
    ' _ "$ROOT" "$WORK/busybox-stage" "$busybox_port" >"$WORK/busybox-server.log" 2>&1 &
    busybox_pid=$!

    ready=0
    for _ in {1..50}; do
        if curl --fail --silent "http://127.0.0.1:$busybox_port/busybox-payload.txt" -o "$WORK/busybox-download.txt"; then
            ready=1
            break
        fi
        kill -0 "$busybox_pid" 2>/dev/null || break
        sleep 0.1
    done
    (( ready )) || { cat "$WORK/busybox-server.log" >&2; fail "BusyBox httpd fallback did not serve staged file"; }
    cmp -s "$WORK/busybox-stage/busybox-payload.txt" "$WORK/busybox-download.txt" || fail "BusyBox HTTP download content mismatch"

    kill -TERM "$busybox_pid"
    wait "$busybox_pid" || :
    if curl --fail --silent --max-time 1 "http://127.0.0.1:$busybox_port/" >/dev/null; then
        fail "BusyBox HTTP server remained reachable after SIGTERM"
    fi
fi

printf 'DEBUG: BusyBox HTTP test passed\n' >&2

# The dispatcher must prefer marked files over the current selection.
marked_files=("$WORK/one.txt" "$WORK/two.txt")
_omnish_select() { printf '%s\n' 'croc (encrypted)'; }
PATH="$WORK/bin:$PATH" quick_transfer "$WORK/missing.txt"
grep -Fq -- "$WORK/one.txt" "$WORK/croc.args" || fail "marked file one was not transferred"
grep -Fq -- "$WORK/two.txt" "$WORK/croc.args" || fail "marked file two was not transferred"

echo 'PASS: Quick Transfer staging, port bounds and optional backend dispatch.'
