# omnish — system management panel
# Inspired by Linux-TUI-Management (Robin Deblauwe) and kmon (orhun).
# Uses fzf as the menu engine (no dialog dependency).
# Detects ulpm/apt/yum, bubble/systemctl, and kernel module tools at runtime.
#
# [FIX 1] All external commands run via `_sys_show`/`_sys_run` which pass
#         args directly (no `bash -c`). No shell-injection on $pkg/$svc/$name.
# [FIX 2] `_sys_show`/`_sys_show_file`/`_sys_run` use `--ansi`.
# [FIX 3] `_sys_sudo` helper checks sudo availability before use.
# [FIX 4] `_sys_ping` checks for `ping` binary.
# [FIX 5] `gens`/`rollback` menu entries hidden when `_SYS_BUBBLE=0`.
# [FIX 6] `_sys_exec` `read` is bounded (`-t 30`) and reads from /dev/tty.
# [FIX 7] `stop`/`restart`/`disable` service actions require confirmation.
# [FIX 8] `_sys_bubble_rollback` validates the generation id.
# [FIX 9] `cpu_widget` cached for the duration of one menu redraw.
# [FIX 10] `_sys_run` shows the last 100 lines (better for installs/updates).

# ===============================================================
# Environment detection (cached)
# ===============================================================
_sys_detect() {
    [[ -n "${_SYS_DETECTED:-}" ]] && return

    _SYS_PKG=""
    _SYS_INIT=""
    _SYS_BUBBLE=0
    _SYS_IS_ROOT=0
    _SYS_HAS_SUDO=0
    _SYS_HAS_LSMOD=0
    _SYS_HAS_MODPROBE=0
    _SYS_HAS_MODINFO=0
    _SYS_HAS_DMESG=0
    _SYS_HAS_PING=0

    command -v ulpm   >/dev/null 2>&1 && _SYS_PKG=ulpm
    [[ -z "$_SYS_PKG" ]] && command -v apt  >/dev/null 2>&1 && _SYS_PKG=apt
    [[ -z "$_SYS_PKG" ]] && command -v dnf  >/dev/null 2>&1 && _SYS_PKG=dnf
    [[ -z "$_SYS_PKG" ]] && command -v yum  >/dev/null 2>&1 && _SYS_PKG=yum

    command -v systemctl >/dev/null 2>&1 && _SYS_INIT=systemd
    [[ -z "$_SYS_INIT" ]] && command -v rc-service >/dev/null 2>&1 && _SYS_INIT=openrc

    command -v bubble >/dev/null 2>&1 && _SYS_BUBBLE=1

    (( EUID == 0 )) && _SYS_IS_ROOT=1
    command -v sudo >/dev/null 2>&1 && _SYS_HAS_SUDO=1

    command -v lsmod    >/dev/null 2>&1 && _SYS_HAS_LSMOD=1
    command -v modprobe >/dev/null 2>&1 && _SYS_HAS_MODPROBE=1
    command -v modinfo  >/dev/null 2>&1 && _SYS_HAS_MODINFO=1
    command -v dmesg    >/dev/null 2>&1 && _SYS_HAS_DMESG=1
    command -v ping     >/dev/null 2>&1 && _SYS_HAS_PING=1

    _SYS_DETECTED=1
}

# ===============================================================
# Display helpers
# ===============================================================
_sys_display_text() {
    local title="$1" body="$2"
    [[ -n "$body" ]] || body="$title: (no output)"

    if [[ "${OMNISH_BACKEND:-fzf}" != "fzf" ]] || ! command -v fzf >/dev/null 2>&1; then
        if command -v less >/dev/null 2>&1; then
            printf '%s\n' "$body" | less -R
        else
            printf '%s\n' "$body"
            read -rsn 1 -t 30 _ </dev/tty 2>/dev/null || true
        fi
        return 0
    fi

    printf '%s\n' "$body" | fzf --ansi --no-sort --no-info \
        --header "$title | Esc: back" \
        --preview-window 'hidden' \
        --bind 'enter:accept' >/dev/null
}

_sys_show() {
    # $1 = title; rest = command. Shows first 500 lines (for lists).
    local title="$1"; shift
    local out
    out=$("$@" 2>&1 | head -500)
    _sys_display_text "$title" "$out"
}

