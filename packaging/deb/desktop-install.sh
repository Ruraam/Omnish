#!/usr/bin/env bash
# Install Omnish's desktop entry and SVG icon for the invoking user.
set -Eeuo pipefail

die() { printf 'omnish: desktop integration: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -ne 0 ]] || die "run this command as your regular user, not through sudo"
: "${HOME:?HOME must be set}"

APP="$HOME/.local/bin/omnish"
[[ -x "$APP" ]] || die "user-local Omnish launcher not found at $APP"

SELF_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ICON_SOURCE="$SELF_DIR/../../assets/omnish-icon.svg"
[[ -r "$ICON_SOURCE" ]] || die "SVG icon is missing: $ICON_SOURCE"

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APPS_DIR="$DATA_HOME/applications"
ICON_DIR="$DATA_HOME/icons/hicolor/scalable/apps"
mkdir -p -- "$APPS_DIR" "$ICON_DIR" || die "cannot create XDG application directories"

# Desktop Exec values use double-quoted arguments; escape desktop-entry syntax.
escape_exec() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '%s' "$value"
}

APP_ESCAPED="$(escape_exec "$APP")"
TMP_ICON="$(mktemp "$ICON_DIR/.omnish.svg.XXXXXX")" || die "cannot stage icon"
TMP_DESKTOP="$(mktemp "$APPS_DIR/.omnish.desktop.XXXXXX")" || {
    rm -f -- "$TMP_ICON"
    die "cannot stage desktop entry"
}
cleanup() { rm -f -- "$TMP_ICON" "$TMP_DESKTOP"; }
trap cleanup EXIT

install -m 0644 -- "$ICON_SOURCE" "$TMP_ICON" || die "cannot install SVG icon"
cat >"$TMP_DESKTOP" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Omnish
GenericName=Terminal File Manager
Comment=Modular terminal file manager and system console
TryExec="$APP_ESCAPED"
Exec="$APP_ESCAPED"
Icon=omnish
Terminal=true
Categories=Utility;FileManager;
Keywords=files;manager;terminal;console;
StartupNotify=false
EOF
chmod 0644 -- "$TMP_DESKTOP"
mv -f -- "$TMP_ICON" "$ICON_DIR/omnish.svg" || die "cannot activate SVG icon"
mv -f -- "$TMP_DESKTOP" "$APPS_DIR/omnish.desktop" || die "cannot activate desktop entry"

printf 'omnish: desktop entry installed: %s/omnish.desktop\n' "$APPS_DIR"
