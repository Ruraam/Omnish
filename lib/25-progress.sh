# omnish — progress bars and spinners
# Three modes:
#   progress_time <sec> [label]           — time-based (like original script)
#   progress_begin <total> [label]        — count-based
#   progress_tick [incr] / progress_set <cur> / progress_end
#   spinner_begin [label] / spinner_end   — indeterminate
#
# All render to /dev/tty so they stay visible even when stdout/stderr
# are redirected (e.g. inside $(...) or pipe to fzf).
#
# [FIX 1] Bar strings built with bash loops (0 fork). Previously used
#         $(seq 1 0) which forks twice per render (catastrophic on proot).
# [FIX 2] `printf '▇%.0s' $(seq 1 0)` printed one extra char when filled=0
#         (printf runs the format once with no arg). Loops fix this.
# [FIX 3] avail recalculated after choosing the compact layout (was: bar
#         exceeded COLUMNS in narrow terminals, causing line wrap).
# [FIX 4] Guard LINES/COLUMNS=0 (they map to \e[0H which is unpredictable).
# [FIX 5] Reset labels in progress_end / spinner_end so stale state
#         doesn't leak into the next operation.
# [FIX 6] Clamp pct to 100 in case progress_set receives current>total.
# [FIX 7] progress_tick now handles negative increments safely.
# [FIX 8] spinner_end no longer waits forever if disown is unavailable.

_ff_progress_total=0
_ff_progress_current=0
_ff_progress_label=""
_ff_progress_start_ts=0
_ff_progress_active=0
_ff_spin_pid=""
_ff_spin_label=""

# ------------------------------------------------------------------
# Bar rendering (pure bash, no fork)
# ------------------------------------------------------------------
_ff_bar_filled() {
    # $1 = filled count; prints N '▇' characters
    local n="${1:-0}" s='' i
    (( n < 0 )) && n=0
    for (( i=0; i<n; i++ )); do s+='▇'; done
    printf '%s' "$s"
}

_ff_bar_empty() {
    # $1 = count; prints N spaces
    local n="${1:-0}" s='' i
    (( n < 0 )) && n=0
    for (( i=0; i<n; i++ )); do s+=' '; done
    printf '%s' "$s"
}

# ------------------------------------------------------------------
# Count/time-based renderer
# ------------------------------------------------------------------
_progress_render() {
    (( _ff_progress_active )) || return
    [[ -w /dev/tty ]] || return

    local lines="${LINES:-24}" cols="${COLUMNS:-80}"
    (( lines > 0 )) || lines=24
    (( cols  > 0 )) || cols=80

    local pct=0 filled=0 bar_width avail
    local done_bar rest_bar nums elapsed timestr
    local label

    # [FIX 3] Choose layout first, THEN compute avail for that layout
    local layout
    if   (( cols < 60 )); then layout="min"
    elif (( cols < 90 )); then layout="mid"
    else                       layout="full"
    fi

    case "$layout" in
        min)   avail=$(( cols - 10 - 1 - 2 - 5 )) ;;  # label(10)+sp+[+]+" 100%"
        mid)   avail=$(( cols - 15 - 1 - 2 - 5 - 3 - 12 )) ;;  # + " | NN/NN"
        full)  avail=$(( cols - 20 - 1 - 2 - 5 - 3 - 12 - 3 - 5 )) ;;  # + " | Ns"
    esac
    (( avail < 5 ))  && avail=5
    (( avail > 60 )) && avail=60
    bar_width=$avail

    if (( _ff_progress_total > 0 )); then
        pct=$(( _ff_progress_current * 100 / _ff_progress_total ))
        (( pct > 100 )) && pct=100
        (( pct < 0 ))   && pct=0
        filled=$(( bar_width * _ff_progress_current / _ff_progress_total ))
    fi
    (( filled > bar_width )) && filled=$bar_width
    (( filled < 0 ))         && filled=0

    # [FIX 1] No fork: pure bash string building
    done_bar=$(_ff_bar_filled "$filled")
    rest_bar=$(_ff_bar_empty $(( bar_width - filled )))

    elapsed=$(( SECONDS - _ff_progress_start_ts ))
    (( elapsed < 0 )) && elapsed=0
    timestr="${elapsed}s"

    if (( _ff_progress_total == 100 )); then
        nums="${pct}%"
    else
        nums="${_ff_progress_current}/${_ff_progress_total}"
    fi

    case "$layout" in
        min)
            label="${_ff_progress_label:0:10}"
            printf '\e7\e[%sH\e[2K\e[36m%-10s\e[m [%s%s] %3d%%\e8' \
                "$lines" "$label" "$done_bar" "$rest_bar" "$pct" > /dev/tty
            ;;
        mid)
            label="${_ff_progress_label:0:15}"
            printf '\e7\e[%sH\e[2K\e[36m%-15s\e[m [%s%s] %3d%% | %s\e8' \
                "$lines" "$label" "$done_bar" "$rest_bar" "$pct" "$nums" > /dev/tty
            ;;
        full)
            label="${_ff_progress_label:0:20}"
            printf '\e7\e[%sH\e[2K\e[36m%-20s\e[m [%s%s] %3d%% | %s | %s\e8' \
                "$lines" "$label" "$done_bar" "$rest_bar" "$pct" "$nums" "$timestr" > /dev/tty
            ;;
    esac
}

