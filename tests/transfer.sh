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
    http_port=41987
    export TMP_OMNISH_DIR="$WORK/tmp-root" TEST_HTTP_PORT="$http_port" TEST_HTTP_FILE="$WORK/http-payload.txt"
    bash -c '
        source "$1/lib/56-transfer.sh"
        _transfer_local_ip() { printf "127.0.0.1\\n"; }
        _transfer_random_port() { printf "%s\\n" "$TEST_HTTP_PORT"; }
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

# The dispatcher must prefer marked files over the current selection.
marked_files=("$WORK/one.txt" "$WORK/two.txt")
_omnish_select() { printf '%s\n' 'croc (encrypted)'; }
PATH="$WORK/bin:$PATH" quick_transfer "$WORK/missing.txt"
grep -Fq -- "$WORK/one.txt" "$WORK/croc.args" || fail "marked file one was not transferred"
grep -Fq -- "$WORK/two.txt" "$WORK/croc.args" || fail "marked file two was not transferred"

echo 'PASS: Quick Transfer staging, port bounds and optional backend dispatch.'