_sys_show_file() {
    _sys_display_text "$1" "$2"
}

_sys_run() {
    # $1 = title; rest = command. Preserve the real command's exit status.
    local title="$1"; shift
    local out rc
    if out=$("$@" 2>&1); then
        rc=0
    else
        rc=$?
    fi
    if (( rc != 0 )); then
        printf -v out '%s\n\n[omnish] command failed (exit status: %s)' "$out" "$rc"
    fi
    _sys_display_text "$title" "$(printf '%s\n' "$out" | tail -100)"
    return "$rc"
}

# ===============================================================
# Privilege helpers
# ===============================================================
_sys_sudo() {
    # Runs "$@" as root (or via sudo). Returns 1 if impossible.
    if (( _SYS_IS_ROOT )); then
        "$@"
    elif (( _SYS_HAS_SUDO )); then
        sudo "$@"
    else
        printf 'error: root required and sudo not available\n' >&2
        return 1
    fi
}

_sys_need_root_or_sudo() {
    (( _SYS_IS_ROOT || _SYS_HAS_SUDO )) && return 0
    status_msg "root required (or install sudo)"
    return 1
}

# ===============================================================
# Individual system queries
# ===============================================================
_sys_cpu() {
    local model usage nproc
    model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | xargs)
    [[ -z "$model" ]] && model=$(uname -m)
    nproc=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
    if command -v top >/dev/null 2>&1; then
        usage=$(top -b -n1 2>/dev/null | awk '/Cpu\(s\)/{print $0; exit}')
    fi
    _sys_show_file "CPU" "Model: ${model:-unknown}
Cores: ${nproc}
${usage:-usage unavailable}"
}

_sys_sensors() {
    if ! command -v sensors >/dev/null 2>&1; then
        status_msg "sensors not installed (lm-sensors)"
        return
    fi
    _sys_show "Sensors" sensors
}

_sys_ram() {
    local body=""
    if command -v free >/dev/null 2>&1; then
        body=$(free -h 2>/dev/null)
    fi
    [[ -z "$body" ]] && body=$(grep -E 'MemTotal|MemFree|MemAvailable|Buffers|Cached' /proc/meminfo 2>/dev/null)
    _sys_show_file "Memory" "$body"
}

_sys_disk() {
    _sys_show "Disk usage" df -h
}

_sys_net() {
    local body=""
    if command -v ip >/dev/null 2>&1; then
        body=$(ip -br addr show 2>/dev/null | grep -v ' lo ')
        body+=$'\n\n'"$(ip route 2>/dev/null | head -10)"
    elif command -v ifconfig >/dev/null 2>&1; then
        body=$(ifconfig 2>/dev/null | grep -E 'inet |^[a-z]')
    fi
    _sys_show_file "Network" "$body"
}

_sys_kernel() {
    _sys_show_file "Kernel" "$(uname -a)"
}

_sys_uptime() {
    _sys_show_file "Uptime" "$(uptime 2>/dev/null)"
}

_sys_users() {
    _sys_show_file "Logged-in users" "$(users 2>/dev/null)"
}

_sys_ping() {
    _sys_detect
    if (( _SYS_HAS_PING == 0 )); then
        status_msg "ping not installed (iputils-ping)"
        return
    fi
    local ip
    cmd_line "ping target: "
    ip="$cmd_reply"
    [[ -z "$ip" ]] && return
    _sys_show "ping $ip" ping -c 4 -W 2 -- "$ip"
}

_sys_exec() {
    local path
    cmd_line "script path: " dirs
    path="$cmd_reply"
    [[ -z "$path" || ! -f "$path" ]] && { status_msg "not found"; return; }
    loop_reset_terminal 2>/dev/null || reset_terminal 2>/dev/null || clear
    bash "$path"
    read -rsn 1 -t 30 -p "Press any key..." _ < /dev/tty 2>/dev/null ||:
    loop_setup_terminal 2>/dev/null || setup_terminal 2>/dev/null ||:
}

