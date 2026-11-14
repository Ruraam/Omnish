#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/omnish-transfer-test.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
source "$ROOT/lib/56-transfer.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

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

# The dispatcher must prefer marked files over the current selection.
marked_files=("$WORK/one.txt" "$WORK/two.txt")
_omnish_select() { printf '%s\n' 'croc (encrypted)'; }
PATH="$WORK/bin:$PATH" quick_transfer "$WORK/missing.txt"
grep -Fq -- "$WORK/one.txt" "$WORK/croc.args" || fail "marked file one was not transferred"
grep -Fq -- "$WORK/two.txt" "$WORK/croc.args" || fail "marked file two was not transferred"

echo 'PASS: Quick Transfer staging, port bounds and optional backend dispatch.'