# ------------------------------------------------------------------
# Count-based API
# ------------------------------------------------------------------
progress_begin() {
    _ff_progress_total="${1:-0}"
    _ff_progress_label="${2:-working}"
    _ff_progress_current=0
    _ff_progress_start_ts=$SECONDS
    _ff_progress_active=1
    _progress_render
}

progress_set() {
    _ff_progress_current="$1"
    (( _ff_progress_current > _ff_progress_total )) && \
        _ff_progress_current=$_ff_progress_total
    (( _ff_progress_current < 0 )) && _ff_progress_current=0
    _progress_render
}

progress_tick() {
    local inc="${1:-1}"
    # [FIX 7] safe with negative increments
    (( inc < 0 )) && inc=0
    _ff_progress_current=$(( _ff_progress_current + inc ))
    (( _ff_progress_current > _ff_progress_total )) && \
        _ff_progress_current=$_ff_progress_total
    _progress_render
}

progress_end() {
    (( _ff_progress_active )) || return
    _ff_progress_active=0
    # [FIX 5] clear stale label
    _ff_progress_label=""
    _ff_progress_current=0
    _ff_progress_total=0
    [[ -w /dev/tty ]] && printf '\e7\e[%sH\e[2K\e8' "${LINES:-24}" > /dev/tty
}

# ------------------------------------------------------------------
# Time-based — faithful to the user's original script
# SLEEP_DURATION can be set to 0.01 for tests
# ------------------------------------------------------------------
progress_time() {
    local duration="${1:-1}"
    local label="${2:-}"
    local sleep_dur="${SLEEP_DURATION:-1}"
    (( duration < 1 )) && duration=1

    progress_begin "$duration" "$label"
    local i
    for (( i=1; i<=duration; i++ )); do
        progress_set "$i"
        [[ "$sleep_dur" == "0" || "$sleep_dur" == "0.0" ]] && continue
        sleep "$sleep_dur"
    done
    progress_end
}

# ------------------------------------------------------------------
# Indeterminate spinner
# ------------------------------------------------------------------
_ff_spin_loop() {
    local frames=( '|' '/' '-' '\' )
    local i=0 lines
    while :; do
        lines="${LINES:-24}"
        (( lines > 0 )) || lines=24
        [[ -w /dev/tty ]] && printf '\e7\e[%sH\e[2K\e[33m%s %s\e8' \
            "$lines" "${_ff_spin_label:0:30}" "${frames[i]}" > /dev/tty
        i=$(( (i+1) % 4 ))
        sleep 0.1
    done
}

spinner_begin() {
    _ff_spin_label="${1:-working}"
    # Kill any previous spinner first
    [[ -n "$_ff_spin_pid" ]] && spinner_end
    _ff_spin_loop &
    _ff_spin_pid=$!
    # [FIX 8] disown may fail on very old bash; ignore it
    disown "$_ff_spin_pid" 2>/dev/null ||:
}

spinner_end() {
    if [[ -n "$_ff_spin_pid" ]]; then
        kill "$_ff_spin_pid" 2>/dev/null
        # [FIX 8] don't wait forever if the child ignores SIGTERM
        wait "$_ff_spin_pid" 2>/dev/null
        _ff_spin_pid=""
    fi
    # [FIX 5] clear stale label
    _ff_spin_label=""
    [[ -w /dev/tty ]] && printf '\e7\e[%sH\e[2K\e8' "${LINES:-24}" > /dev/tty
}

# ------------------------------------------------------------------
# Cleanup hook — called from 10-utils.sh:cleanup()
# ------------------------------------------------------------------
_progress_cleanup() {
    if [[ -n "${_ff_spin_pid:-}" ]]; then
        kill "$_ff_spin_pid" 2>/dev/null
        wait "$_ff_spin_pid" 2>/dev/null
        _ff_spin_pid=""
        _ff_spin_label=""
    fi
    if (( ${_ff_progress_active:-0} )); then
        _ff_progress_active=0
        _ff_progress_label=""
        _ff_progress_current=0
        _ff_progress_total=0
        [[ -w /dev/tty ]] && printf '\e7\e[%sH\e[2K\e8' "${LINES:-24}" > /dev/tty
    fi
}