# ===============================================================
# Packages
# ===============================================================
_sys_pkg_install() {
    _sys_detect
    local pkg
    cmd_line "package to install: "
    pkg="$cmd_reply"
    [[ -z "$pkg" ]] && return

    cmd_yes_no "Install '$pkg'?"
    [[ $cmd_reply == yes ]] || return

    case "$_SYS_PKG" in
        ulpm)
            _sys_run "ulpm install $pkg" ulpm install "$pkg" ;;
        apt)
            _sys_need_root_or_sudo || return
            _sys_run "apt install $pkg" _sys_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" ;;
        dnf|yum)
            _sys_need_root_or_sudo || return
            _sys_run "$_SYS_PKG install $pkg" _sys_sudo "$_SYS_PKG" install -y "$pkg" ;;
        *)
            status_msg "no package manager detected" ;;
    esac
}

_sys_pkg_remove() {
    _sys_detect
    local pkg
    cmd_line "package to remove: "
    pkg="$cmd_reply"
    [[ -z "$pkg" ]] && return
    cmd_yes_no "Remove '$pkg'?"
    [[ $cmd_reply == yes ]] || return
    case "$_SYS_PKG" in
        ulpm)
            _sys_run "ulpm remove $pkg" ulpm remove "$pkg" ;;
        apt)
            _sys_need_root_or_sudo || return
            _sys_run "apt remove $pkg" _sys_sudo env DEBIAN_FRONTEND=noninteractive apt-get remove -y "$pkg" ;;
        dnf|yum)
            _sys_need_root_or_sudo || return
            _sys_run "$_SYS_PKG remove $pkg" _sys_sudo "$_SYS_PKG" remove -y "$pkg" ;;
        *)
            status_msg "no package manager detected" ;;
    esac
}

_sys_pkg_search() {
    _sys_detect
    local query
    cmd_line "search: "
    query="$cmd_reply"
    [[ -z "$query" ]] && return
    case "$_SYS_PKG" in
        ulpm)    _sys_show "ulpm search '$query'" ulpm search "$query" ;;
        apt)     _sys_show "apt-cache search '$query'" apt-cache search "$query" ;;
        dnf|yum) _sys_show "$_SYS_PKG search '$query'" "$_SYS_PKG" search "$query" ;;
        *)       status_msg "no package manager detected" ;;
    esac
}

_sys_pkg_list() {
    _sys_detect
    case "$_SYS_PKG" in
        ulpm)    _sys_show "ulpm list" ulpm list ;;
        apt)     _sys_show "Installed packages" bash -c 'dpkg -l 2>/dev/null | tail -n +6' ;;
        dnf|yum) _sys_show "$_SYS_PKG list installed" "$_SYS_PKG" list installed ;;
        *)       status_msg "no package manager detected" ;;
    esac
}

_sys_pkg_update() {
    _sys_detect
    cmd_yes_no "Update all packages?"
    [[ $cmd_reply == yes ]] || return
    case "$_SYS_PKG" in
        ulpm)
            _sys_run "ulpm update" ulpm update ;;
        apt)
            _sys_need_root_or_sudo || return
            _sys_run "apt update" _sys_sudo env DEBIAN_FRONTEND=noninteractive apt-get update || return
            _sys_run "apt upgrade" _sys_sudo env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
            ;;
        dnf|yum)
            _sys_need_root_or_sudo || return
            _sys_run "$_SYS_PKG upgrade" _sys_sudo "$_SYS_PKG" upgrade -y ;;
        *)
            status_msg "no package manager detected" ;;
    esac
}

# ===============================================================
# Services
# ===============================================================
_sys_svc_list() {
    _sys_detect
    case "$_SYS_INIT" in
        systemd) _sys_show "Services" systemctl list-units --type=service --no-pager ;;
        openrc)  _sys_show "Services" rc-service --list ;;
        *)       status_msg "no init system detected" ;;
    esac
}

