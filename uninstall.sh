#!/usr/bin/env bash
# uninstall.sh — uninstall omnish from XDG paths
#
# Usage:
#   ./uninstall.sh             Interactive confirmation
#   ./uninstall.sh -y          Skip confirmation
#   ./uninstall.sh --dry-run   Show what would be removed

set -uo pipefail

force=0; dry_run=0
while (( $# > 0 )); do
    case "$1" in
        -y|--yes)  force=1 ;;
        --dry-run) dry_run=1 ;;
        -h|--help) sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown option '$1'" >&2; exit 2 ;;
    esac
    shift
done

: "${HOME:?HOME must be set}"
HOME_CANON="$(cd -P -- "$HOME" && pwd -P)" || {
    echo "error: cannot resolve HOME" >&2
    exit 1
}
LOCAL="$(realpath -m -- "$HOME_CANON/.local" 2>/dev/null)" || {
    echo "error: cannot resolve user-local directory" >&2
    exit 1
}
case "$LOCAL" in
    "$HOME_CANON"/*) ;;
    *) echo "error: user-local directory resolves outside HOME; refusing uninstall" >&2
       exit 1 ;;
esac

BIN="$LOCAL/bin/omnish"
SHARE="$LOCAL/share/omnish"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/omnish"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/omnish"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/omnish"

exists_bin=0; exists_share=0
[[ -e "$BIN" || -L "$BIN" ]] && exists_bin=1
[[ -d "$SHARE" && -f "$SHARE/omnish" && -d "$SHARE/lib" ]] && exists_share=1

# Never remove an unrelated binary that merely happens to be named omnish.
if (( exists_bin )) && [[ ! -L "$BIN" ]]; then
    echo "warning: $BIN exists but is not an omnish installation symlink; it will be kept" >&2
    exists_bin=0
elif (( exists_bin )); then
    bin_target=$(readlink -f -- "$BIN" 2>/dev/null || true)
    expected_target=$(readlink -f -- "$SHARE/omnish" 2>/dev/null || true)
    if [[ -z "$bin_target" || "$bin_target" != "$expected_target" ]]; then
        echo "warning: $BIN does not point to this omnish installation; it will be kept" >&2
        exists_bin=0
    fi
fi

if (( ! exists_bin && ! exists_share )); then
    echo "omnish is not installed in $LOCAL"
    exit 0
fi

echo "uninstall plan (user-local: $LOCAL):"
(( exists_bin ))   && echo "  remove: $BIN"
(( exists_share )) && echo "  remove: $SHARE (recursive)"
echo "  keep:   $CACHE  (cache)"
echo "  keep:   $DATA   (trash)"
echo "  keep:   $CONFIG (your configuration)"
echo ""

(( dry_run )) && { echo "(dry-run: no changes)"; exit 0; }

if (( ! force )); then
    read -r -p "Proceed with uninstall? [y/N] " ans </dev/tty
    case "${ans:-n}" in [yY]*) ;; *) echo "cancelled."; exit 0 ;; esac
fi

removed=0; failed=0

if (( exists_bin )); then
    rm -f "$BIN" 2>/dev/null && ((removed++)) || { echo "warn: cannot remove $BIN" >&2; ((failed++)); }
fi
if (( exists_share )); then
    rm -rf "$SHARE" 2>/dev/null && ((removed++)) || { echo "warn: cannot remove $SHARE" >&2; ((failed++)); }
fi

[[ -f "$CACHE/.omnish_d" ]] && rm -f "$CACHE/.omnish_d" 2>/dev/null

if (( failed > 0 )); then
    echo "uninstall incomplete: $removed removed, $failed failed" >&2
    exit 1
fi

echo "uninstalled ($removed path(s) removed)"
echo ""
echo "your data remains in:"
for d in "$CACHE" "$DATA" "$CONFIG"; do
    if [[ -d "$d" ]]; then
        sz=$(du -sh "$d" 2>/dev/null | cut -f1)
        echo "  $d  (${sz:-?})"
    else
        echo "  $d  (absent)"
    fi
done
echo ""
echo "to clean everything:"
echo "  rm -rf \"$CACHE\" \"$DATA\" \"$CONFIG\""

if grep -qE '(^|[^a-zA-Z0-9_])omnish[[:space:]]*\(\)' "$HOME/.bashrc" 2>/dev/null; then
    echo ""
    echo "note: an omnish() shell wrapper is still defined in ~/.bashrc."
fi