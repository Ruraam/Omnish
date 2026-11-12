<p align="center">
  <img src="assets/omnish-banner.svg" alt="omnish — modular file manager & system console" width="100%">
</p>

**A modular command-line environment for file management, system administration and maintenance.**

`omnish` is a terminal file manager with a system administration panel
built in. It runs on **any POSIX-ish Linux** with bash, coreutils, and
findutils — no Python, no Node, no Rust, no compilation.

It ships with two interchangeable backends:
- **`fzf`** — faster to use, fuzzy search, mouse-friendly, richer previews.
- **`loop`** — pure bash, zero forks per keypress, best on proot and Termux.

Both backends share the same UI functions, marks system, trash, and
system panel. You can switch at runtime with `OMNISH_BACKEND=loop omnish`.

---

## Features

**File manager**
- Vim-style navigation (`j/k/g/G/h/l`), or arrows, or Tab.
- Multi-select (`Tab`/`Shift-Tab`), marks persist across directories.
- Copy, move, rename, symlink, mkdir, touch — all with inline prompts.
- Preview pane: text (bat/highlight), images (chafa/viu), PDF (pdftotext),
  markdown (glow/mdcat), archives, JSON, symlinks, and special files.
- Live grep (`^G`, requires ripgrep).
- `cd` on exit (`OMNI_CD_ON_EXIT=1`) — the parent shell follows you back.

**Trash (reversible delete)**
- `^D` moves files to `~/.local/share/omnish/trash/<ts>-<rand>/`.
- `alt-u` restores the last batch (with accurate "restored/skipped/failed"
  counts, no silent data loss).
- `alt-t` browses the trash interactively.
- `omnish --empty-trash` permanently clears it.

**Disk usage panel (`^U`)**
- `flat` mode: first-level sizes, batched, fast.
- `tree` mode: recursive, sorted, percentage bars (dust-inspired).
- Configurable depth, min %, exclude patterns, bar width.
- Trash from inside the panel, drill down, rescan.

**System panel (`^X`)**
- CPU model, RAM, disk, network, kernel, uptime, logged-in users.
- Services (systemd / openrc): list, start, stop, restart, enable, disable.
- Packages (ulpm / apt / dnf / yum): list, search, install, remove, update.
- Kernel modules (kmon-inspired): list, info, depends, load, unload,
  blacklist, dmesg log.
- BubbleOS generations: list + rollback.
- CPU monitor (s-tui-inspired): live temperature/frequency/load, per-core
  frequencies, and a stress test — all read directly from `/proc` and
  `/sys`, no sensors, no msr, no root.
- Spawn an interactive shell.

---

## Installation

### From source

```bash
git clone https://github.com/<your-username>/omnish.git
cd omnish

# Local install (recommended)
./install.sh

# System-wide
sudo PREFIX=/usr/local ./install.sh
```

install.sh copies omnish and lib/ under $PREFIX/share/omnish/
and symlinks $PREFIX/bin/omnish. It runs bash -n on every installed
file and aborts if any fails.

Requirements

| Feature | Requires |
| :--- | :--- |
| **Core** | `bash` >= 4.4, `coreutils`, `findutils` |
| **Backend `fzf`** | `fzf` (recommended >= 0.42) |
| **Backend `loop`** | *nothing* (pure bash) |
| **Image previews** | `chafa` (recommended) or `viu` |
| **Text previews** | `bat` or `highlight` or `glow` |
| **PDF previews** | `poppler-utils` |
| **Grep search** | `ripgrep` (`rg`) |
| **Long listing**  | `eza` (or `ls`) |
| **Native dialogs** | `whiptail` or `dialog` (optional) |

omnish --version reports the resolved backend and whether the optional
script-dialog integration is active.

---

Quick start

```bash
omnish                  # open in $PWD
omnish /etc             # open in /etc
omnish --system-menu    # jump straight to the system panel
omnish --dua            # jump straight to the disk usage panel
omnish --undo           # restore the last trash batch
```

The first time you launch it:

1. Tab selects the current file (a * appears next to it) and moves down.
2. ^U opens the disk usage panel on the current directory.
3. ^X opens the system panel (CPU, RAM, services, packages, modules).
4. q or Esc quits; your last directory is saved for the shell wrapper
   (see Shell integration).

---

Keybindings

