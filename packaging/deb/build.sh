#!/usr/bin/env bash
# Build a user-local Omnish application bootstrap .deb.
set -Eeuo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
VERSION="${1:-}"
OUT_DIR="${2:-$ROOT/dist}"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+~]?[0-9A-Za-z.-]+)?$ ]] || {
    printf 'usage: %s VERSION [OUTPUT_DIR]\n' "$0" >&2
    exit 2
}
for command in dpkg-deb install cp grep sed; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'error: required command not found: %s\n' "$command" >&2
        exit 1
    }
done

APP_VERSION="$(sed -nE 's/^OMNISH_VERSION="([^"]+)"$/\1/p' "$ROOT/omnish")"
[[ -n "$APP_VERSION" ]] || { echo "error: cannot read OMNISH_VERSION from omnish" >&2; exit 1; }
[[ "$APP_VERSION" == "$VERSION" ]] || {
    printf 'error: release tag version (%s) does not match OMNISH_VERSION (%s)\n' "$VERSION" "$APP_VERSION" >&2
    exit 1
}
[[ -f "$ROOT/assets/omnish-icon.svg" ]] || { echo "error: desktop SVG icon is missing" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
PKG="$WORK/pkg"
install -d "$PKG/DEBIAN" "$PKG/usr/share/omnish-installer" \
    "$PKG/usr/bin" "$PKG/usr/share/doc/omnish"

# The payload is a bootstrap source tree. The actual application is installed
# later by the user-local installer into ~/.local, never by dpkg into a HOME.
cp -a "$ROOT/omnish" "$ROOT/install.sh" "$ROOT/uninstall.sh" "$PKG/usr/share/omnish-installer/"
cp -a "$ROOT/lib" "$ROOT/share" "$ROOT/assets" "$PKG/usr/share/omnish-installer/"
cp -a "$ROOT/packaging/deb/desktop-install.sh" "$ROOT/packaging/deb/desktop-uninstall.sh" "$PKG/usr/share/omnish-installer/"

cat >"$PKG/usr/bin/omnish-install" <<'EOF'
#!/bin/sh
set -eu
if [ "$(id -u)" -eq 0 ]; then
    echo "omnish-install: run as your regular user; do not use sudo." >&2
    exit 1
fi
payload=/usr/share/omnish-installer
/usr/bin/env bash "$payload/install.sh" "$@"
/usr/bin/env bash "$payload/desktop-install.sh"
EOF

cat >"$PKG/usr/bin/omnish-uninstall" <<'EOF'
#!/bin/sh
set -eu
if [ "$(id -u)" -eq 0 ]; then
    echo "omnish-uninstall: run as your regular user; do not use sudo." >&2
    exit 1
fi
payload=/usr/share/omnish-installer
/usr/bin/env bash "$payload/uninstall.sh" "$@"
/usr/bin/env bash "$payload/desktop-uninstall.sh"
EOF
chmod 0755 "$PKG/usr/bin/omnish-install" "$PKG/usr/bin/omnish-uninstall"

cat >"$PKG/DEBIAN/control" <<EOF
Package: omnish
Version: $VERSION
Section: utils
Priority: optional
Architecture: all
Maintainer: Omnish contributors <noreply@github.com>
Homepage: https://github.com/Ruraam/Omnish
Depends: bash, coreutils, findutils, grep, mawk, sed
Description: modular terminal file manager and system console
 Omnish is a modular Bash file manager with fzf and minimal loop backends,
 archive browsing, local file transfer and a system console.
 .
 This package installs a small system-wide bootstrap. Run omnish-install
 as your regular user to install the application into ~/.local and add
 a per-user desktop entry and SVG icon. The application itself is not
 installed system-wide and no root post-install script touches a HOME.
EOF

cat >"$PKG/usr/share/doc/omnish/README.Debian" <<'EOF'
Omnish uses a user-local runtime installation.

1. Install this bootstrap package with your Debian package manager.
2. As your regular user (without sudo), run: omnish-install
3. Launch Omnish from your desktop application menu or ~/.local/bin/omnish.

To remove the user-local application and its desktop entry, run
omnish-uninstall as that same user. Then remove this bootstrap package
with apt or dpkg if desired.

The dpkg package manager cannot safely choose a target HOME for a
multi-user application. Therefore no maintainer script installs files
into /root or guesses which desktop user should receive the application.
EOF

mkdir -p -- "$OUT_DIR"
OUT="$OUT_DIR/omnish_${VERSION}_all.deb"
dpkg-deb --build --root-owner-group "$PKG" "$OUT" >/dev/null
dpkg-deb --info "$OUT" >/dev/null
printf 'Built package: %s\n' "$OUT"
