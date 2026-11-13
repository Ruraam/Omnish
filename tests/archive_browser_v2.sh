#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/omnish-archive-v2.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
for tool in tar timeout file stat sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing dependency: $tool" >&2; exit 2; }
done
source "$ROOT/lib/10-utils.sh"
source "$ROOT/lib/55-archive.sh"
TMP_OMNISH_DIR="$WORK"
mkdir -p "$WORK/source/docs"
printf 'Quick Archive v2 payload\n' > "$WORK/source/docs/ReleaseNotes.TXT"
tar -cf "$WORK/fixture.tar" -C "$WORK/source" .
_archive_member_matches_search "docs/ReleaseNotes.TXT" "releasenotes"
_archive_member_matches_search "docs/ReleaseNotes.TXT" "DOCS/"
_archive_member_matches_search "docs/ReleaseNotes.TXT" ""
if _archive_member_matches_search "docs/ReleaseNotes.TXT" "missing"; then exit 1; fi
member="$WORK/member.tmp"
_archive_nested_member_to_file "$WORK/fixture.tar" "./docs/ReleaseNotes.TXT" "$member"
[[ "$(cat "$member")" == "Quick Archive v2 payload" ]]
metadata="$(_archive_file_metadata "$member" "Fixture metadata")"
grep -Fq 'Fixture metadata' <<<"$metadata"
grep -Fq 'MIME:' <<<"$metadata"
grep -Fq 'SHA-256:' <<<"$metadata"
preview_seen=''
_preview_file() { preview_seen="$1"; [[ "$1" == *.TXT ]]; }
_archive_preview_staged_file "$member" "docs/ReleaseNotes.TXT"
[[ "$preview_seen" == *.TXT && -L "$preview_seen" || "$preview_seen" == *.TXT ]]
before="$(sha256sum "$WORK/fixture.tar")"
_archive_file_metadata "$WORK/fixture.tar" "Archive metadata" >/dev/null
after="$(sha256sum "$WORK/fixture.tar")"
[[ "$before" == "$after" ]]
echo 'PASS: Quick Archive v2 search, bounded member streaming and metadata.'
