# omnish — CPU monitor (inspired by s-tui)
# Reads /proc and /sys directly. No sensors, no msr, no psutil.
# Provides:
#   cpu_widget              one-line string (temperature | freq | load)
#   cpu_monitor_view        full-screen monitor (interactive, quit with q)
#   cpu_stress_test [secs]  spawn N `yes` processes, clean kill on exit
#   cpu_hook_check          threshold check (call from the widget periodically)
#
# Config (omnish.conf):
#   CPU_TEMP_THRESHOLD=80       °C threshold for hook + colour
#   CPU_HOOK_SCRIPT=""          path to a script run when threshold is crossed
#   CPU_MONITOR_REFRESH=1       refresh interval (s) in cpu_monitor_view
#   CPU_WIDGET_CACHE_TTL=2      cache widget output for N seconds
#
# [FIX 1] cpu_monitor_view re-installs its INT/TERM trap after stress test.
# [FIX 2] _cpu_hook_check is serialised with flock (no double-fire).
# [FIX 3] _stress_cleanup waits on each known PID, not all jobs.
# [FIX 4] cpu_stress_test validates $1 (falls back to 30).
# [FIX 5] cpu_stress_test exits alt-screen at end (self-contained).
# [FIX 6] _cpu_usage removes dead read, guards /proc/stat.
# [FIX 7] _cpu_temp rounds to 1 decimal correctly.
# [FIX 8] Removed unused variable.
# [FIX 9] _cpu_hook_check creates its state-file dir.
# [FIX 10] cpu_widget caches output (CPU_WIDGET_CACHE_TTL, default 2s).
# [FIX 12] _cpu_temp no longer rejects 5-10°C readings; only < 0 is
#          treated as "bogus" (many sensors report -273000 for "unknown").

CPU_TEMP_THRESHOLD="${CPU_TEMP_THRESHOLD:-80}"
CPU_HOOK_SCRIPT="${CPU_HOOK_SCRIPT:-}"
CPU_MONITOR_REFRESH="${CPU_MONITOR_REFRESH:-1}"
CPU_WIDGET_CACHE_TTL="${CPU_WIDGET_CACHE_TTL:-2}"
CPU_HOOK_STATE_FILE="$TMP_OMNISH_DIR/cpu_hook_active"

# ===============================================================
# Data collection
# ===============================================================
_cpu_temp() {
    local f val max=-1
    for f in /sys/class/thermal/thermal_zone*/temp; do
        [[ -r "$f" ]] || continue
        val=$(<"$f" 2>/dev/null)
        [[ "$val" =~ ^-?[0-9]+$ ]] || continue
        (( val > max )) && max=$val
    done
    # [FIX 12] Only reject clearly-bogus (negative) values.
    # Some kernels expose 0 on idle; we accept it as "0.0°C".
    (( max >= 0 )) || return 1
    # [FIX 7] Round to 1 decimal (45099 → 45.1, not 45.0)
    printf '%d.%d' $(( max / 1000 )) $(( ((max % 1000) + 50) / 100 ))
}

_cpu_freq() {
    local total=0 count=0 f v
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
        [[ -r "$f" ]] || continue
        v=$(<"$f" 2>/dev/null)
        [[ "$v" =~ ^[0-9]+$ ]] || continue
        (( total += v / 1000 ))
        (( count++ ))
    done
    if (( count > 0 )); then
        printf '%d' $(( total / count ))
        return
    fi
    awk -F: '/cpu MHz/ { sum += $2; n++ } END {
        if (n > 0) printf "%d", sum/n
    }' /proc/cpuinfo 2>/dev/null
}

