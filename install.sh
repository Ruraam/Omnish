#!/usr/bin/env bash
# install.sh — transactional, unprivileged-by-default Omnish installer.
#
# Usage:
#   ./install.sh
#   PREFIX=/usr/local ./install.sh
#
# PREFIX defaults to $HOME/.local. No sudo is needed for a user install.

set -Eeuo pipefail

_log()  { printf 'omnish: %s\n' "$*"; }
_die()  { printf 'omnish: error: %s\n' "$*" >&2; exit 1; }

# Resolve the source tree without depending on GNU readlink -f.
SELF="${BASH_SOURCE[0]}"
case "$SELF" in
    */*) ;;
    *) SELF="$(command -v -- "$SELF" 2>/dev/null || printf '%s' "$SELF")" ;;
esac
while [[ -L "$SELF" ]]; do
    _source_dir="$(cd -P -- "$(dirname -- "$SELF")" >/dev/null 2>&1 && pwd -P)" \
        || _die "cannot resolve installer directory"
    _source_link="$(readlink -- "$SELF")" || _die "cannot read installer symlink"
    [[ "$_source_link" == /* ]] && SELF="$_source_link" || SELF="$_source_dir/$_source_link"
done
ROOT="$(cd -P -- "$(dirname -- "$SELF")" >/dev/null 2>&1 && pwd -P)" \
    || _die "cannot resolve source directory"

[[ -d "$ROOT/lib" ]] || _die "source directory is missing lib/: $ROOT"
[[ -f "$ROOT/omnish" && -r "$ROOT/omnish" ]] || _die "source directory is missing readable omnish"

: "${HOME:?HOME must be set}"
PREFIX="${PREFIX:-$HOME/.local}"
[[ -n "$PREFIX" && "$PREFIX" != "/" ]] || _die "refusing unsafe PREFIX='$PREFIX'"

# Create and canonicalize the prefix once; all transaction paths then share
# one filesystem, allowing rename(2)-based activation and rollback.
mkdir -p -- "$PREFIX/bin" "$PREFIX/share" || _die "cannot create PREFIX directories: $PREFIX"
PREFIX="$(cd -P -- "$PREFIX" && pwd -P)" || _die "cannot resolve PREFIX"
BIN="$PREFIX/bin"
SHARE="$PREFIX/share/omnish"

# Never replace a directory (including a symlink to a directory) with a file.
if [[ -d "$BIN/omnish" ]]; then
    _die "$BIN/omnish is a directory; move it aside before installing"
fi

stage=""
backup_share=""
backup_bin=""
link_tmp=""
share_backed_up=0
share_activated=0
bin_backed_up=0
bin_activated=0
committed=0

_cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP

    if (( ! committed )); then
        if (( bin_activated )); then
            rm -f -- "$BIN/omnish" || _log "warning: could not remove failed launcher"
        fi
        if (( bin_backed_up )) && [[ -e "$backup_bin" || -L "$backup_bin" ]]; then
            mv -- "$backup_bin" "$BIN/omnish" \
                || _log "ROLLBACK FAILED: previous launcher remains at $backup_bin"
        fi

        if (( share_activated )); then
            rm -rf -- "$SHARE" || _log "warning: could not remove failed installation tree"
        fi
        if (( share_backed_up )) && [[ -e "$backup_share" || -L "$backup_share" ]]; then
            mv -- "$backup_share" "$SHARE" \
                || _log "ROLLBACK FAILED: previous installation remains at $backup_share"
        fi
    fi

    [[ -n "$link_tmp" && ( -e "$link_tmp" || -L "$link_tmp" ) ]] && rm -f -- "$link_tmp"
    [[ -n "$stage" && -d "$stage" ]] && rm -rf -- "$stage"

    if (( committed )); then
        [[ -n "$backup_bin" && ( -e "$backup_bin" || -L "$backup_bin" ) ]] && rm -f -- "$backup_bin"
        [[ -n "$backup_share" && -d "$backup_share" ]] && rm -rf -- "$backup_share"
    fi
    exit "$rc"
}
trap _cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# Build on the destination filesystem so activation is a same-filesystem rename.
stage="$(mktemp -d "$PREFIX/share/.omnish.stage.XXXXXX")" \
    || _die "cannot create staging directory under $PREFIX/share"
mkdir -p -- "$stage/lib"

cp -R -- "$ROOT/lib/." "$stage/lib/" || _die "failed to stage lib/"
if [[ -d "$ROOT/share" ]]; then
    mkdir -p -- "$stage/share"
    cp -R -- "$ROOT/share/." "$stage/share/" || _die "failed to stage share/"
fi
if [[ -d "$ROOT/vendor" ]]; then
    mkdir -p -- "$stage/vendor"
    cp -R -- "$ROOT/vendor/." "$stage/vendor/" || _die "failed to stage vendor/"
fi
cp -- "$ROOT/omnish" "$stage/omnish" || _die "failed to stage omnish"
chmod 755 -- "$stage/omnish" || _die "cannot make staged omnish executable"

# Validate before touching the current installation.
bash -n "$stage/omnish" || _die "syntax check failed: omnish"
module_count=0
for mod in "$stage/lib"/*.sh; do
    [[ -f "$mod" ]] || continue
    bash -n "$mod" || _die "syntax check failed: ${mod##*/}"
    ((module_count += 1))
