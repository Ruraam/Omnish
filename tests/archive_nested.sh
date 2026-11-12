#!/usr/bin/env bash
# Bounded, read-only nested archive member extraction tests.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/omnish-archive-nested.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
for tool in tar zip unzip timeout sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'Missing nested archive test dependency: %s\n' "$tool" >&2
        exit 2
    }
done
source "$ROOT/lib/55-archive.sh"
TMP_OMNISH_DIR="$WORK"
mkdir -p "$WORK/inner"
printf 'nested payload\n' > "$WORK/inner/payload.txt"
zip -q "$WORK/inner.zip" -j "$WORK/inner/payload.txt"
tar -cf "$WORK/outer.tar" -C "$WORK" inner.zip
nested="$WORK/extracted.zip"
_archive_nested_member_to_file "$WORK/outer.tar" inner.zip "$nested"
[[ "$(_archive_kind "$nested")" == zip ]]
[[ "$(unzip -p "$nested" payload.txt)" == 'nested payload' ]]
# The byte ceiling must reject expansion beyond the configured limit.
printf '0123456789abcdef' > "$WORK/large.bin"
tar -cf "$WORK/large.tar" -C "$WORK" large.bin
if OMNISH_NESTED_ARCHIVE_MAX_BYTES=8 _archive_nested_member_to_file "$WORK/large.tar" large.bin "$WORK/too-large"; then
    echo 'Nested member byte limit was not enforced' >&2
    exit 1
fi
[[ ! -e "$WORK/too-large" ]]
# Unsafe member names must be rejected before any stream operation.
if _archive_nested_member_to_file "$WORK/outer.tar" ../inner.zip "$WORK/unsafe"; then
    echo 'Unsafe nested member path was accepted' >&2
    exit 1
fi
echo 'PASS: nested archive streaming, format validation and size/path limits.'
