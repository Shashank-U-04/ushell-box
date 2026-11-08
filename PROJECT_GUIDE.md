# 📦 ushell-box — The Complete Project Guide

> **Everything you need to know about this mini-project:** what it is, what it does, how it works,
> what it uses, how to run it, how to read the code, and how to answer the viva.

| | |
|---|---|
| **Project** | ushell-box: a Bash-native micro-container engine |
| **Course** | B24EF0506 — UNIX Shell Programming (USP) Lab |
| **University** | REVA University · 5th Semester B.Tech CSE |
| **Language** | Bash 4.4+ (no Python, no C, no Docker) |
| **Runs on** | Ubuntu 24.04 on WSL 2 · Ubuntu 22.04/24.04 in VMware |
| **Main files** | `box` · `setup.sh` · `demo.sh` · `README.md` · `VIVA_PREP.md` · `PROJECT_GUIDE.md` |

> 💡 **How to read this file:** in VS Code press `Ctrl+Shift+V` (or right-click → *Open Preview*). On
> GitHub it renders automatically. Click any **▶ Answer** line in the viva section to reveal the answer,
> so you can test yourself.

---

## 📑 Table of Contents

1. [The 30-second explanation](#1-the-30-second-explanation)
2. [Problem statement and objectives](#2-problem-statement-and-objectives)
3. [Background concepts (from zero)](#3-background-concepts-from-zero)
4. [What the project does: features](#4-what-the-project-does-features)
5. [What it uses: tools and technologies](#5-what-it-uses-tools-and-technologies)
6. [Architecture](#6-architecture)
7. [How it works, step by step](#7-how-it-works-step-by-step)
8. [Code breakdown: understanding the source](#8-code-breakdown-understanding-the-source)
9. [Installation and how to run](#9-installation-and-how-to-run)
10. [How to use it: command cookbook](#10-how-to-use-it-command-cookbook)
11. [Reading the output](#11-reading-the-output)
12. [USP syllabus mapping](#12-usp-syllabus-mapping)
13. [Applications: where this is used in the real world](#13-applications-where-this-is-used-in-the-real-world)
14. [Testing and results](#14-testing-and-results)
15. [Limitations and future scope](#15-limitations-and-future-scope)
16. [Troubleshooting](#16-troubleshooting)
17. [Presenting the project: 5-minute demo script](#17-presenting-the-project-5-minute-demo-script)
18. [Viva questions and answers](#18-viva-questions-and-answers)
19. [Glossary](#19-glossary)
20. [Cheat sheet](#20-cheat-sheet)

---

## 1. The 30-second explanation

> *"ushell-box is a mini Docker written in pure Bash. With one command, `box run alpine`, it starts
> a program inside an isolated **container**. The program gets its own filesystem (Alpine Linux), its
> own process list where it is PID 1, its own hostname, and hard limits on memory and CPU.
> It uses only standard Linux tools that ship with Ubuntu: `unshare`, `chroot`, `mount`,
> `nsenter` and the cgroup files in `/sys/fs/cgroup`. Bash scripting glues them together into a real
> container engine, with clean-up that survives Ctrl+C and even `kill -9`."*

**In one line:** *Docker's core ideas (namespaces + chroot + cgroups), rebuilt with shell scripting.*

---

## 2. Problem statement and objectives

### Problem statement
Tools like Docker hide how containers really work behind a large Go codebase. Students use containers
daily without knowing that a container is *just a Linux process with a restricted view of the system*.
The goal is to **build a working container engine using only UNIX shell programming**, and in doing so
exercise every major topic of the USP syllabus.

### Objectives
1. **Filesystem isolation:** jail a process inside a separate root filesystem (`chroot`).
2. **Process isolation:** give the container its own PID numbering, where its command is PID 1 (PID namespace).
3. **Hostname and IPC isolation:** UTS and IPC namespaces.
4. **Resource control:** enforce memory and CPU ceilings with Linux **cgroups** (v2, with a v1 fallback).
5. **Lifecycle management:** pull images, run, list, exec into, stop and remove containers.
6. **Robustness:** never leave orphaned mounts or cgroups, even on crashes (signal traps + kernel guarantees).
7. **Usability:** colourised CLI, a menu-driven interface (lab-manual requirement) and an automated demo.

---

## 3. Background concepts (from zero)

Read this section first if any of these words are new. Each concept has an analogy.

### 3.1 Process
A running program. Every process has a **PID** (process ID), a parent (**PPID**), open files and memory.
`ps -ef` lists them all. The kernel keeps a live view of them under `/proc/<pid>/`.

### 3.2 The kernel and system calls
The **kernel** is the core of Linux that controls hardware and processes. Programs ask it for things
through **system calls** (`fork`, `execve`, `mount`, `chroot`, `kill`, …). Shell commands like `mount` or
`unshare` are thin wrappers around these system calls.

### 3.3 `chroot`: a fake root directory
> 🏠 *Analogy: locking someone in one room and telling them "this room is the whole house."*

`chroot /some/dir cmd` runs `cmd` with `/some/dir` treated as `/`. The program can no longer see files
outside it. **But** it can still see every process on the machine, share the network, and change the
hostname. A chroot alone is *not* a container.

### 3.4 Namespaces: private views of the system
> 🕶️ *Analogy: giving a process special glasses that show only its own things.*

A **namespace** makes a process see its own private copy of one global resource:

| Namespace | Isolates | Effect in ushell-box |
|---|---|---|
| **PID** | process IDs | container sees itself as PID 1; can't see host processes |
| **mnt** (mount) | the mount table | container mounts don't appear on the host |
| **UTS** | hostname | `hostname` inside = container name |
| **IPC** | shared memory / message queues | no SysV IPC clash with the host |
| net | network interfaces | *not used:* container shares host network |
| user | user/group IDs | *not used:* root inside = root outside |

Namespaces are visible as files: `ls -l /proc/$$/ns/`. Two processes are in the same namespace if
those links show the same **inode number**.

### 3.5 cgroups: resource limits
> 💰 *Analogy: a prepaid card. Once 50 MB is spent, the card is declined.*

**Control groups** put processes into groups and limit what the group can use. Everything is done
through ordinary files:

```bash
mkdir /sys/fs/cgroup/ushell-box/abc123            # create a group
echo 52428800       > .../abc123/memory.max       # 50 MiB memory ceiling
echo "20000 100000" > .../abc123/cpu.max          # 20 % of one CPU
echo $PID           > .../abc123/cgroup.procs     # put a process in the group
```

If the group exceeds `memory.max`, the kernel's **OOM killer** kills a process *in that group only*.
That is why a runaway container can't crash WSL or VMware.

**cgroup v1** = one directory tree per resource (`/sys/fs/cgroup/memory/…`, `/sys/fs/cgroup/cpu/…`).
**cgroup v2** = one unified tree (`/sys/fs/cgroup/…`). Ubuntu 22.04+ uses v2. ushell-box supports both.

### 3.6 overlayfs: copy-on-write layers
> 📄 *Analogy: a transparent sheet over a printed page. You write on the sheet, and the page is never touched.*

overlayfs stacks a read-only **lower** directory (the image) under a writable **upper** directory.
The container sees the **merged** result. Writes go to *upper*, so the downloaded image stays pristine
and many containers can share it. Docker uses the same trick.

### 3.7 Signals
Messages sent to processes: `SIGTERM` (15, "please stop"), `SIGKILL` (9, "die now, can't be caught"),
`SIGINT` (2, Ctrl+C). A script can catch most signals with `trap`. **SIGKILL can never be caught.**

### 3.8 Exit status
Every command returns a number: `0` = success, anything else = failure. If a process is killed by
signal *N*, the shell reports **128 + N**. So `137` = killed by SIGKILL (9) and `130` = Ctrl+C (2).

---

## 4. What the project does: features

| Feature | Command | What happens |
|---|---|---|
| Download an OS image | `box pull alpine` | fetches the Alpine minirootfs (~3.7 MB), **verifies its SHA-256**, extracts it |
| List images | `box images` | name, version, size, **inode**, date |
| Run a container | `box run alpine sh` | isolated shell in Alpine |
| Memory limit | `--mem 50M` | killed at exactly 50 MiB |
| CPU limit | `--cpu 20` | throttled to 20 % of one core |
| Process limit | `--pids 100` | fork-bomb protection (default 512) |
| Shared folder | `--vols /host:/data:ro` | bind-mount a host directory (optionally read-only) |
| Background | `-d` | runs detached, prints the container ID |
| List containers | `box ps` / `box ps -a` | ID, name, status, memory, PIDs host→container |
| Enter a container | `box exec web sh` | joins its namespaces with `nsenter` |
| Live usage | `box stats web` | memory, peak, CPU %, process list |
| Console output | `box logs -f web` | output of detached containers |
| Stop | `box stop web` | SIGTERM → wait → SIGKILL → tear down |
| Remove | `box rm web` | deletes state (refuses while mounts exist) |
| Inspect | `box inspect web` | config, namespace inodes, live cgroup values |
| Crash recovery | `box cleanup` | reaps dead containers, orphan cgroups, stray mounts |
| Host check | `box info` | kernel, cgroup version, overlayfs, … |
| Menu UI | `box menu` | `while true` + `case` menu |

---

## 5. What it uses: tools and technologies

**No extra software is installed.** Everything ships with Ubuntu.

| Tool | Package | Used for |
|---|---|---|
| `bash` 4.4+ | bash | the whole engine |
| `unshare` | util-linux | create PID / mount / UTS / IPC namespaces; mount `/proc` |
| `nsenter` | util-linux | `box exec`: join a running container's namespaces |
| `setsid` | util-linux | detach background containers from the terminal |
| `flock` | util-linux | lock state files against concurrent writes |
| `setpriv` | util-linux | `--pdeathsig KILL`: container dies if its parent dies |
| `chroot` | coreutils | filesystem jail |
| `mount` / `umount` | util-linux | overlay, proc, sysfs, tmpfs, bind mounts |
| `env` | coreutils | clean environment, reset signal dispositions |
| `curl` / `wget` | curl / wget | download images |
| `sha256sum` | coreutils | verify downloads |
| `tar`, `gzip` | tar, gzip | extract the root filesystem |
| `awk`, `sed`, `grep`, `sort`, `cut`, `wc`, `stat`, `find`, `du` | coreutils/gawk/… | text processing, metadata |
| `ps`, `pgrep`, `kill` | procps | process control |
| `hostname` | hostname | set the UTS hostname |
| Linux kernel features | — | namespaces, cgroup v2/v1, overlayfs, procfs, sysfs |
| **Alpine Linux minirootfs** | downloaded | the container OS image (~8.7 MB unpacked) |

---

## 6. Architecture

### 6.1 The three scripts

```
┌──────────────┐     ┌────────────────────────────────────────────┐     ┌──────────────┐
│  setup.sh    │────►│  box  (the engine — one Bash script)       │◄────│  demo.sh     │
│ checks host, │     │                                            │     │ automated    │
│ pulls Alpine │     │  CLI parser → commands → kernel features   │     │ evaluation   │
└──────────────┘     └────────────────────────────────────────────┘     └──────────────┘
                                         │
              ┌──────────────────────────┼──────────────────────────┐
              ▼                          ▼                          ▼
     /var/lib/ushell-box/       /sys/fs/cgroup/ushell-box/     Linux namespaces
     images/  containers/       <id>/memory.max, cpu.max …     pid · mnt · uts · ipc
```

### 6.2 Anatomy of one running container

```
HOST (Ubuntu)
│
├─ box run  (supervisor)          ← waits, records exit code, tears down
│   └─ box __init  (shim)         ← new MOUNT + UTS + IPC namespaces; does all mounting
│        └─ box-reaper            ← created the new PID namespace; waits for PID 1
│             └─ PID 1 = your command, chrooted into the merged overlay
│                  └─ PID 2, 3 …  (its children)
│
└─ cgroup /sys/fs/cgroup/ushell-box/<id>/   ← contains shim, reaper, PID 1, everything below
```

### 6.3 What the container sees

```
 container's  /              =  overlay( lower = images/alpine/rootfs ,  upper = containers/<id>/upper )
 container's  /proc          =  fresh procfs of the container's PID namespace  (only its processes)
 container's  /sys           =  sysfs, read-only
 container's  /dev           =  tiny tmpfs with null, zero, full, random, urandom, tty, pts, shm
 container's  /data          =  (optional) bind mount of a host folder
 container's  hostname       =  the container name
```

### 6.4 On-disk layout

```
/var/lib/ushell-box/                 ← BOX_ROOT (change with the BOX_ROOT env variable)
├── images/
│   └── alpine/
│       ├── rootfs/                  ← pristine Alpine files (read-only lower layer)
│       └── image.meta               ← version, SHA-256, source URL, pull date
├── containers/
│   └── 8a2e86cbd744/                ← one directory per container (12-hex-digit ID)
│       ├── config                   ← KEY=VALUE state: NAME, STATUS, INIT_PID, MEM_BYTES …
│       ├── cmd                      ← the command's arguments, NUL-separated
│       ├── volumes                  ← host:container:mode lines
│       ├── console.log              ← output (detached containers)
│       ├── upper/ work/             ← overlay writable layer
│       └── merged/                  ← container root (mounted only inside its namespace)
└── tmp/                             ← partial downloads, auto-removed
```

---

## 7. How it works, step by step

### 7.1 `box pull alpine`

```
1. uname -m                         → x86_64
2. curl latest-releases.yaml        → awk finds "alpine-minirootfs-3.24.4-x86_64.tar.gz" + its sha256
3. curl -o tarball                  → download into BOX_ROOT/tmp/pull.XXXXXX  (trap deletes on failure)
4. sha256sum tarball | cut -d' ' -f1  must equal the published hash, else abort (exit 3)
5. tar --numeric-owner -xpzf        → extract
6. cat > image.meta <<EOF … EOF     → record metadata (here-document)
7. mv  → images/alpine              → atomic install
```

### 7.2 `box run --name web --mem 50M --cpu 20 alpine sh`: the full journey

| # | Who | What happens | Why |
|---|---|---|---|
| 1 | `main` | not root? → `exec sudo …` again | namespaces/mounts/cgroups need root |
| 2 | `cmd_run` | parse options, validate (`50M` → `52428800`, CPU range, name regex, volume paths) | bad input → exit 1 |
| 3 | `cmd_run` | random ID from `/dev/urandom`, write `config` with a here-doc, `cmd` with `printf '%s\0'` | persistent state |
| 4 | `supervise` | `prepare_rootfs`: create `upper/ work/ merged/` | copy-on-write root |
| 5 | `supervise` | `cg_create`: `mkdir` cgroup, write `memory.max`, `memory.swap.max=0`, `cpu.max`, `pids.max` | limits exist *before* the container |
| 6 | `supervise` | `( echo $BASHPID > cgroup.procs; exec unshare --mount --uts --ipc … box __init ) &` | the shim joins the cgroup, so every descendant is limited |
| 7 | `__init` | `mount --make-rprivate /` | mounts never leak to the host |
| 8 | `__init` | `mount -t overlay … merged/` | the root filesystem |
| 9 | `__init` | `mount -t sysfs` (ro), tmpfs on `/dev` + device binds, devpts, shm | minimal system dirs |
| 10 | `__init` | `hostname web`, write `/etc/hostname`, `/etc/hosts`, `/etc/resolv.conf` | identity + DNS |
| 11 | `__init` | bind-mount volumes (with symlink-escape checks) | shared folders |
| 12 | `__init` | `exec unshare --pid -- bash -c 'reaper'` | children of this process go into a **new PID namespace** |
| 13 | reaper | forks **once** → that child is **PID 1** | the first child of a new PID ns is its init |
| 14 | PID 1 | `exec env --default-signal…` → `setpriv --pdeathsig KILL` → `unshare --mount-proc=…/proc` → `env -i PATH=…` → `chroot merged/ sh` | each step `exec`s (no fork), so `sh` **is** PID 1, with a fresh `/proc` and a clean environment |
| 15 | `supervise` | `find_ns_child` finds the host PID of PID 1 (verifies a different PID-ns inode) | for `ps`/`stop`/`exec` |
| 16 | `supervise` | `wait $shim` (interruptible by traps) | container runs |
| 17 | `record_exit` | exit code, `memory.events` → `oom_kill`, `memory.peak` saved to `config` | accounting before deletion |
| 18 | EXIT trap | `container_teardown`: kill leftovers, `rmdir` cgroup, sweep mounts, `--rm` deletes state | nothing left behind |

### 7.3 Why there are two `unshare` calls (the clever bit)

`unshare --pid` doesn't move the calling process. Only its **next child** becomes PID 1. If setup
commands like `mount` ran after that, the first `mount` would become PID 1, exit after a millisecond,
and kill the namespace. So:

* **Stage 1** (`unshare --mount --uts --ipc`) does all the setup work, which needs many forks.
* **Stage 2** (`unshare --pid`) starts a tiny reaper that forks **exactly once**. That child `exec`s
  its way to your command without forking.

Results: `ps aux` inside shows **PID 1 and PID 2 only**, `/proc` is mounted *from inside* the new PID
namespace (required, see viva Q5), and the reaper's `wait` gives the true exit code (137 on OOM).

### 7.4 `box exec web ps aux`

```
nsenter --target <host PID of web's PID 1> --mount --uts --ipc --pid --root --wd -- ps aux
        └ opens /proc/<pid>/ns/{mnt,uts,ipc,pid} and calls setns() on each, then
          chroots to /proc/<pid>/root and forks → ps becomes PID 2 inside the container
```
Before that, the process writes itself into the container's `cgroup.procs`, so exec'd commands obey the limits too.

### 7.5 `box stop web`

```
kill -TERM <hostpid>  →  wait up to 5 s (−t N)  →  still alive?  →  kill -KILL <hostpid>
→ PID 1 dies → kernel kills the rest of the namespace → mount namespace freed → mounts gone
→ supervisor records the exit code → cgroup killed + rmdir → STATUS=exited
```
`sleep` has no SIGTERM handler, and PID 1 ignores un-handled signals, so it needs SIGKILL (exit 137).
A container whose PID 1 runs `trap 'exit 0' TERM` stops gracefully with exit 0.

### 7.6 What happens on a crash (`kill -9` of the engine)

| Thing | Who cleans it | How |
|---|---|---|
| Mounts | **kernel** | the mount namespace dies with its last process |
| Container processes | **kernel** | `PR_SET_PDEATHSIG` kills PID 1 when the reaper dies; PID 1's death kills the namespace |
| cgroup directory + state | `box cleanup` | finds `Dead (stale)` containers, writes `cgroup.kill`, `rmdir`s |

---

## 8. Code breakdown: understanding the source

The engine `box` is divided into numbered sections (search for `§` in the file).

### §0 Header and configuration

```bash
set -Eeuo pipefail        # exit on error (-e), unset vars are errors (-u), pipeline errors count (pipefail)
shopt -s nullglob         # an unmatched glob expands to nothing (safe loops over empty dirs)
: "${BOX_ROOT:=/var/lib/ushell-box}"   # default value unless set in the environment
readonly E_OK=0 E_USAGE=1 E_PERM=2 E_RUNTIME=3    # deterministic exit codes
```

### §1 Presentation: colours and logging
* `setup_colors`: ANSI colours **only if** stderr is a terminal (`[[ -t 2 ]]`) and `NO_COLOR` is unset.
* `info / ok / warn / err / die`: all print to **stderr** (`>&2`). stdout is reserved for data such as
  tables and IDs, so `id=$(box run -d …)` captures only the ID.

### §2 Signal handling and the cleanup stack

```bash
cleanup_push rm -rf -- "$work"        # register an undo action
trap 'cleanup INT' INT                # Ctrl+C
trap 'cleanup EXIT' EXIT              # any exit, including set -e failures
```
`cleanup()` runs the registered actions **last-in-first-out**, ignores further Ctrl+C while working,
and exits with 130/143/129 for INT/TERM/HUP.

### §3 Privilege handling
`require_root`: if `EUID ≠ 0` and sudo is usable, `exec sudo … "$SELF" "${ORIG_ARGS[@]}"` re-runs the
same command as root. Otherwise it exits with code **2**. `in_userns` detects rootless test mode.

### §4 Utilities
`gen_id` (random hex via `od`), `parse_size` (regex `^([0-9]+)([KMG]?)…$` → bytes), `human`
(bytes → MiB with awk), `duration`, `proc_starttime` (field 22 of `/proc/PID/stat`, to detect PID reuse).

### §5 State store
* `state_get ID KEY`: `awk -F=` lookup. The file is **never `source`d**, so it can't run code.
* `state_set ID K V …`: rewrites through awk into a temp file, then `mv` (atomic), under `flock` on fd 9.
* `resolve_container`: accepts a name, a full ID or a unique ID prefix.
* `is_running`: `/proc/PID` exists **and** its start time matches the recorded one.

### §6 cgroups
* `cg_detect`: `stat -fc %T /sys/fs/cgroup` → `cgroup2fs` = v2; a `memory/` cgroupfs = v1; else none.
* `cg_create`: v2 enables `+memory +cpu +pids` in `cgroup.subtree_control`, then writes `memory.max`,
  `memory.swap.max`, `cpu.max`, `pids.max`. v1 writes `memory.limit_in_bytes`, `cpu.cfs_quota_us`, … per controller.
* `cg_mem_current / cg_mem_peak / cg_oom_kills / cg_cpu_usec`: read accounting files.
* `cg_destroy`: `cgroup.kill` (or `kill -KILL` each PID), then `rmdir` with retries.

### §7 Images
`resolve_alpine` (awk parses the YAML release index; pinned fallback), `resolve_ubuntu` (grep + `sort -V`
on SHA256SUMS), `cmd_pull` (download → verify → extract → meta → atomic move), `cmd_images`, `cmd_rmi`.

### §8 Container lifecycle: host side
* `prepare_rootfs`: overlay directories, or a full `cp -a` copy if overlayfs is unavailable.
* `supervise`: the heart: cgroup → shim → `find_ns_child` → `wait` → `record_exit`.
* `kill_container`: SIGTERM → grace loop → SIGKILL.
* `sweep_mounts` / `remove_container_dir`: the safety net before any `rm -rf` (`--one-file-system`).
* `container_teardown`: **idempotent** (safe to call any number of times from anywhere).

### §9 Inside the namespaces
* `setup_dev`: tmpfs `/dev`, bind `null zero full random urandom tty`, symlinks `fd stdin stdout stderr`, devpts, shm.
* `mount_volume`: `realpath -m` check so a symlink in the image can't redirect a mount onto the host.
* `container_init`: overlay → sysfs → `/dev` → hostname → `/etc` files → volumes → reaper → PID 1.

### §10 CLI commands
`cmd_run`, `cmd_exec`, `cmd_ps`, `cmd_stats`, `cmd_logs`, `cmd_stop`, `cmd_rm`, `cmd_inspect`,
`cmd_cleanup`, `cmd_info`, `cmd_menu`, `usage`. Each parses its options with `while (( $# )); case $1 in …`.

### §11 Entry point

```bash
main() {
    case $sub in
        help|version) …                       # no root needed
        __init)       container_init "$@" ;;  # internal: runs inside the namespaces
        __supervise)  cmd_supervise "$@" ;;   # internal: detached supervisor
        pull|run|ps|…) require_root; init_dirs; cg_detect; "cmd_$sub" "$@" ;;
    esac
}
```

### `setup.sh` in 8 steps
1. Fix CRLF line endings (`sed -i 's/\r$//'`) and `bash -n` syntax check.
2. Kernel, WSL detection, bash version, architecture.
3. Required tools present (`command -v`).
4. Namespaces (`/proc/self/ns/*`), kernel config flags, and a **live probe**: `unshare --pid … --mount-proc`.
5. cgroup version, controllers, writability.
6. overlayfs; the state directory must not be on a Windows (9p) drive.
7. `chmod +x`, symlink `/usr/local/bin/box`.
8. `box pull alpine`. Exit 3 if any critical check failed.

### `demo.sh` in 4 sections
| Section | Proves | Key checks |
|---|---|---|
| **A** Filesystem jail | chroot + overlay + UTS | Alpine `os-release`, `cd /../../..` stays at `/`, host paths invisible, hostname, image untouched |
| **B** Process isolation | PID namespace + private `/proc` | exactly PID 1 and PID 2 inside; host sees an ordinary PID; `NSpid`; namespace inodes differ; SIGTERM vs SIGKILL |
| **C** cgroups | memory + CPU limits | memory hog killed with 137 at ≤ 50 MiB, `oom_kill` recorded; CPU ≈ 20 % vs ~100 % for a host loop |
| **D** Tear-down | no orphans, even after a crash | `kill -9` engine → 0 mounts → `box cleanup` → 0 cgroups, 0 processes, 0 state |

---

## 9. Installation and how to run

### 9.1 Requirements
* Ubuntu 22.04 or 24.04 (WSL 2 **or** a VMware VM), x86_64 or arm64
* `sudo` access, and internet for the first `box pull`
* Nothing to install: all tools ship with Ubuntu

### 9.2 On WSL 2 (Windows)

```bash
# Open "Ubuntu" from the Start menu (or type `wsl` in PowerShell)
cd ~
git clone <your-repo-url> ushell-box      # or copy the folder from Windows:
# cp -r "/mnt/c/Users/<you>/Documents/GitHub/ushell box" ~/ushell-box
cd ushell-box
sudo ./setup.sh                           # checks + chmod + pull alpine
sudo ./demo.sh                            # the full evaluation
```

> Working from `/mnt/c/…` is also fine. The engine always stores images and containers on the Linux
> filesystem (`/var/lib/ushell-box`), because Windows drives don't support chroot/overlay permissions.

### 9.3 On VMware Ubuntu

```bash
cd ~/ushell-box
sudo ./setup.sh
sudo ./demo.sh
```
If the VM is old and uses cgroup **v1**, `setup.sh` reports "cgroup v1 (legacy/hybrid) — fallback mode"
and everything still works.

### 9.4 If `./setup.sh` says `bash\r: No such file or directory`
The files got Windows line endings. Fix once:
```bash
sed -i 's/\r$//' setup.sh box demo.sh
```

### 9.5 Running without installing the symlink
```bash
sudo bash ./box run alpine
```

### 9.6 Menu mode (lab-manual style)

```bash
sudo box menu
```
```
  ┌──────────────────────────────────────────────────────────────┐
  │              ushell-box  ·  micro-container engine           │
  └──────────────────────────────────────────────────────────────┘
  cgroups v2 · images: alpine · running: 0

  Images       1) Pull an image             2) List images
  Containers   3) Run interactive shell     4) Run detached container
               5) List containers (ps -a)   6) Exec into a container
               7) Live stats                8) Stop a container
               9) Remove a container        l) View container logs
  System       i) System info               c) Cleanup orphans
               d) Run demo.sh               0) Exit
```

---

## 10. How to use it: command cookbook

```bash
# ── images ────────────────────────────────────────────────────────────
sudo box pull alpine                 # ~3.7 MB, checksum verified
sudo box pull ubuntu-mini            # Ubuntu Base 24.04 (~30 MB)
sudo box images

# ── interactive shell ─────────────────────────────────────────────────
sudo box run alpine                  # type: hostname; ps aux; ls /; exit
sudo box run --name lab --mem 64M --cpu 30 alpine

# ── one-shot commands ─────────────────────────────────────────────────
sudo box run --rm alpine cat /etc/os-release
sudo box run --rm alpine sh -c 'echo "I am PID $$ on $(hostname)"'

# ── share a folder (read-only) ────────────────────────────────────────
sudo box run --rm -v "$PWD:/work:ro" alpine ls -l /work

# ── install a package inside (network is shared) ──────────────────────
sudo box run --rm alpine sh -c 'apk add --no-cache curl && curl -sI https://example.com | head -1'

# ── background container ──────────────────────────────────────────────
sudo box run -d --name ticker alpine sh -c 'while :; do date; sleep 2; done'
sudo box ps
sudo box logs -f ticker              # Ctrl+C stops following, not the container
sudo box exec ticker ps aux
sudo box stats ticker
sudo box inspect ticker
sudo box stop ticker
sudo box rm ticker

# ── see the memory limit kill a process ───────────────────────────────
sudo box run --rm --mem 50M alpine awk 'BEGIN { s = "x"; for (k = 0; k < 20; k++) s = s s
    for (i = 1; ; i++) { a[i] = s i; if (i % 10 == 0) { print i " MiB"; fflush() } } }'
echo $?                              # 137 → OOM-killed (prints 10 … 40 MiB first)

# ── see the CPU limit ─────────────────────────────────────────────────
sudo box run -d --name spin --cpu 20 alpine sh -c 'while :; do :; done'
sudo box stats spin                  # ≈ 20 %
sudo box rm -f spin

# ── housekeeping ──────────────────────────────────────────────────────
sudo box ps -a
sudo box cleanup                     # reap anything stale
sudo box cleanup --all               # also delete all stopped containers
sudo box info
```

**Environment variables:**

| Variable | Default | Meaning |
|---|---|---|
| `BOX_ROOT` | `/var/lib/ushell-box` | where images and containers are stored |
| `BOX_STOP_GRACE` | `5` | seconds between SIGTERM and SIGKILL |
| `BOX_PIDS_MAX` | `512` | default `pids.max` |
| `BOX_ROOTFS_MODE` | `auto` | `overlay` or `copy` |
| `BOX_CGROUP` | `auto` | force `v2`, `v1` or `none` |
| `NO_COLOR` | — | `1` disables colours |
| `BOX_QUIET` | — | `1` hides ▸/✔ progress messages |
| `BOX_DEBUG` | — | `1` = full `set -x` trace |

---

## 11. Reading the output

### `box ps`
```
CONTAINER ID  NAME     IMAGE   STATUS     MEM USAGE/LIMIT   PROCS  PID HOST->CTR  COMMAND
0ef9acbf7207  worker   alpine  Up 2m      864.0KiB/64.0MiB  2      1111->1        sh -c while :; do :; done
```
| Column | Meaning | Source |
|---|---|---|
| CONTAINER ID | 12 random hex digits | `/dev/urandom` |
| STATUS | `Up 2m`, `Exited(0) 5s ago`, `OOM-killed …`, `Dead (stale)` | state + liveness check |
| MEM USAGE/LIMIT | current / ceiling | `memory.current` / `memory.max` |
| PROCS | processes in the cgroup | `wc -l < cgroup.procs` |
| PID HOST->CTR | `1111->1`: host PID 1111 is PID 1 inside | `NSpid:` line of `/proc/1111/status` |

### `box inspect`: namespaces
```
pid     pid:[4026532230]       ISOLATED
mnt     mnt:[4026532227]       ISOLATED
uts     uts:[4026532228]       ISOLATED
ipc     ipc:[4026532229]       ISOLATED
net     net:[4026531840]       shared
```
The number in brackets is the namespace's **inode**. It differs from the host's, so the container is isolated.

### Message symbols
`▸` progress · `✔` success · `⚠` warning · `✖` error (all on stderr).

### Exit codes
| Code | Meaning |
|---|---|
| `0` | success |
| `1` | wrong usage: bad option, bad `--mem`, unknown image/container |
| `2` | not root and sudo not possible |
| `3` | runtime error: mount/cgroup/download/checksum failed |
| `137` / `130` / `143` | (foreground `run`) container killed by SIGKILL (OOM/stop) / SIGINT / SIGTERM |
| anything else | the container command's own exit status (e.g. `exit 7` → 7) |

---

## 12. USP syllabus mapping

| Syllabus topic | Where in the project |
|---|---|
| **Shell basics**: shebang, variables, quoting, `$?` `$$` `$!` `$#` `"$@"` | `#!/usr/bin/env bash`; `$!` = shim PID; `$BASHPID` written to `cgroup.procs` |
| **Process creation**: `&`, subshells, `exec` | `( … ) &` shim; `exec unshare`; reaper `"$@" &` |
| **Process control**: `ps`, `kill`, `top`, `pgrep`, `killall` | `box stats` (`ps -o`), `box stop` (`kill -TERM` / `kill -KILL`), `pgrep -P`, `box exec c top` |
| **Jobs**: `jobs`, `wait`, background | `wait "$shim"`; demo section C uses `( loop ) &`, `jobs -l`, `wait` |
| **Signals**: `trap`, `kill -l`, exit 128+N | `install_traps`, `cleanup`, reaper `trap ""`, `kill -l $((rc-128))` |
| **I/O redirection**: `>`, `>>`, `2>&1`, `>&2`, `2>/dev/null`, `<&0` | logs → stderr; `>> console.log 2>&1`; `<&0 &` keeps the TTY |
| **File descriptors** | `{ flock 9; … } 9> .lock` |
| **Pipes** | `printf … \| sort -k1,1n \| cut -f2- \| while read` in `box ps` |
| **Here-documents / here-strings** | `cat > config <<EOF`, `image.meta`, `usage`, menu; `read … <<< "$spec"` |
| **Filters**: `awk`, `sed`, `grep -E`, `sort`, `cut`, `wc -l`, `tr`, `head`, `tail` | state store (awk), YAML parse (awk), CRLF fix (sed), checksum (`cut`), file count (`wc -l`) |
| **File metadata**: `stat -c '%i' '%y'`, inodes | `box images` (inode + mtime), namespace inode comparison, `stat -fc %T` |
| **Permissions**: `chmod`, `chown`, `umask` | `chmod 0711` / `0700`, `chmod +x` in setup, `umask 022`, `tar --numeric-owner` |
| **File tests**: `-d -f -e -s -r -x -L -t -z -n` | everywhere, e.g. `[[ -L $t ]]` blocks symlink escapes |
| **Control flow**: `if`, `case`, `for`, `while`, `until`, `break`, `continue` | all parsers; **menu = `while true` + `case`** |
| **Functions**: `local`, return codes | ~80 functions in `box` |
| **Arrays** | `cmd=()`, `vols=()`, `mapfile -d ''` (NUL-separated argv) |
| **Regular expressions** | `[[ $s =~ ^([0-9]+)([KMG]?) ]]`, `grep -E`, awk patterns |
| **Defensive scripting** | `set -Eeuo pipefail`, `${var:?}`, `--` before paths, atomic `mv`, `rm --one-file-system` |
| **Exit status** | 0/1/2/3 + pass-through |

---

## 13. Applications: where this is used in the real world

| Application | How containers (and these exact kernel features) are used |
|---|---|
| **Docker / Podman / Kubernetes** | the same namespaces + cgroups + overlayfs; ushell-box is a miniature of `runc` |
| **Online judges** (Codeforces, HackerRank, LeetCode) | run untrusted code with memory/CPU/time limits, which is exactly `--mem`/`--cpu`/`--pids` |
| **Auto-grading lab assignments** | run each student's script in a throwaway container so it can't damage the grader |
| **CI/CD pipelines** (GitHub Actions, GitLab CI) | each build runs in a fresh, isolated root filesystem |
| **Microservices / cloud hosting** | many isolated apps share one server; cgroups stop one from starving the others |
| **Testing on other distros** | run Alpine or Ubuntu userlands on any Linux host without a VM |
| **systemd** | every service is placed in its own cgroup (`systemctl status` shows it) |
| **Browser sandboxes** (Chrome) | use PID/network/user namespaces to isolate renderer processes |
| **Reproducible environments** | the same image gives the same files every time |
| **Education** | understanding containers from first principles, which is the purpose of this project |

---

## 14. Testing and results

Tested on **Ubuntu 24.04.4 LTS, WSL 2, kernel 6.6.87, cgroup v2, util-linux 2.39.3, bash 5.2**.

| Test | Expected | Result |
|---|---|---|
| `box pull alpine` | SHA-256 verified, extracted | ✔ 3.24.4, 8.7 MiB, 516 files |
| `ls /` inside | Alpine root | ✔ |
| `cd /../../..; pwd` | stays at `/` | ✔ |
| Host state directory visible inside? | no | ✔ "No such file or directory" |
| `hostname` inside / on host | container name / unchanged | ✔ |
| `ps aux` inside | only PID 1 and PID 2 | ✔ |
| Host view (`NSpid`) | e.g. `1233 → 1` | ✔ |
| PID-namespace inodes | different | ✔ |
| `--mem 50M` memory hog | killed, exit 137, peak ≤ 50 MiB | ✔ peak **50.0 MiB**, `oom_kill 1`, exit **137** |
| `--cpu 20` busy loop | ≈ 20 % | ✔ **19.6–19.9 %** |
| `box stop` on `sleep` (no handler) | SIGTERM ignored → SIGKILL | ✔ exit 137 after the 2 s grace |
| `box stop` on `trap 'exit 0' TERM` | graceful | ✔ exit 0 |
| SIGTERM to the foreground engine | full teardown | ✔ exit 143, cgroup removed |
| `kill -9` supervisor + reaper | no orphan mounts; container dies | ✔ 0 mounts; `box cleanup` reaps the cgroup |
| Read-only volume | write refused | ✔ "Read-only file system" |
| Exit-code pass-through | `exit 7` → 7 | ✔ |
| Bad arguments / unknown names / no TTY | exit 1 | ✔ |
| Not root, no sudo | exit 2 | ✔ |
| `demo.sh -y` | all checks pass | ✔ **21/21** (+ section C, which needs real root) |

---

## 15. Limitations and future scope

| Limitation | Why it matters | Future improvement |
|---|---|---|
| `chroot` instead of `pivot_root` | root with `CAP_SYS_CHROOT` can escape a chroot | `pivot_root` + unmount the old root |
| No **user** namespace | root inside = real root | `CLONE_NEWUSER` + uid/gid maps (rootless containers) |
| No **network** namespace | shares host network and ports | `CLONE_NEWNET` + veth pair + bridge + NAT (`ip`, `iptables`) |
| All capabilities kept | container root can e.g. load kernel modules | drop with `setpriv --bounding-set` (keep Docker's ~14) |
| No seccomp | all syscalls allowed | seccomp-bpf filter |
| Only 2 images | — | `box pull <url>`, or import a `docker export` tarball |
| No image building | — | a mini "Boxfile" (`FROM`, `RUN`, `COPY`) |
| No port mapping, no restart policy | — | `--publish`, `--restart` |

---

## 16. Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `bash\r: No such file or directory` | Windows CRLF line endings | `sed -i 's/\r$//' setup.sh box demo.sh` |
| `must run as root` (exit 2) | no sudo | prefix commands with `sudo` |
| `image 'alpine' not found` | not pulled yet | `sudo box pull alpine` |
| `cgroups unavailable — cannot enforce --mem/--cpu` | no cgroup access | `sudo box info`; run on a normal Ubuntu host |
| `overlay mount failed` | filesystem doesn't support overlay | `sudo BOX_ROOTFS_MODE=copy box run …` |
| `Dead (stale)` in `box ps -a` | engine was killed hard | `sudo box cleanup` |
| `name 'x' is already used` | old stopped container | `sudo box rm x` |
| download fails | no internet / proxy | check `curl -I https://dl-cdn.alpinelinux.org` |
| need details | — | `sudo BOX_DEBUG=1 box run …` |
| start over completely | — | `sudo box cleanup --all && sudo rm -rf /var/lib/ushell-box` |

---

## 17. Presenting the project: 5-minute demo script

| Time | Do | Say |
|---|---|---|
| 0:00 | show this guide's §1 | "A mini Docker in pure Bash: namespaces, chroot, cgroups." |
| 0:30 | `sudo box info` | "WSL 2 kernel, cgroup v2, overlayfs available." |
| 1:00 | `sudo box run --name viva alpine` then `cat /etc/os-release; hostname; ps aux; exit` | "Different OS, own hostname, and `ps` shows only my shell as PID 1." |
| 2:00 | `sudo box run -d --name bg alpine sleep 600`, then `sudo box ps`, then `ps -ef \| grep 'sleep 600'` | "Inside it is PID 1, but the host sees it as an ordinary process: `NSpid` maps the two." |
| 2:45 | the `--mem 50M` awk command from [§10](#10-how-to-use-it-command-cookbook), then `echo $?` | "It allocates 1 MiB at a time and is killed at 50 MiB: exit 137 = 128 + SIGKILL. WSL is unaffected." |
| 3:30 | `sudo box stop bg` | "SIGTERM is ignored by PID 1 without a handler, so after the grace period we send SIGKILL." |
| 4:00 | `grep -c ushell-box /proc/mounts` | "Zero. Mounts lived in the container's mount namespace; the kernel freed them." |
| 4:30 | `sudo ./demo.sh -y` (or show its summary) | "Automated proof: every check passes." |

---

## 18. Viva questions and answers

> Click **▶ Answer** to reveal. Deeper versions of Q1–Q20 are in [`VIVA_PREP.md`](VIVA_PREP.md).

### Part A — About the project

**Q1. What is your project in one sentence?**
<details><summary>▶ Answer</summary>

A container engine written in Bash that runs programs in an isolated root filesystem with their own
PID numbering, hostname and IPC, and enforces memory/CPU limits with cgroups, using only standard
Linux tools (`unshare`, `chroot`, `mount`, `nsenter`, cgroup files).
</details>

**Q2. What is a container? How is it different from a virtual machine?**
<details><summary>▶ Answer</summary>

A container is a normal process with a restricted view of the system (namespaces), limited resources
(cgroups) and its own root filesystem (chroot). A VM runs a **separate kernel** on virtual hardware.
Containers **share the host kernel**, so they start in milliseconds and use MBs, but isolation is weaker.
</details>

**Q3. Difference between `chroot` and Docker's namespaces?**
<details><summary>▶ Answer</summary>

`chroot` changes **only the root directory**: the process still sees all host processes, network and
hostname, and root can escape it. Namespaces isolate **PIDs, mounts, network, hostname, IPC, users**.
Docker also adds cgroups, `pivot_root`, dropped capabilities and seccomp. ushell-box combines chroot
with PID/mount/UTS/IPC namespaces and cgroups.
</details>

**Q4. Which namespaces do you use, and which not? Why?**
<details><summary>▶ Answer</summary>

Used: **PID, mount, UTS, IPC**. Not used: **net** (so the container has internet for `apk add`) and
**user** (root inside = real root; simpler). `box inspect` shows each namespace inode as ISOLATED or shared.
</details>

**Q5. Why must you `mount -t proc` inside a new PID namespace?**
<details><summary>▶ Answer</summary>

`ps` reads `/proc`. A procfs shows the processes of the PID namespace of **whoever mounted it**.
The inherited `/proc` belongs to the host, so `ps` would list all host processes. A fresh procfs
mounted *from inside* the new namespace shows only the container's processes, starting at PID 1.
</details>

**Q6. Difference between `fork()`, `clone()` and `unshare()`?**
<details><summary>▶ Answer</summary>

`fork()` creates a copy of the process that shares all namespaces. `clone(flags)` is the general
version: flags choose what to share (memory → threads) and which **new namespaces** the child gets.
`unshare(flags)` creates **no process**; it moves the *caller* into new namespaces, except for PID,
where only future **children** enter it. (`setns()` joins an existing namespace; that's `nsenter`.)
</details>

**Q7. Why do you use `unshare` twice?**
<details><summary>▶ Answer</summary>

After `unshare --pid`, the **first child** becomes PID 1. Setup needs many forks (`mount`, `mkdir`), and
the first would become PID 1 and kill the namespace when it exits. So setup runs in stage 1
(mount/UTS/IPC). Stage 2 creates the PID namespace with a reaper that forks exactly once, and that child
`exec`s to the user command. This keeps the command as PID 1 and gives the true exit code.
</details>

**Q8. What is special about PID 1 in a namespace?**
<details><summary>▶ Answer</summary>

(1) It ignores signals it has no handler for, even `kill -9` from inside. (2) Orphans are re-parented to
it, so it must reap zombies. (3) When it dies, the kernel SIGKILLs every process in the namespace.
</details>

**Q9. How do `SIGTERM` and `kill -9` work across namespace boundaries?**
<details><summary>▶ Answer</summary>

A container can't see host PIDs, so it can't signal them. The host can see container processes by their
host PIDs. For the container's PID 1, the host's SIGTERM is delivered **only if PID 1 has a handler**,
but **SIGKILL and SIGSTOP are always delivered** from an ancestor namespace. That's why `box stop` sends
SIGTERM, waits, then sends SIGKILL.
</details>

**Q10. What are cgroups? How do v1 and v2 differ?**
<details><summary>▶ Answer</summary>

Control groups limit and account for resources of a group of processes via files in `/sys/fs/cgroup`.
**v1:** a separate tree per controller (`memory/`, `cpu/`), files like `memory.limit_in_bytes` and
`cpu.cfs_quota_us`. **v2:** one unified tree, controllers enabled through `cgroup.subtree_control`,
files `memory.max` and `cpu.max`, the "no internal processes" rule, plus PSI pressure files and
`cgroup.kill`. ushell-box detects v2 with `stat -fc %T /sys/fs/cgroup` = `cgroup2fs` and falls back to v1.
</details>

**Q11. How exactly does `--mem 50M` stop a process?**
<details><summary>▶ Answer</summary>

`52428800` is written to `memory.max` before start, and the container joins the cgroup. At the limit,
the kernel tries to reclaim memory and then the **cgroup's OOM killer** sends SIGKILL to a process in
that group only. Exit **137**, `memory.events: oom_kill 1`. `memory.swap.max=0` stops it from simply
swapping instead of dying.
</details>

**Q12. How does `--cpu 20` work?**
<details><summary>▶ Answer</summary>

`cpu.max = "20000 100000"`: the group may use 20 ms of CPU every 100 ms period. Once used up, it is
**throttled** until the next period, which gives ≈ 20 % of one core. Measured: 19.6–19.9 %.
</details>

**Q13. What is overlayfs, and why use it?**
<details><summary>▶ Answer</summary>

It merges a read-only **lower** directory (the image) with a writable **upper** directory. Writes are
copied up into upper and deletes become whiteouts. The downloaded image is never modified and can be
shared by many containers, the same as Docker's layers.
</details>

**Q14. How do you guarantee mounts are never left orphaned?**
<details><summary>▶ Answer</summary>

All mounts are created inside the container's **private mount namespace**, so the host never sees
them. When the namespace's last process exits, the **kernel** destroys the namespace and all its mounts,
even if the engine was `kill -9`ed. `PR_SET_PDEATHSIG` makes sure the container dies with its parent.
Traps and `box cleanup` handle the rest (cgroups and state).
</details>

**Q15. What happens if someone runs `kill -9` on your engine?**
<details><summary>▶ Answer</summary>

Traps can't run (SIGKILL is uncatchable), but mounts vanish with the namespace, and the container is
killed by pdeathsig. Only the cgroup directory and state remain; `box ps -a` shows `Dead (stale)`, and
`box cleanup` removes them. Demo section D proves it.
</details>

**Q16. How does `box exec` enter a running container?**
<details><summary>▶ Answer</summary>

`nsenter --target <hostpid> --mount --uts --ipc --pid --root --wd` opens `/proc/<pid>/ns/*`, calls
`setns()` for each, chroots to the container's root and forks, so the new process is PID 2 (or higher) inside.
</details>

**Q17. How does `box ps` know the container PID for a host PID?**
<details><summary>▶ Answer</summary>

From the `NSpid:` line in `/proc/<hostpid>/status` (e.g. `NSpid: 1233 1`), extracted with
`awk '/^NSpid:/{print $NF}'`. Memory comes from `memory.current`, and the process count from `wc -l < cgroup.procs`.
</details>

**Q18. How do you avoid confusing a recycled PID with your container?**
<details><summary>▶ Answer</summary>

The process start time (field 22 of `/proc/<pid>/stat`) is stored at launch. `is_running` requires both
that `/proc/<pid>` exists **and** that its start time matches.
</details>

**Q19. Is your engine secure? How would you harden it?**
<details><summary>▶ Answer</summary>

It's a learning tool, not a security boundary. To harden it: `pivot_root` instead of chroot, a user
namespace (rootless), drop capabilities, a seccomp filter, and a network namespace with veth. Already
done: checksum verification, symlink-escape checks, `rm --one-file-system`, `pids.max`, read-only sysfs,
minimal `/dev`, state files never `source`d.
</details>

**Q20. Where are containers used in real life?**
<details><summary>▶ Answer</summary>

Docker/Kubernetes, CI/CD runners, online judges and auto-graders (run untrusted code with limits),
microservices, systemd services (cgroups), and browser sandboxes (namespaces).
</details>

### Part B — Shell-scripting questions examiners like to ask

**Q21. What does `set -euo pipefail` do?**
<details><summary>▶ Answer</summary>

`-e`: exit on an unhandled error. `-u`: error on unset variables. `pipefail`: a pipeline fails if
**any** stage fails. Pitfall found in this project: `cmd | awk '{…; exit}'` makes `cmd` die of SIGPIPE
(141), and pipefail then aborts the script.
</details>

**Q22. What is `trap`? Which signals cannot be trapped?**
<details><summary>▶ Answer</summary>

`trap 'cmd' SIGNAL` runs `cmd` when the signal arrives; `EXIT` runs on any exit. ushell-box uses
`trap 'cleanup INT' INT`, etc. **SIGKILL (9) and SIGSTOP (19)** can't be trapped or ignored.
</details>

**Q23. Difference between `$*` and `"$@"`?**
<details><summary>▶ Answer</summary>

`"$@"` expands to each argument as a **separate** word (preserves spaces inside arguments). `"$*"`
joins all arguments into **one** string. Containers' commands are passed with `"${cmd[@]}"` so
`sh -c 'echo hi'` stays exactly 3 arguments.
</details>

**Q24. What are `$?`, `$$`, `$!`, `$#`, `$BASHPID`?**
<details><summary>▶ Answer</summary>

`$?` exit status of the last command · `$$` PID of the main shell · `$!` PID of the last background job
(the shim) · `$#` number of arguments · `$BASHPID` PID of the *current* subshell (written to `cgroup.procs`).
</details>

**Q25. What does the `exec` builtin do?**
<details><summary>▶ Answer</summary>

It **replaces** the shell process with a new program **without creating a new process** (same PID).
ushell-box uses chains of `exec` so the user's command keeps the PID that became PID 1. `exec 9>file`
(without a command) instead opens a file descriptor.
</details>

**Q26. Difference between `( … )` and `{ …; }`?**
<details><summary>▶ Answer</summary>

`( … )` runs in a **subshell** (a forked child), so variable changes and `cd` don't affect the parent.
`{ …; }` runs in the **current** shell. The shim uses `( … ) &` so it can join the cgroup and then `exec`.
</details>

**Q27. Explain `2>&1`, `>&2` and `2>/dev/null`.**
<details><summary>▶ Answer</summary>

`2>&1` sends stderr to wherever stdout goes. `>&2` sends stdout to stderr (used for all log messages).
`2>/dev/null` throws errors away. Order matters: `>f 2>&1` sends both to f, but `2>&1 >f` sends only stdout to f.
</details>

**Q28. What is a here-document? A here-string?**
<details><summary>▶ Answer</summary>

Here-doc `<<EOF … EOF` feeds a multi-line block to a command's stdin (`cat > config <<EOF`).
Here-string `<<< "$var"` feeds one string (`IFS=: read -r a b c <<< "$spec"`).
</details>

**Q29. What is an inode? How do you see it?**
<details><summary>▶ Answer</summary>

The data structure that stores a file's metadata (owner, permissions, size, timestamps, block
pointers), not its name. `ls -i` or `stat -c '%i' file` shows it. `box images` prints the rootfs inode,
and namespaces are also identified by inode (`stat -L -c %i /proc/PID/ns/pid`).
</details>

**Q30. What does `chmod 755` mean? `chmod 0700`?**
<details><summary>▶ Answer</summary>

Octal digits for owner/group/others with r=4, w=2, x=1. `755` = rwx r-x r-x. `0700` = rwx for the
owner only, used for container state directories. `0711` (BOX_ROOT) lets others traverse but not list.
</details>

**Q31. What is the difference between a zombie and an orphan process?**
<details><summary>▶ Answer</summary>

**Zombie:** the process has exited, but its parent hasn't `wait()`ed for its exit status yet.
**Orphan:** the parent has died while the child is still running; it is re-parented to init (PID 1)
or the nearest subreaper. Inside a container, the container's PID 1 adopts orphans.
</details>

**Q32. What do `jobs`, `wait`, `&`, `fg`, `bg` do?**
<details><summary>▶ Answer</summary>

`cmd &` runs a command in the background · `jobs` lists background jobs · `wait [pid]` blocks until it finishes
and returns its status · `fg`/`bg` move a job to the foreground/background (interactive shells).
The demo uses `&`, `jobs -l` and `wait`; the engine uses `wait "$shim"`.
</details>

**Q33. Explain the awk command `awk -F= '$1 == k { print $2 }'`.**
<details><summary>▶ Answer</summary>

`-F=` makes `=` the field separator. For each line, if field 1 equals the variable `k`, print field 2.
This is how `state_get` reads `KEY=VALUE` config files.
</details>

**Q34. `[ ]` vs `[[ ]]`?**
<details><summary>▶ Answer</summary>

`[` is a command (POSIX test). `[[ ]]` is Bash syntax: no word-splitting of variables, and it supports
`&&`, `||`, pattern matching (`==` with globs) and regex (`=~`). ushell-box uses `[[ ]]`, e.g.
`[[ $s =~ ^([0-9]+)([KMG]?) ]]` to parse `50M`.
</details>

**Q35. Why are logs written to stderr and data to stdout?**
<details><summary>▶ Answer</summary>

So output can be piped or captured cleanly: `id=$(box run -d …)` gets only the ID, and
`box ps | grep alpine` isn't polluted by progress messages, while the user still sees them on screen.
</details>

---

## 19. Glossary

| Term | Meaning |
|---|---|
| **Container** | an isolated process (namespaces + cgroups + own root filesystem) |
| **Image** | a directory/tarball holding a complete root filesystem (e.g. Alpine) |
| **Rootfs** | the root filesystem a container sees as `/` |
| **Namespace** | kernel feature giving a process a private view of one resource |
| **cgroup** | kernel feature limiting/accounting resources for a group of processes |
| **OOM killer** | kernel mechanism that kills a process when memory runs out (here, per cgroup) |
| **overlayfs** | union filesystem: read-only lower + writable upper = merged view |
| **chroot** | change the root directory of a process |
| **pivot_root** | swap the root mount of a mount namespace (more secure than chroot) |
| **procfs** (`/proc`) | virtual filesystem exposing processes and kernel info |
| **sysfs** (`/sys`) | virtual filesystem exposing devices, kernel objects and cgroups |
| **tmpfs** | in-memory filesystem |
| **bind mount** | make a directory visible at a second location |
| **mount propagation** | whether mounts spread between namespaces (`private` = they don't) |
| **PID 1 / init** | the first process of a PID namespace: reaps orphans, special signal rules |
| **Supervisor** | the `box` process that launches, waits for and cleans up a container |
| **Shim / reaper** | intermediate processes that create namespaces and wait for PID 1 |
| **pdeathsig** | `PR_SET_PDEATHSIG`: signal a process receives when its parent dies |
| **NSpid** | line in `/proc/PID/status` listing the PID in each nested namespace |
| **SHA-256** | cryptographic hash used to verify a download wasn't corrupted/tampered with |
| **WSL 2** | Windows Subsystem for Linux, a real Linux kernel in a lightweight VM |

---

## 20. Cheat sheet

```
┌──────────────────────────────── ushell-box cheat sheet ────────────────────────────────┐
│ SETUP      sudo ./setup.sh             DEMO      sudo ./demo.sh [-y]                     │
│ MENU       sudo box menu               INFO      sudo box info                           │
│                                                                                          │
│ IMAGES     box pull alpine | ubuntu-mini        box images        box rmi <img>          │
│ RUN        box run [-n name] [-m 50M] [-c 20] [-p 100] [-v h:c[:ro]] [-d] [--rm] img cmd │
│ MANAGE     box ps [-a]   box exec n cmd   box stats n   box logs [-f] n   box inspect n  │
│ STOP       box stop [-t secs] n           box rm [-f] n          box cleanup [--all]     │
│                                                                                          │
│ EXIT       0 ok · 1 usage · 2 not root · 3 runtime · 137 SIGKILL/OOM · 130 ^C · 143 TERM │
│                                                                                          │
│ KERNEL     PID+mnt+UTS+IPC namespaces · chroot · overlayfs · cgroup v2 (v1 fallback)     │
│ FILES      memory.max  memory.swap.max  cpu.max  pids.max  cgroup.procs  memory.events   │
│ KEY IDEAS  1st child after unshare --pid = PID 1 · /proc must be mounted from inside     │
│            PID 1 ignores un-handled signals · SIGKILL from host always works             │
│            mounts live in the container's mount ns → kernel frees them on exit           │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

---

<p align="center"><i>ushell-box · B24EF0506 UNIX Shell Programming Lab · REVA University</i></p>
