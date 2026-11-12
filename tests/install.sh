#!/usr/bin/env bash
# Installer integration tests: fixed user-local destination and safe upgrades.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

SRC="$WORK/source tree"
HOME_DIR="$WORK/home with spaces"
LOCAL="$HOME_DIR/.local"
mkdir -p -- "$SRC" "$HOME_DIR" "$SRC/lib"
cp -- "$ROOT/install.sh" "$ROOT/omnish" "$SRC/"
cp -R -- "$ROOT/lib/." "$SRC/lib/"

# PREFIX is deliberately ignored: it cannot redirect writes outside ~/.local.
OUTSIDE_PREFIX="$WORK/outside-prefix"
HOME="$HOME_DIR" PREFIX="$OUTSIDE_PREFIX" "$SRC/install.sh"
[[ ! -e "$OUTSIDE_PREFIX" ]] \
    || { printf 'FAIL: PREFIX redirected installation outside HOME\n' >&2; exit 1; }
[[ -L "$LOCAL/bin/omnish" ]]
[[ -x "$LOCAL/bin/omnish" ]]
[[ "$(readlink -- "$LOCAL/bin/omnish")" == "$LOCAL/share/omnish/omnish" ]]
version_before="$("$LOCAL/bin/omnish" --version)"
[[ "$version_before" == *"omnish 3.0.0"* ]]

# A broken source tree must fail before disturbing the working installation.
cp -- "$SRC/omnish" "$WORK/known-good-omnish"
printf '#!/usr/bin/env bash\nif then\n' > "$SRC/omnish"
if HOME="$HOME_DIR" "$SRC/install.sh" >"$WORK/bad-install.log" 2>&1; then
    printf 'FAIL: installer accepted an invalid entrypoint\n' >&2
    exit 1
fi
cmp -s -- "$WORK/known-good-omnish" "$LOCAL/share/omnish/omnish" \
    || { printf 'FAIL: failed upgrade damaged the active installation\n' >&2; exit 1; }
[[ "$("$LOCAL/bin/omnish" --version)" == "$version_before" ]] \
    || { printf 'FAIL: failed upgrade changed the active launcher\n' >&2; exit 1; }

# A valid upgrade must replace the application tree without stale staging files.
cp -- "$WORK/known-good-omnish" "$SRC/omnish"
sed 's/OMNISH_VERSION="3.0.0"/OMNISH_VERSION="9.9.9"/' \
    "$SRC/omnish" > "$WORK/omnish-new"
mv -- "$WORK/omnish-new" "$SRC/omnish"
HOME="$HOME_DIR" PREFIX="$OUTSIDE_PREFIX" "$SRC/install.sh"
[[ "$("$LOCAL/bin/omnish" --version)" == *"omnish 9.9.9"* ]]
leftovers="$(find "$LOCAL/share" -maxdepth 1 \( -name '.omnish.stage.*' -o -name '.omnish.backup.*' \) -print -quit)"
[[ -z "$leftovers" ]] \
    || { printf 'FAIL: installer left transaction directories behind: %s\n' "$leftovers" >&2; exit 1; }

printf 'PASS: fixed user-local install, ignored PREFIX, failed-upgrade safety and upgrade\n'