_sys_svc_action() {
    _sys_detect
    local action="$1" svc

    if (( _SYS_INIT == 0 )) && [[ -z "$_SYS_INIT" ]]; then
        status_msg "no init system detected"
        return
    fi

    cmd_line "service name: "
    svc="$cmd_reply"
    [[ -z "$svc" ]] && return

    # [FIX 7] Confirm destructive actions
    case "$action" in
        stop|restart|disable)
            cmd_yes_no "$action '$svc'?"
            [[ $cmd_reply == yes ]] || return
            ;;
    esac

    case "$_SYS_INIT" in
        systemd)
            case "$action" in
                status)  _sys_show "status $svc" systemctl status "$svc" --no-pager ;;
                start)   _sys_need_root_or_sudo || return
                         _sys_run "start $svc" _sys_sudo systemctl start "$svc" ;;
                stop)    _sys_need_root_or_sudo || return
                         _sys_run "stop $svc" _sys_sudo systemctl stop "$svc" ;;
                restart) _sys_need_root_or_sudo || return
                         _sys_run "restart $svc" _sys_sudo systemctl restart "$svc" ;;
                enable)  _sys_need_root_or_sudo || return
                         _sys_run "enable $svc" _sys_sudo systemctl enable "$svc" ;;
                disable) _sys_need_root_or_sudo || return
                         _sys_run "disable $svc" _sys_sudo systemctl disable "$svc" ;;
            esac
            ;;
        openrc)
            case "$action" in
                status)  _sys_show "status $svc" rc-service "$svc" status ;;
                start)   _sys_need_root_or_sudo || return
                         _sys_run "start $svc" _sys_sudo rc-service "$svc" start ;;
                stop)    _sys_need_root_or_sudo || return
                         _sys_run "stop $svc" _sys_sudo rc-service "$svc" stop ;;
                restart) _sys_need_root_or_sudo || return
                         _sys_run "restart $svc" _sys_sudo rc-service "$svc" restart ;;
                *)       status_msg "enable/disable not supported on openrc here" ;;
            esac
            ;;
    esac
}

# ===============================================================
# Kernel modules
# ===============================================================
_SYS_MOD_BLACKLIST_USER="$CACHE_OMNISH_DIR/modules.blacklist"
_SYS_MOD_BLACKLIST_SYS="/etc/modprobe.d/blacklist.conf"

_sys_mod_available() {
    _sys_detect
    (( _SYS_HAS_LSMOD || _SYS_HAS_MODPROBE )) && return 0
    return 1
}

_sys_mod_list() {
    _sys_detect
    if (( _SYS_HAS_LSMOD )); then
        if (( _SYS_HAS_MODINFO )) && [[ "${OMNISH_BACKEND:-fzf}" == "fzf" ]] && command -v fzf >/dev/null 2>&1; then
            lsmod | tail -n +2 | \
                fzf --no-sort --no-info \
                    --header "Loaded modules | Enter: info | Esc: back" \
                    --preview 'modinfo {1} 2>/dev/null | head -40' \
                    --preview-window 'right:60%:wrap' \
                    --bind 'enter:execute(modinfo {1} 2>/dev/null | less)+accept' \
                    >/dev/null
        else
            _sys_show "Loaded modules" lsmod
        fi
    elif [[ -r /proc/modules ]]; then
        _sys_show "Loaded modules" cat /proc/modules
    else
        status_msg "no module list available"
    fi
}

_sys_mod_info() {
    _sys_detect
    if (( _SYS_HAS_MODINFO == 0 )); then
        status_msg "modinfo not installed"
        return
    fi
    local name
    cmd_line "module name: "
    name="$cmd_reply"
    [[ -z "$name" ]] && return
    _sys_show "modinfo $name" modinfo "$name"
}

_sys_mod_depends() {
    _sys_detect
    if (( _SYS_HAS_MODINFO == 0 )); then
        status_msg "modinfo not installed"
        return
    fi
    local name deps
    cmd_line "module name: "
    name="$cmd_reply"
    [[ -z "$name" ]] && return
    deps=$(modinfo -F depends "$name" 2>/dev/null)
    [[ -z "$deps" ]] && { status_msg "no dependencies"; return; }
    _sys_show_file "depends: $name" "$(printf '%s' "$deps" | tr ',' '\n')"
}

_sys_mod_load() {
    _sys_detect
    if (( _SYS_HAS_MODPROBE == 0 )); then
        status_msg "modprobe not installed"
        return
    fi
    local name
    cmd_line "module to load: "
    name="$cmd_reply"
    [[ -z "$name" ]] && return

    _sys_need_root_or_sudo || return
    cmd_yes_no "Load module '$name'?"
    [[ $cmd_reply == yes ]] || return
    _sys_run "modprobe $name" _sys_sudo modprobe "$name"
}

