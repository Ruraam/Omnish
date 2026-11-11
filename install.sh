#!/usr/bin/env bash
# install.sh — install omnish to XDG paths

set -euo pipefail

SELF="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
ROOT="${SELF%/*}"
[[ "$ROOT" == "$SELF" ]] && ROOT="."
[[ -z "$ROOT" ]] && ROOT="."

[[ -d "$ROOT/lib" ]] || { echo "error: $ROOT/lib not found" >&2; exit 1; }
[[ -f "$ROOT/omnish" ]] || { echo "error: $ROOT/omnish not found" >&2; exit 1; }

PREFIX="${PREFIX:-$HOME/.local}"
BIN="$PREFIX/bin"
SHARE="$PREFIX/share/omnish"

if [[ -e "$BIN/omnish" && ! -L "$BIN/omnish" ]]; then
    echo "warning: $BIN/omnish exists and is not a symlink (will be replaced)" >&2
fi

mkdir -p "$BIN" "${PREFIX}/share"

# Stage the installation first so a failed copy never destroys a working install.
stage="$(mktemp -d "${PREFIX}/share/.omnish.install.XXXXXX")"
cleanup_stage() { rm -rf -- "$stage"; }
trap cleanup_stage EXIT INT TERM

mkdir -p "$stage/lib"
cp -r "$ROOT/lib/." "$stage/lib/"
[[ -d "$ROOT/share"  ]] && { mkdir -p "$stage/share";  cp -r "$ROOT/share/."  "$stage/share/"; }
[[ -d "$ROOT/vendor" ]] && { mkdir -p "$stage/vendor"; cp -r "$ROOT/vendor/." "$stage/vendor/"; }
cp "$ROOT/omnish" "$stage/omnish"
chmod +x "$stage/omnish"

# Validate the staged tree before replacing the current installation.
bash -n "$stage/omnish"
for mod in "$stage/lib"/*.sh; do
    [[ -r "$mod" ]] && bash -n "$mod"
done

# Replace the installed tree transactionally. Keep the previous version
# available until the staged tree has been moved into place successfully.
backup=""
if [[ -e "$SHARE" || -L "$SHARE" ]]; then
    backup="$(mktemp -d "${PREFIX}/share/.omnish.backup.XXXXXX")"
    rmdir -- "$backup"
    if ! mv -- "$SHARE" "$backup"; then
        echo "error: cannot move current installation to backup" >&2
        exit 1
    fi
fi

if ! mv -- "$stage" "$SHARE"; then
    echo "error: cannot activate staged installation" >&2
    if [[ -n "$backup" && -e "$backup" ]]; then
        mv -- "$backup" "$SHARE" || echo "error: rollback failed; backup is at $backup" >&2
    fi
    exit 1
fi

# The new tree is active. Only now discard the previous installation.
[[ -n "$backup" ]] && rm -rf -- "$backup"
trap - EXIT INT TERM
ln -sfn "$SHARE/omnish" "$BIN/omnish"

# Sanity check
_fail=0
bash -n "$SHARE/omnish" 2>/dev/null || { echo "error: syntax in $SHARE/omnish" >&2; _fail=1; }
for mod in "$SHARE/lib"/*.sh; do
    [[ -r "$mod" ]] || continue
    bash -n "$mod" 2>/dev/null || { echo "error: syntax in $mod" >&2; _fail=1; }
done
(( _fail )) && { echo "install aborted" >&2; exit 1; }

echo "installed:"
echo "  $BIN/omnish -> $SHARE/omnish"
echo "  modules:    $SHARE/lib/"
echo "  config:     ${XDG_CONFIG_HOME:-$HOME/.config}/omnish/omnish.conf"

case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo ""; echo "note: $BIN is not in PATH."
       echo "      add: export PATH=\"$BIN:\$PATH\"" ;;
esac

echo ""
echo "run 'omnish --version' to verify."