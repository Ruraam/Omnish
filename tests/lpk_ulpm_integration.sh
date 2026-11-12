#!/usr/bin/env bash
# Build a genuine signed LPK with ULPM, then exercise Omnish's real unsquashfs
# read-only browsing path. This complements the fast fake-unsquashfs regression.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ULPM_SOURCE_DIR="${1:-$ROOT/../ulpm}"
[[ -x "$ULPM_SOURCE_DIR/bin/ulpm" && -d "$ULPM_SOURCE_DIR/lib" ]] || {
    printf 'ULPM source tree not found: %s\n' "$ULPM_SOURCE_DIR" >&2
    exit 2
}

for tool in mksquashfs unsquashfs zstd jq openssl file; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'Missing integration-test dependency: %s\n' "$tool" >&2
        exit 2
    }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/omnish-ulpm-lpk.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

export HOME="$WORK/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_STATE_HOME="$HOME/.local/state"
export ULPM_LIB_DIR="$ULPM_SOURCE_DIR/lib"
export NO_COLOR=1
mkdir -p -- "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

STAGE="$WORK/stage"
LPK="$WORK/omnish-integration.lpk"
mkdir -p -- "$STAGE/meta" "$STAGE/bin"
cat > "$STAGE/meta/manifest.json" <<'EOF_MANIFEST'
{
  "format_version": 5,
  "id": "io.omnish.integration",
  "name": "omnish-integration",
  "version": "1.2.3",
  "arch": "all",
  "exec": "bin/demo",
  "permissions": {
    "network": false,
    "audio": false,
    "gui": false,
    "gpu": false
  }
}
EOF_MANIFEST
cat > "$STAGE/bin/demo" <<'EOF_APP'
#!/bin/sh
printf 'real ULPM LPK integration fixture\n'
EOF_APP
chmod 0755 "$STAGE/bin/demo"

# Use ULPM's actual pack/sign implementation; this creates a real zstd
# SquashFS image and the 104-byte Ed25519 ULPM_SIG trailer.
"$ULPM_SOURCE_DIR/bin/ulpm" pack --no-scan "$STAGE" omnish-integration "$LPK" 1.2.3
[[ -s "$LPK" ]] || { echo "ULPM did not create the LPK fixture" >&2; exit 1; }
[[ "$(head -c 4 -- "$LPK")" == hsqs ]] || { echo "LPK is not a SquashFS image" >&2; exit 1; }
[[ "$(tail -c 104 -- "$LPK" | head -c 8)" == ULPM_SIG ]] || {
    echo "ULPM signature trailer is missing" >&2
    exit 1
}
export TMP_OMNISH_DIR="$WORK/omnish-tmp"
mkdir -p -- "$TMP_OMNISH_DIR"
status_msg() { :; }
source "$ROOT/lib/55-archive.sh"

[[ "$(_archive_kind "$LPK")" == lpk ]] || { echo "Omnish did not detect native LPK" >&2; exit 1; }
BEFORE="$WORK/lpk.before"
cp -- "$LPK" "$BEFORE"

INDEX="$(_archive_lpk_list "$LPK")"
grep -Fxq 'meta/manifest.json' <<< "$INDEX" || {
    printf 'Manifest missing from real LPK listing:\n%s\n' "$INDEX" >&2
    exit 1
}
grep -Fxq 'bin/demo' <<< "$INDEX" || {
    printf 'Executable missing from real LPK listing:\n%s\n' "$INDEX" >&2
    exit 1
}

MANIFEST="$(_archive_lpk_stream_member "$LPK" 'meta/manifest.json')"
grep -Fq '"id": "io.omnish.integration"' <<< "$MANIFEST" || {
    echo "Omnish failed to stream the real LPK manifest" >&2
    exit 1
}
APP="$(_archive_lpk_stream_member "$LPK" 'bin/demo')"
grep -Fq 'real ULPM LPK integration fixture' <<< "$APP" || {
    echo "Omnish failed to stream the real LPK executable" >&2
    exit 1
}

cmp -s -- "$LPK" "$BEFORE" || {
    echo "Omnish modified the original signed LPK" >&2
    exit 1
}

printf 'PASS: ULPM generated a real signed zstd SquashFS LPK; Omnish listed and streamed members without modifying it.\n'
