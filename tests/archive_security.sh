#!/usr/bin/env bash
# Security and stress integration tests for Quick Archive.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/omnish-archive-security.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

for tool in bsdtar curl python3 tar; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'Missing archive security test dependency: %s\n' "$tool" >&2
        exit 2
    }
done

source "$ROOT/lib/55-archive.sh"

# A genuine, tiny RAR3 fixture released under CC0. Pin the upstream commit so
# CI never silently switches to different test data.
RAR="$WORK/real-rar3.rar"
curl -fsSL --retry 3 \
    "https://raw.githubusercontent.com/ssokolow/rar-test-files/16b785c2b1b504e99fc307676e5369a26d3ce060/build/testfile.rar3.rar" \
    -o "$RAR"
[[ "$(stat -c '%s' "$RAR")" == 98 ]] || {
    echo "Unexpected RAR fixture size" >&2
    exit 1
}
[[ "$(_archive_kind "$RAR")" == libarchive ]] || {
    echo "The installed libarchive reader did not accept the genuine RAR3 fixture" >&2
    exit 1
}
mapfile -t rar_members < <(_archive_list_to "$RAR")
(("${#rar_members[@]}" > 0)) || {
    echo "The genuine RAR3 fixture contains no readable members" >&2
    exit 1
}
rar_payload="$WORK/rar-member.out"
_archive_stream_member "$RAR" "${rar_members[0]}" > "$rar_payload"
[[ -s "$rar_payload" ]] || {
    echo "Could not stream a member from the genuine RAR3 fixture" >&2
    exit 1
}

# Create traversal and absolute-path entries without ever extracting them.
python3 - "$WORK" <<'PY'
import pathlib
import sys
import tarfile
import zipfile

root = pathlib.Path(sys.argv[1])
with tarfile.open(root / "hostile.tar", "w") as archive:
    for name, payload in (("../outside.txt", b"traversal"),
                          ("/tmp/omnish-absolute.txt", b"absolute"),
                          ("safe/inside.txt", b"safe")):
        info = tarfile.TarInfo(name)
        info.size = len(payload)
        archive.addfile(info, __import__("io").BytesIO(payload))

with zipfile.ZipFile(root / "hostile.zip", "w") as archive:
    archive.writestr("../outside.zip.txt", "zip traversal")
    archive.writestr("safe/inside.txt", "safe")
PY

for unsafe in "../outside.txt" "/tmp/omnish-absolute.txt" "safe/../../escape"; do
    if _archive_member_is_safe "$unsafe"; then
        printf 'Unsafe archive member path accepted: %s\n' "$unsafe" >&2
        exit 1
    fi
done
for safe in "payload.txt" "./safe/inside.txt" "nested/file.txt"; do
    _archive_member_is_safe "$safe" || {
        printf 'Safe archive member path rejected: %s\n' "$safe" >&2
        exit 1
    }
done

# Listing hostile metadata must not create anything outside the temporary
# workspace. Both formats are inspected only; no extraction command is used.
_archive_list_to "$WORK/hostile.tar" > "$WORK/hostile-tar.list"
_archive_list_to "$WORK/hostile.zip" > "$WORK/hostile-zip.list"
[[ ! -e "$WORK/../outside.txt" && ! -e /tmp/omnish-absolute.txt ]] || {
    echo "Archive inspection unexpectedly wrote an external path" >&2
    exit 1
}

# Stream a moderately large member completely and verify exact byte count.
dd if=/dev/zero of="$WORK/large.bin" bs=1M count=8 status=none
tar -cf "$WORK/large.tar" -C "$WORK" large.bin
_archive_stream_member "$WORK/large.tar" large.bin > "$WORK/large.out"
[[ "$(wc -c < "$WORK/large.out")" -eq 8388608 ]] || {
    echo "Large archive member was truncated or streamed incorrectly" >&2
    exit 1
}

# Corrupt containers must fail during listing rather than being treated as
# successfully browsable archives.
printf 'not a zip file\n' > "$WORK/corrupt.zip"
printf 'not a gzip stream\n' > "$WORK/corrupt.tar.gz"
if _archive_list_to "$WORK/corrupt.zip" >/dev/null 2>&1; then
    echo "Corrupt ZIP was accepted" >&2
    exit 1
fi
if _archive_list_to "$WORK/corrupt.tar.gz" >/dev/null 2>&1; then
    echo "Corrupt gzip tar was accepted" >&2
    exit 1
fi

printf 'PASS: genuine RAR3, traversal/absolute paths, corrupt containers and 8 MiB streaming.\n'
