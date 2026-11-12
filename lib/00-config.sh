# omnish — configuration and environment
# Sourced first. Everything else can rely on these.

[[ -n "${OMNISH_CONFIG_LOADED:-}" ]] && return
OMNISH_CONFIG_LOADED=1

SCRIPT="omnish"

# Per-process runtime directory, exported so child actions share UI state.
if [[ -n "${OMNISH_RUNTIME_DIR:-}" ]]; then
    # A caller-supplied runtime directory is caller-owned. Omnish must never
    # recursively remove it during cleanup, even if it created it on demand.
    TMP_OMNISH_DIR="$OMNISH_RUNTIME_DIR"
    [[ -d "$TMP_OMNISH_DIR" ]] || mkdir -p -- "$TMP_OMNISH_DIR" 2>/dev/null
    OMNISH_RUNTIME_OWNED=0
else
    _omnish_runtime_base="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
    if [[ ! -d "$_omnish_runtime_base" || ! -w "$_omnish_runtime_base" ]]; then
        _omnish_runtime_base="${TMPDIR:-/tmp}"
    fi
    TMP_OMNISH_DIR="$(mktemp -d "${_omnish_runtime_base%/}/omnish.XXXXXX" 2>/dev/null || true)"
    if [[ -z "$TMP_OMNISH_DIR" && "$_omnish_runtime_base" != "/tmp" ]]; then
        TMP_OMNISH_DIR="$(mktemp -d /tmp/omnish.XXXXXX 2>/dev/null || true)"
    fi
    if [[ -z "$TMP_OMNISH_DIR" ]]; then
        printf 'omnish: unable to create runtime directory\n' >&2
        return 1
    fi
    OMNISH_RUNTIME_DIR="$TMP_OMNISH_DIR"
    OMNISH_RUNTIME_OWNED=1
    export OMNISH_RUNTIME_DIR
fi
export OMNISH_RUNTIME_OWNED
chmod 700 -- "$TMP_OMNISH_DIR" 2>/dev/null || true

CACHE_OMNISH_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/omnish"
CONFIG_OMNISH_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omnish"
mkdir -p -- "$CACHE_OMNISH_DIR" "$CONFIG_OMNISH_DIR" 2>/dev/null

# --- Persistent state ---
MARGIN_PREVIEW_FILE="$CACHE_OMNISH_DIR/margin_preview"
MARGIN_PREVIEW="$MARGIN_PREVIEW_FILE"
MARKED_FILES_FILE="$TMP_OMNISH_DIR/marked_files"
HISTORY_FILE="$CACHE_OMNISH_DIR/dir_history"
OMNI_CD_FILE="$CACHE_OMNISH_DIR/.omnish_d"

[[ -f "$MARGIN_PREVIEW_FILE" ]] || echo 60 > "$MARGIN_PREVIEW_FILE" 2>/dev/null
touch "$MARKED_FILES_FILE" 2>/dev/null

marked_files=()
all_files=()

# --- Defaults (overridable via config) ---
OMNI_CD_ON_EXIT="${OMNI_CD_ON_EXIT:-1}"
OMNI_USE_TRASH="${OMNI_USE_TRASH:-1}"
OMNI_OPENER="${OMNI_OPENER:-}"
OMNI_TRASH="${OMNI_TRASH:-${XDG_DATA_HOME:-$HOME/.local/share}/omnish/trash}"

# --- Colors ---
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

# --- Entrypoint path ---
# This module is sourced, so BASH_SOURCE[0] would point to this file.
SCRIPT_PATH="${OMNISH_ENTRYPOINT:-}"
[[ -n "$SCRIPT_PATH" ]] || SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || printf '%s' "$0")"
preview_cmd="bash \"$SCRIPT_PATH\" --preview-file {}"

# --- Load user config ---
CONFIG_FILE="$CONFIG_OMNISH_DIR/omnish.conf"
if [[ -r "$CONFIG_FILE" ]]; then
    if ! source "$CONFIG_FILE" 2>/dev/null; then
        printf 'omnish: error sourcing %s (see %s/debug.log)\n' \
            "$CONFIG_FILE" "$TMP_OMNISH_DIR" >/dev/tty 2>/dev/null ||:
    fi
fi

# --- Post-config fixups ---
# Backward compatibility: the documented MARGIN_PREVIEW=60 setting is a
# width value, while older internals used MARGIN_PREVIEW as a cache-file path.
if [[ "$MARGIN_PREVIEW" != "$MARGIN_PREVIEW_FILE" ]]; then
    if [[ "$MARGIN_PREVIEW" =~ ^[0-9]+%?$ ]]; then
        OMNISH_PREVIEW_WIDTH="$MARGIN_PREVIEW"
    else
        MARGIN_PREVIEW_FILE="$MARGIN_PREVIEW"
    fi
fi
MARGIN_PREVIEW="$MARGIN_PREVIEW_FILE"
# A pristine cache value of 60 is the historical default, not a
# user override: let each backend choose its responsive layout. Preserve
# custom cached widths and explicit environment/config overrides.
if [[ -z "${OMNISH_PREVIEW_WIDTH:-}" ]]; then
    _omnish_cached_preview_width=$(cat "$MARGIN_PREVIEW_FILE" 2>/dev/null || true)
    [[ "$_omnish_cached_preview_width" == "60" ]] || OMNISH_PREVIEW_WIDTH="$_omnish_cached_preview_width"
fi
[[ "${OMNISH_PREVIEW_WIDTH:-}" =~ ^[0-9]+%?$ ]] || OMNISH_PREVIEW_WIDTH=''
export TMP_OMNISH_DIR CACHE_OMNISH_DIR CONFIG_OMNISH_DIR MARKED_FILES_FILE
[[ -d "$OMNI_TRASH" ]] || mkdir -p "$OMNI_TRASH" 2>/dev/null
PREVIEW_OPENER="$OMNI_OPENER"