Key Action
↑/↓ / j/k Move selection
Enter / → / l Open file or descend into directory
← / h / ⌫ Go to parent directory
g / G Top / bottom
Tab / Shift-Tab Mark current + move down/up
Space Toggle mark on current (loop backend)
alt-a Toggle mark on current (both backends)
alt-x Mark all in current directory
^a Toggle-all in current directory
c Clear marks
^Y / ^V Copy / move marked files
^D / ^E Trash (reversible, see below)
^N / alt-n mkdir / touch
^S / r Symlink / rename
^O Open with mime handler
p / x / X Paste marks / stat / toggle executable
^P Toggle preview pane
alt-h Toggle hidden files
alt-l Toggle long listing
^G Grep in tree (ripgrep)
/ Local filter (loop backend)
! / ~ / - Shell / $HOME / $OLDPWD
1–9 Jump to OMNI_FAV_<N>
F1 / ? Help
Esc / ^Q / ^C Quit (loop: q or Esc)

Inside the disk usage panel (^U)

Key Action
Enter / → Descend
^H / ← Up one level
^O Open (shell in dir / editor on file)
^D / ^E Trash selected entry
^R Rescan
^T Toggle flat ↔ tree
alt-d/alt-D Increase / decrease tree depth
Esc Return to omnish

Inside the system panel (^X)

Entry Action
all CPU + sensors + RAM + disk + net
cpu Model + usage
cpu-mon Live monitor (q quit, s stress test, r reset)
stress CPU stress test (30 s × nproc)
ram, disk, net, kernel, uptime, users as named
sensors lm-sensors
ping, exec Ping a host / run a script
services systemd/openrc service management
packages ulpm / apt / dnf / yum package management
modules Kernel modules (list, info, depends, load, unload, blacklist, logs)
gens, rollback BubbleOS generations (only on BubbleOS)
shell Spawn an interactive shell

---

Backends

Both backends implement the same contract (fzf_main / loop_main) and
consume the same UI, preview, dua, fileops, and trash modules.

| Feature | `fzf` backend | `loop` backend |
| :--- | :---: | :---: |
| **Fuzzy search** | ✅ native fzf | ❌ substring only |
| **Mouse support** | ✅ | ❌ |
| **Forks per keypress** | ~1 (fzf redraw) | **0** (pure bash) |
| **Alt-screen flicker** | Rare | Frequent on proot |
| **Preview scrolling** | ✅ | Limited |
| **Bundle size** | Needs fzf binary | **Self-contained** |

```bash
OMNISH_BACKEND=fzf  omnish   # explicit
OMNISH_BACKEND=loop omnish   # explicit
omnish                       # auto: fzf if present, else loop
```

On proot Debian, Termux, and CI containers, loop is
noticeably faster because there's no fzf subprocess between every keypress.

---

Configuration

Config file: $XDG_CONFIG_HOME/omnish/omnish.conf (~/.config/omnish/omnish.conf).
Format: bash — it is sourced directly.

```bash
# Behavioral
OMNI_CD_ON_EXIT=1          # write $PWD to .omnish_d on exit
OMNI_USE_TRASH=1           # 1: ^D goes to trash, 0: ^D uses rm -rf
OMNI_OPENER="xdg-open"     # opener for ^O on non-text files
OMNI_TRASH="$HOME/.local/share/omnish/trash"
OMNISH_BACKEND=auto        # fzf|loop|auto
MARGIN_PREVIEW=60          # preview width: chars (60) or percent (60%)

# Disk usage panel
DUA_MODE=flat              # flat|tree
DUA_TREE_DEPTH=3
DUA_TREE_LINES=30
DUA_MIN_PCT=1              # hide entries below this % of total
DUA_EXCLUDES=".git node_modules .cache .venv target"
DUA_BAR_WIDTH=12

# CPU monitor
CPU_TEMP_THRESHOLD=80      # °C threshold for hook + colour
CPU_HOOK_SCRIPT=""         # script run on crossing ($1=temp $2=threshold)
CPU_MONITOR_REFRESH=1      # refresh interval (s)
CPU_WIDGET_CACHE_TTL=2

# Favorites
OMNI_FAV_1=~/Documents
OMNI_FAV_2=~/Downloads
OMNI_FAV_3=~/Pictures
```

Every option is optional. omnish --show-help opens the full reference.

---

Shell integration

Add to ~/.bashrc (or ~/.zshrc) so omnish can cd the parent shell
on exit:

```bash
omnish() {
    command omnish "$@"
    local rc=$?
    if [[ -f ~/.cache/omnish/.omnish_d ]]; then
        cd "$(cat ~/.cache/omnish/.omnish_d)"
        rm -f ~/.cache/omnish/.omnish_d
    fi
    return $rc
}
```