done
(( module_count > 0 )) || _die "no shell modules found in lib/"

# Prepare a temporary launcher before swapping either live path.
link_tmp="$(mktemp "$BIN/.omnish.link.XXXXXX")" || _die "cannot create temporary launcher"
rm -f -- "$link_tmp"
ln -s -- "$SHARE/omnish" "$link_tmp" || _die "cannot prepare launcher symlink"

# Keep rollback copies until both the application tree and launcher are live.
if [[ -e "$SHARE" || -L "$SHARE" ]]; then
    backup_share="$(mktemp -d "$PREFIX/share/.omnish.backup.XXXXXX")" \
        || _die "cannot create installation backup path"
    rmdir -- "$backup_share"
    mv -- "$SHARE" "$backup_share" || _die "cannot back up current installation"
    share_backed_up=1
fi

mv -- "$stage" "$SHARE" || _die "cannot activate staged installation"
stage=""
share_activated=1

if [[ -e "$BIN/omnish" || -L "$BIN/omnish" ]]; then
    backup_bin="$(mktemp "$BIN/.omnish.previous.XXXXXX")" \
        || _die "cannot create launcher backup path"
    rm -f -- "$backup_bin"
    mv -- "$BIN/omnish" "$backup_bin" || _die "cannot back up current launcher"
    bin_backed_up=1
fi

mv -f -- "$link_tmp" "$BIN/omnish" || _die "cannot activate launcher symlink"
link_tmp=""
bin_activated=1

# Verify the installed paths, not just the staging directory.
[[ -x "$BIN/omnish" && -L "$BIN/omnish" ]] || _die "launcher verification failed"
[[ "$(readlink -- "$BIN/omnish")" == "$SHARE/omnish" ]] || _die "launcher points to an unexpected target"
bash -n "$SHARE/omnish" || _die "installed entrypoint failed syntax verification"
for mod in "$SHARE/lib"/*.sh; do
    [[ -f "$mod" ]] || continue
    bash -n "$mod" || _die "installed module failed syntax verification: ${mod##*/}"
done

committed=1
_log "installation completed"
printf '  executable: %s/omnish\n' "$BIN"
printf '  application: %s/\n' "$SHARE"
printf '  config:      %s/omnish/omnish.conf\n' "${XDG_CONFIG_HOME:-$HOME/.config}"

case ":$PATH:" in
    *":$BIN:"*) ;;
    *)
        printf '\nnote: %s is not in PATH. Add this to your shell profile:\n' "$BIN"
        printf '  export PATH="%s:$PATH"\n' "$BIN"
        ;;
esac
printf "\nRun 'omnish --version' to verify.\n"