_cpu_usage() {
    # [FIX 6] Guard /proc/stat; remove dead `read -r _ _ ...` line.
    [[ -r /proc/stat ]] || { printf '0'; return; }

    local -a a b
    read -ra a < <(awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8}' /proc/stat 2>/dev/null)
    [[ ${#a[@]} -eq 7 ]] || { printf '0'; return; }

    sleep 0.1

    read -ra b < <(awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8}' /proc/stat 2>/dev/null)
    [[ ${#b[@]} -eq 7 ]] || { printf '0'; return; }

    local i total1=0 total2=0
    for (( i=0; i<7; i++ )); do
        (( total1 += a[i] ))
        (( total2 += b[i] ))
    done
    local dtotal=$(( total2 - total1 ))
    local didle=$(( b[3] - a[3] ))
    (( dtotal > 0 )) || { printf '0'; return; }
    printf '%d' $(( 100 * (dtotal - didle) / dtotal ))
}

_cpu_load() {
    awk '{printf "%s", $1}' /proc/loadavg 2>/dev/null
}

_cpu_nproc() {
    local n
    n=$(nproc 2>/dev/null) || n=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null) || n=1
    printf '%d' "${n:-1}"
}

# ===============================================================
# Colour helper (temperature)
# ===============================================================
_cpu_temp_color() {
    local t="${1:-0}" th="${CPU_TEMP_THRESHOLD:-80}"
    local ti=${t%.*}; ti=${ti:-0}
    if   (( ti >= th ));        then printf '\033[1;31m'
    elif (( ti >= th - 15 ));   then printf '\033[1;33m'
    elif (( ti > 0 ));          then printf '\033[1;32m'
    else                             printf '\033[0;37m'
    fi
}

# ===============================================================
# Threshold hook
# [FIX 2] flock-serialised.
# [FIX 9] mkdir the state-file dir.
# ===============================================================
_cpu_hook_check() {
    local temp="${1:-}" th="${CPU_TEMP_THRESHOLD:-80}"
    [[ -n "$temp" ]] || return
    local ti=${temp%.*}; ti=${ti:-0}

    mkdir -p "${CPU_HOOK_STATE_FILE%/*}" 2>/dev/null

    local lockfile="$TMP_OMNISH_DIR/cpu_hook.lock"
    mkdir -p "${lockfile%/*}" 2>/dev/null

    (
        if command -v flock >/dev/null 2>&1; then
            flock -n 9 || exit 0
        fi

        local was_hot=0
        [[ -f "$CPU_HOOK_STATE_FILE" ]] && was_hot=1

        if (( ti >= th )); then
            if (( was_hot == 0 )); then
                touch "$CPU_HOOK_STATE_FILE" 2>/dev/null
                if [[ -n "$CPU_HOOK_SCRIPT" && -x "$CPU_HOOK_SCRIPT" ]]; then
                    ( "$CPU_HOOK_SCRIPT" "$temp" "$th" ) &>/dev/null &
                fi
            fi
        else
            [[ -f "$CPU_HOOK_STATE_FILE" ]] && rm -f "$CPU_HOOK_STATE_FILE"
        fi
    ) 9>"$lockfile"
}

# ===============================================================
# One-line widget
# [FIX 10] Cache output for CPU_WIDGET_CACHE_TTL seconds.
# ===============================================================
cpu_widget() {
    local cache_file="$TMP_OMNISH_DIR/cpu_widget.cache"
    local now mt age

    if [[ -r "$cache_file" ]]; then
        mt=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)
        now=$(date +%s)
        age=$(( now - mt ))
        if (( age < CPU_WIDGET_CACHE_TTL )); then
            cat "$cache_file" 2>/dev/null
            return
        fi
    fi

    local temp freq usage nproc
    temp=$(_cpu_temp 2>/dev/null)     || temp=""
    freq=$(_cpu_freq 2>/dev/null)     || freq=""
    usage=$(_cpu_usage 2>/dev/null)   || usage="?"
    nproc=$(_cpu_nproc)

    local out=""
    if [[ -n "$temp" ]]; then
        local col reset
        col=$(_cpu_temp_color "$temp")
        reset=$'\033[0m'
        out+="${col}${temp}°C${reset} "
    fi
    [[ -n "$freq" ]] && out+="${freq}MHz "
    out+="CPU:${usage}% (${nproc}c)"

    printf '%s' "$out" > "$cache_file" 2>/dev/null
    printf '%s' "$out"

    _cpu_hook_check "$temp" &
}

# ===============================================================
# Interactive monitor view
# [FIX 1] Re-install INT/TERM trap after the stress test.
# ===============================================================
cpu_monitor_view() {
    local interval="$CPU_MONITOR_REFRESH"
    local stop=0

    printf '\e[?1049h\e[?25l\e[2J'
    stty -echo 2>/dev/null

    _cleanup_cpu_monitor() {
        printf '\e[?25h\e[?1049l'
        stty echo 2>/dev/null
    }
    trap '_cleanup_cpu_monitor; stop=1' INT TERM

    while (( stop == 0 )); do
        get_term_size
        local rows=$(( LINES - 2 ))
        local temp freq usage load nproc
        temp=$(_cpu_temp 2>/dev/null)   || temp="n/a"
        freq=$(_cpu_freq 2>/dev/null)   || freq="n/a"
        usage=$(_cpu_usage 2>/dev/null) || usage="0"
        load=$(_cpu_load 2>/dev/null)   || load="0.00"
        nproc=$(_cpu_nproc)

        printf '\e[1;1H\e[2K\e[1;96m CPU monitor \e[0m  (%s cores)  \e[2m%s\e[0m\n' \
            "$nproc" "$(date +%H:%M:%S)"

        local col reset ti
        col=$(_cpu_temp_color "$temp")
        reset=$'\033[0m'
        printf '\e[2;1H\e[2K Temperature : %s%s°C%s   (threshold: %d°C)\n' \
            "$col" "$temp" "$reset" "$CPU_TEMP_THRESHOLD"

        printf '\e[3;1H\e[2K Frequency   : %s MHz\n' "$freq"

        local bar bar_w=40 filled
        filled=$(( usage * bar_w / 100 ))
        (( filled > bar_w )) && filled=$bar_w
        bar=''
        local i
        for (( i=0; i<filled; i++ )); do bar+='█'; done
        for (( i=filled; i<bar_w; i++ )); do bar+='░'; done
        printf '\e[4;1H\e[2K Usage       : [%s] %3d%%\n' "$bar" "$usage"

        printf '\e[5;1H\e[2K Load avg    : %s\n' "$load"
        printf '\e[6;1H\e[2K\e[2m────────────────────────────────────────\e[0m\n'

        local f v name row=7
        for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
            [[ -r "$f" ]] || continue
            (( row >= rows )) && break
            name="${f#/sys/devices/system/cpu/}"
            name="${name%/cpufreq/*}"
            v=$(<"$f" 2>/dev/null)
            [[ "$v" =~ ^[0-9]+$ ]] || continue
            printf '\e[%d;1H\e[2K %-6s : %d MHz\n' "$row" "$name" $(( v / 1000 ))
            (( row++ ))
        done

        printf '\e[%d;1H\e[2K\e[2m q: quit  s: stress test  r: reset thresholds  \e[0m' "$LINES"

        local key
        IFS= read -rsn 1 -t "$interval" key 2>/dev/null && {
            case "$key" in
                q|Q|$'\e') stop=1 ;;
                s|S)
                    _cleanup_cpu_monitor
                    cpu_stress_test 30
                    # [FIX 1] Re-install the outer trap (stress test overrode it)
                    trap '_cleanup_cpu_monitor; stop=1' INT TERM
                    printf '\e[?1049h\e[?25l\e[2J'
                    stty -echo 2>/dev/null
                    ;;
                r|R)  rm -f "$CPU_HOOK_STATE_FILE" ;;
            esac
        }
    done

    _cleanup_cpu_monitor
    trap - INT TERM
}

# ===============================================================
# Stress test
# [FIX 3] wait per-pid, not global wait.
# [FIX 4] Validate $secs.
# [FIX 5] Restore alt-screen at end (self-contained).
# ===============================================================
cpu_stress_test() {
    local secs="${1:-30}"
    # [FIX 4] Validate secs
    [[ "$secs" =~ ^[0-9]+$ ]] && (( secs > 0 )) || secs=30

    local nproc pids=() i stop_stress=0
    nproc=$(_cpu_nproc)

    # [FIX 3] Wait per-pid, not global
    _stress_cleanup() {
        local p
        for p in "${pids[@]}"; do
            kill "$p" 2>/dev/null
            wait "$p" 2>/dev/null
        done
    }

    trap 'stop_stress=1; _stress_cleanup' INT TERM

    printf '\e[?1049h\e[2J\e[1;96mCPU stress test: %d workers for %d seconds\e[0m\n\n' \
        "$nproc" "$secs"
    printf 'Press Ctrl-C to abort.\n\n'

    for (( i=0; i<nproc; i++ )); do
        yes > /dev/null &
        pids+=($!)
    done

    local elapsed=0 temp
    while (( elapsed < secs && !stop_stress )); do
        sleep 1
        (( elapsed++ ))
        (( stop_stress )) && break
        temp=$(_cpu_temp 2>/dev/null) || temp="n/a"
        printf '\e[4;1H\e[2K elapsed: %2ds / %2ds   temp: %s°C   ' \
            "$elapsed" "$secs" "$temp"
    done

    _stress_cleanup
    trap - INT TERM

    printf '\n\nDone. %d workers killed.\n' "$nproc"
    sleep 1

    # [FIX 5] Self-contained: restore alt-screen
    printf '\e[?1049l'
}