_sys_mod_unload() {
    _sys_detect
    if (( _SYS_HAS_MODPROBE == 0 )); then
        status_msg "modprobe not installed"
        return
    fi

    local name
    if (( _SYS_HAS_LSMOD )); then
        name=$(lsmod | tail -n +2 | awk '{print $1}' | \
            _omnish_select "Unload module | Enter: select | Esc: cancel")
        [[ -z "$name" ]] && return
    else
        cmd_line "module to unload: "
        name="$cmd_reply"
        [[ -z "$name" ]] && return
    fi

    _sys_need_root_or_sudo || return
    cmd_yes_no "Unload module '$name'? (may fail if in use)"
    [[ $cmd_reply == yes ]] || return
    _sys_run "modprobe -r $name" _sys_sudo modprobe -r "$name"
}

_sys_mod_blacklist() {
    _sys_detect
    local name
    cmd_line "module to blacklist: "
    name="$cmd_reply"
    [[ -z "$name" ]] && return
    # The name is written into a root-owned modprobe configuration file.
    # Reject whitespace, separators and newlines to prevent directive injection.
    if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        status_msg "invalid module name"
        return 2
    fi

    if (( _SYS_IS_ROOT )) && [[ -w "/etc/modprobe.d" ]]; then
        cmd_yes_no "Write 'blacklist $name' to $_SYS_MOD_BLACKLIST_SYS?"
        [[ $cmd_reply == yes ]] || return
        if [[ ! -f "$_SYS_MOD_BLACKLIST_SYS" ]]; then
            printf '# managed by omnish\n' > "$_SYS_MOD_BLACKLIST_SYS" 2>/dev/null
        fi
        if printf 'blacklist %s\n' "$name" >> "$_SYS_MOD_BLACKLIST_SYS" 2>/dev/null; then
            status_msg "blacklisted: $name"
        else
            status_msg "write failed"
        fi
    else
        mkdir -p "$CACHE_OMNISH_DIR" 2>/dev/null
        printf 'blacklist %s\n' "$name" >> "$_SYS_MOD_BLACKLIST_USER" 2>/dev/null
        status_msg "saved to user blacklist (not applied)"
        _sys_show_file "User blacklist" \
"Written to:
  $_SYS_MOD_BLACKLIST_USER

To apply system-wide, copy the entries to:
  $_SYS_MOD_BLACKLIST_SYS
as root, then run:
  sudo update-initramfs -u    (Debian)
  sudo dracut -f              (Fedora/Arch)

Current user blacklist:
$(cat "$_SYS_MOD_BLACKLIST_USER" 2>/dev/null)"
    fi
}

_sys_mod_logs() {
    _sys_detect
    if (( _SYS_HAS_DMESG == 0 )); then
        status_msg "dmesg not installed"
        return
    fi
    local body
    body=$(dmesg -T --level=err,warn 2>/dev/null | tail -100)
    [[ -z "$body" ]] && body=$(dmesg -T 2>/dev/null | tail -100)
    [[ -z "$body" ]] && body=$(dmesg 2>/dev/null | tail -100)
    if [[ -z "$body" ]]; then
        status_msg "dmesg empty or permission denied (try as root)"
        return
    fi
    _sys_show_file "Kernel log (last 100)" "$body"
}

_sys_mod_search() {
    _sys_detect
    if (( _SYS_HAS_MODINFO == 0 )); then
        status_msg "modinfo not installed"
        return
    fi
    local query
    cmd_line "search module: "
    query="$cmd_reply"
    [[ -z "$query" ]] && return

    local kdir="/lib/modules/$(uname -r)"
    if [[ ! -d "$kdir" ]]; then
        status_msg "kernel modules dir not found: $kdir"
        return
    fi
    local matches
    matches=$(find "$kdir" -type f -name "*.ko*" 2>/dev/null | \
        grep -i -- "$query" | head -100 | sed "s|$kdir/||; s|\.ko.*||")
    if [[ -z "$matches" ]]; then
        status_msg "no match for '$query'"
    else
        _sys_show_file "modules matching '$query'" "$matches"
    fi
}

