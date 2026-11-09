# omnish — help text

help() {
    cat <<'EOF'
╔══════════════════════════════════════════════════════════════════════╗
║  omnish — modular file manager for BubbleOS                           ║
╚══════════════════════════════════════════════════════════════════════╝

USAGE
  omnish [DIR]               Launch in DIR (default: $PWD)
  omnish --version, -v       Print version + resolved backend + dialog
  omnish --help, -h          This help

  Subcommands:
    --backend                Print resolved backend (fzf|loop)
    --has-dialog             Print 1 if script-dialog is active, else 0
    --show-help              Open help in whiptail/dialog/pager
    --system-menu            Open the system panel directly
    --undo                   Restore the most recent trash batch
    --trash-view             Browse trash interactively
    --empty-trash            Permanently delete everything in the trash
    --list-files [DIR]       Print raw listing of DIR
    --dua [DIR]              Launch disk usage panel directly on DIR
    --preview-file PATH      Print preview of PATH

═══════════════════════════════════════════════════════════════════════════
NAVIGATION
  ↑/↓              Move selection         Tab/⇧Tab    Multi-select + move
  Enter/→          Open / descend         ←/h/⌫       Go up one level
  g / G            Top / bottom           F5 / ^R     Refresh listing
  F1 / ?           This help              Esc/^Q/^C   Quit (loop: q|Esc)
  ^P               Toggle preview
  alt-h            Toggle hidden files    (loop: . also works)
  alt-l            Toggle long listing
  ~ / -            Go to $HOME / $OLDPWD  :           Go to arbitrary dir
  1..9             Jump to favorite (OMNI_FAV<N> in config)

FILE OPERATIONS
  ^Y  copy            ^V  move             ^D / ^E  trash
  ^N  mkdir           alt-n  touch         ^S      create symlink
  ^O  open (mime)     r  rename            p       paste marked here
  !   spawn $SHELL    x  stat              X       toggle executable bit

MARKING
  Tab / Shift-Tab     Select + move down/up
  Space               Toggle mark on current (loop backend)
  alt-a               Toggle mark on current (both backends)
  alt-x               Mark all in current dir
  ^a                  Toggle-all in current dir
  c                   Clear all marks

TRASH (reversible delete)
  alt-u               Undo the most recent trash batch
  alt-t               Browse trash, restore individual items
  --empty-trash       Permanently delete the trash (CLI)
  --undo              Undo last batch (CLI)
  Set OMNI_USE_TRASH=0 to make ^D use rm -rf directly.

DISK USAGE PANEL
  ^U                  Launch disk usage on current directory
                      Inside:
                        Enter / →      Descend into directory
                        ^H / ←         Go up one level
                        ^O             Open (shell / editor)
                        ^D / ^E        Trash selected entry
                        ^R             Rescan current directory
                        ^T             Toggle flat ↔ tree view
                        alt-d / alt-D  Increase / decrease tree depth
                        Esc            Return to omnish
  Config: DUA_MODE, DUA_TREE_DEPTH, DUA_TREE_LINES, DUA_MIN_PCT,
          DUA_EXCLUDES, DUA_BAR_WIDTH

SYSTEM PANEL
  ^X                  Open the system management panel
                        → CPU, RAM, disk, network, kernel, uptime, users
                        → sensors, ping, execute a script
                        → services (systemd / openrc)
                        → packages (ulpm on BubbleOS, apt/dnf/yum elsewhere)
                        → kernel modules
                        → BubbleOS generations: list + rollback
                        → spawn interactive shell

CPU MONITOR (panel → cpu-mon)
  cpu-mon             Live monitor (temperature, frequency, load, per-core)
                        → q: quit, s: stress test, r: reset threshold
  stress              CPU stress test (30s × nproc workers)
  Config: CPU_TEMP_THRESHOLD, CPU_HOOK_SCRIPT, CPU_MONITOR_REFRESH,
          CPU_WIDGET_CACHE_TTL

KERNEL MODULES (panel → modules)
  loaded              List loaded modules (preview: modinfo)
  info                Show modinfo of a module
  depends             Show dependencies (modinfo -F depends)
  search              Search .ko files under /lib/modules/<uname -r>
  load / unload       modprobe / modprobe -r (sudo if not root)
  blacklist           As root: /etc/modprobe.d/blacklist.conf
                      As user: ~/.cache/omnish/modules.blacklist
  logs                Recent kernel log (dmesg --level=err,warn, last 100)

SEARCH
  ^G                  Grep in current tree (requires ripgrep)
  /                   Local substring filter (loop backend only)
  Type text           Fuzzy filter (fzf backend)

═══════════════════════════════════════════════════════════════════════════
BACKEND
  OMNISH_BACKEND=fzf   Use fzf (requires `fzf` in PATH)
  OMNISH_BACKEND=loop  Pure-bash TUI (no fzf, no fork per keypress)
  OMNISH_BACKEND=auto  fzf if available, else loop (default)

SCRIPT-DIALOG (optional)
  If vendor/script-dialog/ is present, omnish uses native whiptail/dialog
  prompts for cmd_line and cmd_yes_no. Force-disable with
  OMNISH_HAS_SCRIPT_DIALOG=0.

═══════════════════════════════════════════════════════════════════════════
CONFIG FILE
  Location: $XDG_CONFIG_HOME/omnish/omnish.conf  (default: ~/.config/omnish/)

  Behavioral
    OMNI_CD_ON_EXIT=1       Write $PWD to .omnish_d on exit
    OMNI_USE_TRASH=1        1: ^D → trash, 0: ^D → rm -rf
    OMNI_OPENER="xdg-open"  Opener for ^O on non-text files
    OMNI_TRASH=~/.local/share/omnish/trash
    OMNISH_BACKEND=auto     fzf|loop|auto
    MARGIN_PREVIEW=60       Preview width (chars or N%)

  Disk usage
    DUA_MODE=flat           Initial mode: flat|tree
    DUA_TREE_DEPTH=3        Recursion depth in tree mode
    DUA_TREE_LINES=30       Max lines in tree mode
    DUA_MIN_PCT=1           Hide entries below this % of total
    DUA_EXCLUDES=".git node_modules .cache .venv target"
    DUA_BAR_WIDTH=12        Bar width in characters

  CPU monitor
    CPU_TEMP_THRESHOLD=80
    CPU_HOOK_SCRIPT=""
    CPU_MONITOR_REFRESH=1
    CPU_WIDGET_CACHE_TTL=2

  Favorites
    OMNI_FAV_1=~/Documents
    OMNI_FAV_2=~/Downloads
    ...

SHELL INTEGRATION (add to ~/.bashrc)
  omnish() {
      command omnish "$@"
      local rc=$?
      if [[ -f ~/.cache/omnish/.omnish_d ]]; then
          cd "$(cat ~/.cache/omnish/.omnish_d)"
          rm -f ~/.cache/omnish/.omnish_d
      fi
      return $rc
  }

ENVIRONMENT
  OMNISH_BACKEND, OMNISH_DEBUG, OMNISH_HAS_SCRIPT_DIALOG
  XDG_CONFIG_HOME, XDG_CACHE_HOME, XDG_DATA_HOME honored
  TMPDIR, LINES, COLUMNS

PATHS
  Config:   $XDG_CONFIG_HOME/omnish/omnish.conf
  Cache:    $XDG_CACHE_HOME/omnish/
  Trash:    $XDG_DATA_HOME/omnish/trash/
  Temp:     $TMPDIR/omnish/
  Debug:    $TMPDIR/omnish/debug.log

EXIT CODES
  0    normal exit        130  SIGINT (Ctrl-C)
  143  SIGTERM            1    fatal error
EOF
}