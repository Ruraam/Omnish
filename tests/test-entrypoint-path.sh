#!/usr/bin/env bash
# Regression tests for the Omnish entrypoint self-path resolver.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/omnish-self-path.XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# Load only the resolver function so tests do not start the interactive UI.
# shellcheck source=/dev/null
source <(sed -n '/^_omnish_resolve_self() {/,/^}/p' "$ROOT/omnish")

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expected="$ROOT/omnish"
actual=$(_omnish_resolve_self "$ROOT/omnish")
[[ "$actual" == "$expected" ]] || fail "absolute entrypoint path did not resolve"
printf 'PASS: absolute entrypoint path\n'

(
    cd -- "$ROOT"
    actual=$(_omnish_resolve_self ./omnish)
    [[ "$actual" == "$expected" ]] || fail "relative entrypoint path did not resolve"
)
printf 'PASS: relative entrypoint path\n'

mkdir -p -- "$TEST_ROOT/real dir" "$TEST_ROOT/first link dir" "$TEST_ROOT/second link dir"
touch -- "$TEST_ROOT/real dir/entry point"
ln -s -- "../real dir/entry point" "$TEST_ROOT/first link dir/first link"
ln -s -- "../first link dir/first link" "$TEST_ROOT/second link dir/second link"

actual=$(_omnish_resolve_self "$TEST_ROOT/second link dir/second link")
expected="$TEST_ROOT/real dir/entry point"
[[ "$actual" == "$expected" ]] || fail "relative symlink chain did not resolve"
printf 'PASS: relative symlink chain with spaces\n'

printf '\nAll entrypoint path tests passed.\n'