_sys_modules_menu() {
    _sys_detect
    if ! _sys_mod_available; then
        status_msg "module tools unavailable (lsmod/modprobe missing)"
        return
    fi
    local root_hint="user"
    (( _SYS_IS_ROOT )) && root_hint="root"

    while :; do
        local header choice
        header="Modules (mode=$root_hint, lsmod=$_SYS_HAS_LSMOD modprobe=$_SYS_HAS_MODPROBE dmesg=$_SYS_HAS_DMESG) | Esc: back"
        choice=$(cat <<'EOF' | _omnish_select "$header"
loaded   List loaded modules (with info preview)
info     Show modinfo of a module
depends  Show dependencies of a module
search   Search available modules by name
load     Load a module (modprobe)
unload   Unload a module (modprobe -r)
blacklist Add a module to the blacklist
logs     Show recent kernel log (errors/warnings)
EOF
)
        [[ -z "$choice" ]] && return
        case "${choice%% *}" in
            loaded)    _sys_mod_list ;;
            info)      _sys_mod_info ;;
            depends)   _sys_mod_depends ;;
            search)    _sys_mod_search ;;
            load)      _sys_mod_load ;;
            unload)    _sys_mod_unload ;;
            blacklist) _sys_mod_blacklist ;;
            logs)      _sys_mod_logs ;;
        esac
    done
}

# ===============================================================
# BubbleOS: generations / rollback
# ===============================================================
_sys_bubble_generations() {
    _sys_detect
    if (( _SYS_BUBBLE == 0 )); then
        status_msg "bubble command not found (not a BubbleOS system?)"
        return
    fi
    _sys_show "Generations" bubble generation list
}

_sys_bubble_rollback() {
    _sys_detect
    if (( _SYS_BUBBLE == 0 )); then
        status_msg "bubble command not found"
        return
    fi
    local gens
    gens=$(bubble generation list 2>/dev/null | head -30)
    if [[ -z "$gens" ]]; then
        status_msg "no generations"
        return
    fi
    local target
    target=$(printf '%s\n' "$gens" | _omnish_select "Select generation to rollback to | Enter: select | Esc: cancel")
    [[ -z "$target" ]] && return
    local id
    id=$(printf '%s' "$target" | awk '{print $1}')
    # [FIX 8] Validate the id (defensive against output format changes)
    if [[ ! "$id" =~ ^[A-Za-z0-9_.:+-]+$ ]]; then
        status_msg "invalid generation id: '$id'"
        return
    fi
    cmd_yes_no "Rollback to '$id'?"
    [[ $cmd_reply == yes ]] || return
    _sys_need_root_or_sudo || return
    _sys_run "rollback $id" _sys_sudo bubble rollback "$id"
}