This pairs with OMNI_CD_ON_EXIT=1 (default).

---

Architecture

```
omnish/
├── omnish              # entrypoint: resolve backend, load modules, dispatch
├── lib/
│   ├── 00-config.sh    # paths, env, config loading, defaults
│   ├── 10-utils.sh     # clean_path, human_size, cleanup, mark persistence
│   ├── 15-dialog.sh    # optional script-dialog integration (falls back)
│   ├── 20-ui.sh        # cmd_line, cmd_yes_no, status_msg (bash fallback)
│   ├── 25-progress.sh  # progress bars + spinners (count, time, indeterminate)
│   ├── 30-preview.sh   # _preview_file: text/images/pdf/markdown/etc.
│   ├── 40-dua.sh       # disk usage panel (flat + tree views)
│   ├── 45-system.sh    # system panel: cpu/ram/disk/net/svc/pkg/modules/gens
│   ├── 46-cpu-monitor.sh # live CPU view + stress test + hook
│   ├── 50-fileops.sh   # copy, move, delete, mkdir, touch, symlink
│   ├── 60-trash.sh     # reversible delete (batch dirs, undo, empty, view)
│   ├── 70-fzf.sh       # fzf backend (fzf_main)
│   ├── 70-loop.sh      # loop backend (loop_main, pure bash)
│   ├── 80-help.sh      # help text
│   └── 99-main.sh      # backend dispatcher (main)
├── install.sh
├── uninstall.sh
└── share/
    └── omnish.conf.example
```

Load order is alphabetical. The entrypoint skips 70-* during the
common pass, then loads exactly one backend based on OMNISH_BACKEND.

Dependency direction is strictly upward: 00 has no deps, 10 depends
on 00, 20 on 10, and so on. 70-* depends on 00–60. 99 only
depends on 70-*.

Guards: every cross-module function is gated with declare -F so a
missing optional module degrades gracefully. 20-ui.sh will not override
cmd_line/cmd_yes_no if 15-dialog.sh already provided them.

---

Packaging (.lpk for BubbleOS)

```
app_id: omnish
version: 3.0.0
depends: bash, findutils, coreutils, file
optional: fzf, bat, chafa, eza, glow, poppler-utils, ripgrep, less,
          whiptail, dialog
entrypoint: ~/.local/bin/omnish
permissions: filesystem=home
description: Modular file manager and system console for BubbleOS
```

The user-scoped installer handles the .lpk's pre-install step: it copies omnish,
lib/, and (if present) vendor/ under $PREFIX/share/omnish/.

If whiptail or dialog is absent at runtime, 15-dialog.sh skips the
native-dialog path and 20-ui.sh provides the pure-bash fallbacks. Nothing
breaks.

---

Development

```bash
# Syntax check every file
bash -n omnish
for f in lib/*.sh; do bash -n "$f" || echo "FAIL: $f"; done

# Quick smoke test without installing
./omnish /tmp
./omnish --version
./omnish --system-menu
./omnish --dua /tmp

# Install to a throwaway prefix
PREFIX=/tmp/omnish-test ./install.sh
PATH=/tmp/omnish-test/bin:$PATH omnish --version
```

Design rules

· Every module has a single responsibility (see Architecture).
· Cross-module functions are guarded by declare -F.
· Errors go to /dev/tty (stderr is redirected to debug.log).
· The trap cleanup EXIT INT TERM lives in the interactive entry points
  (fzf_main, loop_main), never at module scope.
· No bash -c "... '$var' ..." — arguments are always passed directly,
  never interpolated into a shell string.
· No external dependency is mandatory for core operation.

Tested on: Debian 12, Ubuntu 22.04, Termux (native), proot Debian on
Android 14+, Alpine 3.19.

---

Exit codes

| Code | Meaning |
| :---: | :--- |
| `0` | Normal exit (`q`, `Esc`, `^Q`) |
| `130` | `SIGINT` (Ctrl-C)|
| `143` | `SIGTERM` |
| `1` | Fatal error (missing lib, bad backend) |
| `2` | Invalid CLI argument |

---

License

GPLv3 — see LICENSE.

Portions inspired by:

· fff — the bash-loop TUI model.
· dust — tree/percentage disk view.
· kmon — kernel module management UX.
· s-tui — CPU monitoring + stress test.
· script-dialog — optional
  whiptail/dialog abstraction.
