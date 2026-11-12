#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/omnish-archive-magic.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
for tool in tar zip unzip bsdtar genisoimage gcab ar; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing dependency: $tool" >&2; exit 2; }
done
source "$ROOT/lib/55-archive.sh"
mkdir -p "$WORK/source"
printf 'magic detection payload\n' > "$WORK/source/payload.txt"
check() {
    local actual
    actual="$(_archive_kind "$1")"
    [[ "$actual" == "$2" ]] || { printf 'Expected %s for %s, got %s\n' "$2" "$1" "$actual" >&2; exit 1; }
    _archive_list_to "$1" >/dev/null
}
tar -czf "$WORK/gzip.data" -C "$WORK/source" payload.txt
check "$WORK/gzip.data" tar
tar -cJf "$WORK/xz.data" -C "$WORK/source" payload.txt
check "$WORK/xz.data" tar
tar -cf "$WORK/plain.data" -C "$WORK/source" payload.txt
check "$WORK/plain.data" tar
zip -q "$WORK/zip.data" -j "$WORK/source/payload.txt"
check "$WORK/zip.data" zip
bsdtar --format=7zip -cf "$WORK/seven.data" -C "$WORK/source" payload.txt
check "$WORK/seven.data" libarchive
genisoimage -quiet -R -o "$WORK/iso.data" "$WORK/source"
check "$WORK/iso.data" libarchive
(cd "$WORK/source" && gcab -c "$WORK/cab.data" payload.txt)
check "$WORK/cab.data" libarchive
ar r "$WORK/ar.data" "$WORK/source/payload.txt" >/dev/null
check "$WORK/ar.data" libarchive
printf 'not a zip\n' > "$WORK/fake.zip"
[[ "$(_archive_kind "$WORK/fake.zip")" == unknown ]]
cp "$WORK/zip.data" "$WORK/renamed.bin"
[[ "$(_archive_kind "$WORK/renamed.bin")" == zip ]]
echo 'PASS: content-based tar, gzip, xz, ZIP, 7z, ISO, CAB and ar detection.'