# ===============================================================
# Main menu
# ===============================================================
_sys_menu() {
    _sys_detect

    local pkg_hint="${_SYS_PKG:-none}"
    local init_hint="${_SYS_INIT:-none}"
    local bubble_hint="no"; (( _SYS_BUBBLE )) && bubble_hint="yes"
    local mods_hint="no";   _sys_mod_available && mods_hint="yes"

    local has_cpu_mon=0
    declare -F cpu_monitor_view >/dev/null 2>&1 && has_cpu_mon=1

    while :; do
        # [FIX 9] compute the widget once per redraw (was: every fzf iteration)
        local widget_line=""
        if (( has_cpu_mon )) && declare -F cpu_widget >/dev/null 2>&1; then
            widget_line="$(cpu_widget 2>/dev/null) "
        fi

        local header="System: pkg=$pkg_hint | init=$init_hint | bubble=$bubble_hint | modules=$mods_hint
${widget_line}Esc: back"

        local menu=""
        menu+=$'all      Show all (CPU + sensors + RAM + disk + net)\n'
        menu+=$'cpu      CPU model + usage\n'
        if (( has_cpu_mon )); then
            menu+=$'cpu-mon  Live CPU monitor (temp/freq/load, per-core)\n'
            menu+=$'stress   CPU stress test (30s, all cores)\n'
        fi
        menu+=$'ram      RAM usage\n'
        menu+=$'disk     Disk usage\n'
        menu+=$'net      Network interfaces + routes\n'
        menu+=$'kernel   Kernel version\n'
        menu+=$'uptime   System uptime\n'
        menu+=$'users    Logged-in users\n'
        menu+=$'sensors  CPU sensors (lm-sensors)\n'
        menu+=$'ping     Ping a host\n'
        menu+=$'exec     Execute a script\n'
        menu+=$'services Service management (systemd/openrc)\n'
        menu+=$'packages Package management (ulpm/apt/dnf)\n'
        if _sys_mod_available; then
            menu+=$'modules  Kernel modules (list/load/unload/blacklist)\n'
        fi
        # [FIX 5] only show gens/rollback on BubbleOS
        if (( _SYS_BUBBLE )); then
            menu+=$'gens     BubbleOS generations (list)\n'
            menu+=$'rollback BubbleOS rollback to a generation\n'
        fi
        menu+=$'shell    Spawn an interactive shell\n'

        local choice
        choice=$(printf '%s' "$menu" | _omnish_select "$header")

        [[ -z "$choice" ]] && return
        case "${choice%% *}" in
            all)
                _sys_cpu
                _sys_sensors
                _sys_ram
                _sys_disk
                _sys_net
                ;;
            cpu)      _sys_cpu ;;
            cpu-mon)
                if (( has_cpu_mon )); then
                    loop_reset_terminal 2>/dev/null || reset_terminal 2>/dev/null || clear
                    cpu_monitor_view
                    loop_setup_terminal 2>/dev/null || setup_terminal 2>/dev/null ||:
                else
                    status_msg "46-cpu-monitor.sh not loaded"
                fi
                ;;
            stress)
                if (( has_cpu_mon )); then
                    loop_reset_terminal 2>/dev/null || reset_terminal 2>/dev/null || clear
                    cpu_stress_test 30
                    loop_setup_terminal 2>/dev/null || setup_terminal 2>/dev/null ||:
                else
                    status_msg "46-cpu-monitor.sh not loaded"
                fi
                ;;
            ram)      _sys_ram ;;
            disk)     _sys_disk ;;
            net)      _sys_net ;;
            kernel)   _sys_kernel ;;
            uptime)   _sys_uptime ;;
            users)    _sys_users ;;
            sensors)  _sys_sensors ;;
            ping)     _sys_ping ;;
            exec)     _sys_exec ;;
            services) _sys_services_menu ;;
            packages) _sys_packages_menu ;;
            modules)  _sys_modules_menu ;;
            gens)     _sys_bubble_generations ;;
            rollback) _sys_bubble_rollback ;;
            shell)
                loop_reset_terminal 2>/dev/null || reset_terminal 2>/dev/null || clear
                "${SHELL:-bash}" -i
                loop_setup_terminal 2>/dev/null || setup_terminal 2>/dev/null ||:
                ;;
        esac
    done
}

_sys_services_menu() {
    _sys_detect
    while :; do
        local header choice
        header="Services (init=$_SYS_INIT) | Esc: back"
        choice=$(cat <<'EOF' | _omnish_select "$header"
list     List all services
running  List running services
status   Show status of a service
start    Start a service
stop     Stop a service
restart  Restart a service
enable   Enable a service on boot
disable  Disable a service on boot
EOF
)
        [[ -z "$choice" ]] && return
        case "${choice%% *}" in
            list)
                if [[ "$_SYS_INIT" == systemd ]]; then
                    _sys_show "services" systemctl list-units --type=service --no-pager
                else
                    _sys_svc_list
                fi
                ;;
            running)
                if [[ "$_SYS_INIT" == systemd ]]; then
                    _sys_show "running" systemctl list-units --type=service --state=running --no-pager
                else
                    status_msg "not supported on $_SYS_INIT"
                fi
                ;;
            status|start|stop|restart|enable|disable)
                _sys_svc_action "${choice%% *}"
                ;;
        esac
    done
}

_sys_packages_menu() {
    _sys_detect
    while :; do
        local header choice
        header="Packages (manager=$_SYS_PKG) | Esc: back"
        choice=$(cat <<'EOF' | _omnish_select "$header"
list     List installed packages
search   Search the repository
install  Install a package
remove   Remove a package
update   Update all packages
EOF
)
        [[ -z "$choice" ]] && return
        case "${choice%% *}" in
            list)    _sys_pkg_list ;;
            search)  _sys_pkg_search ;;
            install) _sys_pkg_install ;;
            remove)  _sys_pkg_remove ;;
            update)  _sys_pkg_update ;;
        esac
    done
}
