#!/usr/bin/env bash
# Remove only Omnish's per-user desktop entry and icon.
set -Eeuo pipefail

[[ "$(id -u)" -ne 0 ]] || {
    printf 'omnish: desktop integration: run as your regular user, not through sudo\n' >&2
    exit 1
}
: "${HOME:?HOME must be set}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
rm -f -- "$DATA_HOME/applications/omnish.desktop" \
          "$DATA_HOME/icons/hicolor/scalable/apps/omnish.svg"
rmdir --ignore-fail-on-non-empty -- "$DATA_HOME/applications" \
    "$DATA_HOME/icons/hicolor/scalable/apps" \
    "$DATA_HOME/icons/hicolor/scalable" \
    "$DATA_HOME/icons/hicolor" \
    "$DATA_HOME/icons" 2>/dev/null || true
printf 'omnish: per-user desktop entry and icon removed\n'
