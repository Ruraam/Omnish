#!/usr/bin/env bash
# End-to-end test of the Debian bootstrap and per-user install/uninstall flow.
set -Eeuo pipefail

PACKAGE="${1:-}"
[[ -f "$PACKAGE" ]] || { echo "usage: $0 PACKAGE.deb" >&2; exit 2; }
PACKAGE="$(cd -P -- "$(dirname -- "$PACKAGE")" && pwd -P)/$(basename -- "$PACKAGE")"

for command in dpkg dpkg-deb sudo mktemp grep; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'error: required command not found: %s\n' "$command" >&2
        exit 1
    }
done

[[ "$(dpkg-deb --field "$PACKAGE" Package)" == "omnish" ]] || {
    echo "error: package is not named omnish" >&2
    exit 1
}
dpkg-deb --info "$PACKAGE" >/dev/null
dpkg-deb --contents "$PACKAGE" >/dev/null

WORK="$(mktemp -d)"
HOME_TEST="$WORK/home"
mkdir -p -- "$HOME_TEST"
installed=0
cleanup() {
    local rc=$?
    trap - EXIT
    if (( installed )); then
        sudo dpkg --remove omnish >/dev/null 2>&1 || true
    fi
    rm -rf -- "$WORK"
    exit "$rc"
}
trap cleanup EXIT

sudo dpkg --install "$PACKAGE"
installed=1

HOME="$HOME_TEST" XDG_DATA_HOME="$HOME_TEST/.local/share" /usr/bin/omnish-install
test -L "$HOME_TEST/.local/bin/omnish"
test -f "$HOME_TEST/.local/share/omnish/omnish"
test -f "$HOME_TEST/.local/share/applications/omnish.desktop"
test -f "$HOME_TEST/.local/share/icons/hicolor/scalable/apps/omnish.svg"
grep -Fq '# >>> omnish PATH >>>' "$HOME_TEST/.bashrc"
grep -Fq "Exec=\"$HOME_TEST/.local/bin/omnish\"" "$HOME_TEST/.local/share/applications/omnish.desktop"

version_output="$(HOME="$HOME_TEST" OMNISH_BACKEND=loop "$HOME_TEST/.local/bin/omnish" --version)"
printf '%s\n' "$version_output"
grep -Fq 'omnish ' <<<"$version_output"

HOME="$HOME_TEST" XDG_DATA_HOME="$HOME_TEST/.local/share" /usr/bin/omnish-uninstall --yes
test ! -e "$HOME_TEST/.local/bin/omnish"
test ! -e "$HOME_TEST/.local/share/omnish/omnish"
test ! -e "$HOME_TEST/.local/share/applications/omnish.desktop"
test ! -e "$HOME_TEST/.local/share/icons/hicolor/scalable/apps/omnish.svg"
! grep -Fq '# >>> omnish PATH >>>' "$HOME_TEST/.bashrc"

printf 'Debian package install, desktop integration and uninstall: OK\n'
