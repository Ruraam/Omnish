#!/usr/bin/env bash
# Installer integration tests: fresh install, failed upgrade, successful upgrade.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

SRC="$WORK/source tree"
HOME_DIR="$WORK/home"
PREFIX="$WORK/prefix with spaces"
mkdir -p -- "$SRC" "$HOME_DIR" "$SRC/lib"
cp -- "$ROOT/install.sh" "$ROOT/omnish" "$SRC/"
cp -R -- "$ROOT/lib/." "$SRC/lib/"

# Fresh install must support paths containing spaces and create a working link.
HOME="$HOME_DIR" PREFIX="$PREFIX" "$SRC/install.sh"
[[ -L "$PREFIX/bin/omnish" ]]
[[ -x "$PREFIX/bin/omnish" ]]
[[ "$(readlink -- "$PREFIX/bin/omnish")" == "$PREFIX/share/omnish/omnish" ]]
version_before="$("$PREFIX/bin/omnish" --version)"
[[ "$version_before" == *"omnish 3.0.0"* ]]

# A broken source tree must fail before disturbing the working installation.
cp -- "$SRC/omnish" "$WORK/known-good-omnish"
printf '#!/usr/bin/env bash\nif then\n' > "$SRC/omnish"
if HOME="$HOME_DIR" PREFIX="$PREFIX" "$SRC/install.sh" >"$WORK/bad-install.log" 2>&1; then
    printf 'FAIL: installer accepted an invalid entrypoint\n' >&2
    exit 1
fi
cmp -s -- "$WORK/known-good-omnish" "$PREFIX/share/omnish/omnish" \
    || { printf 'FAIL: failed upgrade damaged the active installation\n' >&2; exit 1; }
[[ "$("$PREFIX/bin/omnish" --version)" == "$version_before" ]] \
    || { printf 'FAIL: failed upgrade changed the active launcher\n' >&2; exit 1; }

# A valid upgrade must replace the application tree without stale staging files.
cp -- "$WORK/known-good-omnish" "$SRC/omnish"
sed 's/OMNISH_VERSION="3.0.0"/OMNISH_VERSION="9.9.9"/' \
    "$SRC/omnish" > "$WORK/omnish-new"
mv -- "$WORK/omnish-new" "$SRC/omnish"
HOME="$HOME_DIR" PREFIX="$PREFIX" "$SRC/install.sh"
[[ "$("$PREFIX/bin/omnish" --version)" == *"omnish 9.9.9"* ]]
leftovers="$(find "$PREFIX/share" -maxdepth 1 \( -name '.omnish.stage.*' -o -name '.omnish.backup.*' \) -print -quit)"
[[ -z "$leftovers" ]] \
    || { printf 'FAIL: installer left transaction directories behind: %s\n' "$leftovers" >&2; exit 1; }

printf 'PASS: installer fresh install, failed-upgrade safety and upgrade\n'
