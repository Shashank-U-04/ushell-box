# ushell-box

**A zero-dependency, Bash-native micro-container engine.**
Linux namespaces + `chroot` + overlayfs + cgroups, orchestrated entirely from a single Bash script.

> Mini-project · **B24EF0506 — UNIX Shell Programming Lab** · REVA University · 5th Semester B.Tech CSE
>
> 📘 **New here? Start with [`PROJECT_GUIDE.md`](PROJECT_GUIDE.md)**: the complete guide (concepts,
> how it works, code walkthrough, how to run, applications, 35 viva Q&As).

```
$ sudo box run --name demo --mem 50M --cpu 20 alpine sh -c 'hostname; ps aux'
▸ cgroup v2: memory=50.0MiB cpu=20% pids=512
▸ unshare --mount --uts --ipc → setup → unshare --pid → chroot /var/lib/ushell-box/containers/8a2e86cbd744/merged
✔ container 'demo' (8a2e86cbd744) running — host PID 744 ⇄ container PID 1
demo
PID   USER     TIME  COMMAND
    1 root      0:00 sh -c hostname; ps aux
    2 root      0:00 ps aux
▸ container 'demo' exited with code 0
```

---

## Contents

1. [Features](#features)
2. [Quick start](#quick-start)
3. [Command reference](#command-reference)
4. [Architecture](#architecture)
5. [System-call flow](#system-call-flow)
6. [Safety design: why mounts can never be orphaned](#safety-design-why-mounts-can-never-be-orphaned)
7. [USP syllabus mapping](#usp-syllabus-mapping-b24ef0506)
8. [Exit codes](#exit-codes)
9. [Files and on-disk layout](#files-and-on-disk-layout)
10. [Limitations (honest ones)](#limitations)
11. [Troubleshooting](#troubleshooting)

---

## Features

| Area | What ushell-box does |
|---|---|
| **Images** | `box pull alpine` downloads the official Alpine minirootfs (~3.7 MB), **verifies its SHA-256** against Alpine's release index and caches it. `ubuntu-mini` pulls Ubuntu Base 24.04. |
| **Isolation** | New **PID, mount, UTS and IPC** namespaces. Private `/proc`, read-only `/sys`, minimal tmpfs `/dev`, own hostname. |
| **Filesystem** | Copy-on-write **overlayfs** per container: the image is the read-only `lowerdir`, so containers can never damage it. Automatic fallback to a private copy. |
| **Limits** | `--mem` → `memory.max` (+ `memory.swap.max=0`), `--cpu` → `cpu.max`, `--pids` → `pids.max`. **cgroup v2 first, v1 fallback.** |
| **Volumes** | `--vols host:container[:ro]` bind mounts, with symlink-escape checks. |
| **Lifecycle** | `run` (foreground or `-d` detached), `exec` (via `nsenter`), `ps`, `stats`, `logs`, `stop` (SIGTERM → grace → SIGKILL), `rm`, `inspect`, `cleanup`. |
| **Robustness** | `set -Eeuo pipefail`, LIFO cleanup stack run from `trap … EXIT INT TERM HUP`, atomic `flock`-protected state, PID-reuse protection, kernel-guaranteed mount teardown, `PR_SET_PDEATHSIG`. |
| **UX** | Colourised output (honours `NO_COLOR`), data on stdout and diagnostics on stderr, menu-driven TUI (`box menu`), automatic `sudo` re-exec. |

---

## Quick start

### On WSL 2 (Ubuntu 24.04) or a VMware Ubuntu 22.04/24.04 VM

```bash
# 1. get the code (clone into your Linux home, not /mnt/c, for best results)
cd ~ && git clone <your-repo-url> ushell-box && cd ushell-box

# 2. verify the host, chmod +x, link /usr/local/bin/box, pull Alpine
sudo ./setup.sh

# 3. your first container
sudo box run alpine                                   # interactive shell; type `exit` to leave
sudo box run --name web --mem 64M --cpu 25 alpine sh -c 'cat /etc/os-release'

# 4. the automated evaluation (sections A–D, PASS/FAIL per check)
sudo ./demo.sh            # pauses between sections
sudo ./demo.sh -y         # non-stop

# 5. the menu-driven interface
sudo box menu
```

> **Running from `/mnt/c/...`** also works, because image and container data always live on Linux's own
> filesystem under `/var/lib/ushell-box`. If `./setup.sh` fails with `bash\r: No such file`, the files
> were checked out with Windows line endings. Run `sed -i 's/\r$//' setup.sh box demo.sh` once.

### A detached workflow

```bash
sudo box run -d --name worker --mem 64M alpine sh -c 'while :; do date; sleep 2; done'
sudo box ps                       # CONTAINER ID, NAME, STATUS, MEM USAGE/LIMIT, PID HOST->CTR …
sudo box exec worker ps aux       # PID 1 = the loop, PID 2 = ps
sudo box logs -f worker           # Ctrl+C to stop following
sudo box stats worker             # memory, peak, CPU % (1 s sample), process list
sudo box stop worker              # SIGTERM → 5 s grace → SIGKILL → teardown
sudo box rm worker
```

---

## Command reference

```
box pull [--force] [alpine|ubuntu-mini]   download + verify + cache a root filesystem
box images                                list cached images (size, inode, mtime)
box rmi <image>                           delete a cached image

box run [OPTIONS] <image> [cmd...]        create and start a container
    -n, --name <name>           container name (default box-<id>)
    -m, --mem  <size>           memory ceiling: 50M, 256M, 1G         → memory.max
    -c, --cpu  <percent>        CPU quota, % of one core: 20, 150     → cpu.max
    -p, --pids <n>              max processes (default 512)           → pids.max
    -v, --vols <host:ctr[:ro]>  bind mount (repeatable)
    -d, --detach                run in background, print the id
        --rm                    delete state when the container exits

box ps [-a] [-q]                          running (or all) containers
box exec <name|id> [cmd...]               run a command inside a running container
box stats <name|id>                       live cgroup accounting
box logs [-f] <name|id>                   console of a detached container
box stop [-t secs] <name|id>...           graceful stop
box rm [-f] <name|id>...                  remove (force = stop first)
box inspect <name|id>                     state, namespace inodes, live cgroup files
box cleanup [--all]                       reap dead containers, orphan cgroups, stray mounts
box info                                  host capabilities
box menu                                  interactive menu (while true + case)
```

**Environment:** `BOX_ROOT` (default `/var/lib/ushell-box`), `BOX_STOP_GRACE=5`, `BOX_PIDS_MAX=512`,
`BOX_ROOTFS_MODE=auto|overlay|copy`, `BOX_CGROUP=auto|v2|v1|none`, `NO_COLOR=1`, `BOX_QUIET=1`, `BOX_DEBUG=1` (`set -x` trace).

---

## Architecture

```
                          ┌──────────────────────────── HOST (Ubuntu) ───────────────────────────┐
                          │                                                                      │
  user ──► box run ──────►│  supervise()                                                         │
                          │   ├─ prepare_rootfs   upper/ work/ merged/  (overlay on the image)   │
                          │   ├─ cg_create        /sys/fs/cgroup/ushell-box/<id>/                │
                          │   │                     memory.max · memory.swap.max · cpu.max ·     │
                          │   │                     pids.max                                     │
                          │   ├─ fork ─┐                                                         │
                          │   │        │ echo $BASHPID > cgroup.procs    (join cgroup first)     │
                          │   │        │ exec unshare --mount --uts --ipc                        │
                          │   │        ▼                                                         │
                          │   │   ┌──────────── new MOUNT · UTS · IPC namespaces ───────────┐    │
                          │   │   │ box __init <id>                                         │    │
                          │   │   │   mount -t overlay  → merged/                           │    │
                          │   │   │   mount sysfs (ro), tmpfs /dev (+null zero tty …)       │    │
                          │   │   │   mount --bind volumes · hostname <name> · /etc/hosts   │    │
                          │   │   │   exec unshare --pid  ──► reaper (bash, forks once)     │    │
                          │   │   │        ┌────────────── new PID namespace ───────────┐   │    │
                          │   │   │        │ PID 1: env --default-signal                │   │    │
                          │   │   │        │        setpriv --pdeathsig KILL            │   │    │
                          │   │   │        │        unshare --mount-proc=merged/proc    │   │    │
                          │   │   │        │        env -i PATH=…                       │   │    │
                          │   │   │        │        chroot merged/  <your command>      │   │    │
                          │   │   │        └────────────────────────────────────────────┘   │    │
                          │   │   └─────────────────────────────────────────────────────────┘    │
                          │   ├─ find_ns_child    host PID of container PID 1 (NSpid)            │
                          │   ├─ wait             interruptible: traps fire immediately          │
                          │   └─ record_exit      exit code, memory.events oom_kill, peak        │
                          │  trap EXIT INT TERM → container_teardown → kill · rmdir cgroup ·     │
                          │                       sweep mounts · state = exited                  │
                          └──────────────────────────────────────────────────────────────────────┘
```

**Why two `unshare` stages?** `unshare --pid` without `--fork` moves only the caller's *future children*
into the new PID namespace, and the *first* child becomes PID 1. Setup needs many forks (`mount`, `mkdir`, …).
If they ran after `unshare --pid`, the first `mount` would become PID 1, exit, and take the namespace
with it. So setup happens first (stage 1). Then a tiny reaper that forks **exactly once** launches an
**exec-only** chain, which gives three things:

* your command **is** PID 1 (inside `ps aux` shows only PID 1 and PID 2),
* `/proc` is mounted *from inside* the new PID namespace (a procfs instance belongs to the PID
  namespace of the process that mounts it),
* the reaper's `wait` reports the true exit status (`137` = 128 + SIGKILL after an OOM kill). This also
  avoids a util-linux 2.39 bug in `unshare --fork`, which reports `1` after re-raising SIGKILL.

---

## System-call flow

| Step | Shell command | Kernel system call(s) | Effect |
|---|---|---|---|
| 1 | `mkdir /sys/fs/cgroup/ushell-box/<id>` | `mkdir(2)` on cgroupfs | new control group |
| 2 | `echo 52428800 > memory.max` | `write(2)` | memory ceiling (OOM killer at the limit) |
| 3 | `echo "20000 100000" > cpu.max` | `write(2)` | 20 ms CPU per 100 ms period = 20 % |
| 4 | `( … ) &` | `clone(2)` / `fork(2)` | shim process |
| 5 | `echo $BASHPID > cgroup.procs` | `write(2)` | shim and all its descendants are now limited |
| 6 | `exec unshare --mount --uts --ipc` | `unshare(CLONE_NEWNS\|CLONE_NEWUTS\|CLONE_NEWIPC)`, `mount(MS_REC\|MS_PRIVATE)`, `execve(2)` | private mount table, hostname, SysV IPC |
| 7 | `mount -t overlay …` | `mount(2)` | copy-on-write root |
| 8 | `mount -t sysfs`, `mount -t tmpfs`, `mount --bind` | `mount(2)` | /sys, /dev, volumes |
| 9 | `hostname <name>` | `sethostname(2)` | only visible in this UTS namespace |
| 10 | `exec unshare --pid` | `unshare(CLONE_NEWPID)`, `execve(2)` | children will be in a new PID namespace |
| 11 | `"$@" &` (in the reaper) | `clone(2)` | **PID 1** of the new namespace |
| 12 | `setpriv --pdeathsig KILL` | `prctl(PR_SET_PDEATHSIG, SIGKILL)` | dies if the reaper dies |
| 13 | `unshare --mount-proc=…/proc` | `unshare(CLONE_NEWNS)`, `mount("proc")` | procfs for the new PID namespace |
| 14 | `chroot <rootfs> cmd` | `chroot(2)`, `chdir("/")`, `execve(2)` | filesystem jail |
| 15 | `box exec` → `nsenter --target P --mount --uts --ipc --pid --root --wd` | `setns(2)` × 4, `fork(2)`, `chroot(2)`, `execve(2)` | join a running container |
| 16 | `box stop` → `kill -TERM`, `kill -KILL` | `kill(2)` | graceful, then forced |
| 17 | teardown → `echo 1 > cgroup.kill`, `rmdir` | `write(2)`, `rmdir(2)` | cgroup removed |

---

## Safety design: why mounts can never be orphaned

1. **All mounts live in the container's private mount namespace** (`unshare --mount --propagation private`
   plus `mount --make-rprivate /`). The host's `/proc/mounts` never sees them.
2. A mount namespace is destroyed by the **kernel** when its last process exits. Every mount inside
   disappears with it, so no userspace cleanup is needed, even after `kill -9` of the engine.
3. If the reaper is killed, `PR_SET_PDEATHSIG` makes the kernel SIGKILL the container's PID 1. When
   PID 1 of a PID namespace dies, the kernel kills every other process in that namespace.
4. What remains (cgroup directory, state file) is handled by a **LIFO cleanup stack** run from
   `trap 'cleanup …' EXIT INT TERM HUP`. A second Ctrl+C during teardown is ignored (`trap '' INT`).
5. If the engine itself is SIGKILLed (traps can't run), `box ps -a` shows `Dead (stale)` and
   `box cleanup` reaps it: it kills cgroup members, `rmdir`s the cgroup and lazily unmounts anything
   unexpected under `$BOX_ROOT`.
6. Before every `rm -rf` the engine re-checks `/proc/mounts` and uses `--one-file-system`. A
   bind-mounted host folder can never be deleted through a container directory.

`demo.sh` section D proves this live: it `kill -9`s the supervisor and reaper and shows 0 mounts, then
runs `box cleanup` and shows 0 cgroups.

---

## USP syllabus mapping (B24EF0506)

| Syllabus topic | Where it is exercised | Example |
|---|---|---|
| **Process creation** | `supervise()`: `( … ) &`, `exec`, the reaper's `"$@" &` | background shim + `$!` |
| **Process control**: `ps`, `kill`, `top` | `cmd_stats` (`ps -o pid,ppid,rss,pcpu`), `kill_container` (`kill -TERM` → `kill -KILL`), `box exec c top` | SIGTERM, grace, SIGKILL |
| `killall` / `pkill` / `pgrep` | `find_ns_child` (`pgrep -P`), demo (`pgrep -f box-reaper`) | find children by parent |
| **Background jobs**: `&`, `jobs`, `wait` | `supervise()` (`wait "$shim"`), demo section C (`( loop ) &`, `jobs -l`, `wait`) | interruptible wait |
| **Signals and `trap`** | `install_traps`, `cleanup`, reaper `trap "" INT …`, menu Ctrl+C trap | `trap 'cleanup INT' INT` |
| **Redirection**: `>&2`, `2>&1`, `2>/dev/null`, `<&0` | `info/warn/err` → stderr; `setsid … >>log 2>&1`; `<&0 &` keeps the TTY | stdout = data, stderr = logs |
| **File descriptors** | `state_set`: `{ flock 9; … } 9> .lock` | fd 9 as a lock |
| **Pipes** | `cmd_ps`: `printf | sort -t$'\t' -k1,1n | cut -f2- | while read` | multi-stage pipeline |
| **Here-documents** | `cmd_run` (config file), `cmd_pull` (image.meta), `usage`, `menu_banner` | `cat > config <<EOF` |
| **Here-strings** | `IFS=: read -r hp cp mode <<< "$spec"` | volume parsing |
| **`awk`** | `state_get/state_set`, `human`, YAML release-index parser, `cg_oom_kills`, NSpid extraction | `awk '/^NSpid:/{print $NF}'` |
| **`grep -E`** | `resolve_ubuntu` (checksum list), setup kernel-config scan | `grep -E "ubuntu-base-24\.04…"` |
| **`sed`** | version extraction, log indenting, CRLF repair in `setup.sh` | `sed -i 's/\r$//'` |
| **`sort`, `cut`, `wc -l`** | `cmd_ps`, `cmd_pull` (`sha256sum | cut -d' ' -f1`, `find | wc -l`) | |
| **`stat`, inodes** | `cmd_images` (`stat -c '%i'`, `stat -c '%y'`), `fs_type` (`stat -fc %T`), demo (`stat -L -c %i /proc/PID/ns/pid`) | namespace inode comparison |
| **`chmod`, `chown`, permissions** | `init_dirs` (`chmod 0711`), container dirs `0700`, `setup.sh` (`chmod +x`), `umask 022` | |
| **File test operators** `-d -f -e -s -r -x -L -t -z -n` | everywhere, e.g. `[[ -L $t ]]` symlink guard, `[[ -t 2 ]]` colour detection | |
| **`case` and `while true` menus** | `cmd_menu` (lab-manual pattern), every argument parser | |
| **Functions, `local`, arrays, assoc. of state** | whole engine is ~80 small functions; `mapfile -d ''` NUL-separated argv | |
| **Defensive scripting** | `set -Eeuo pipefail`, `shopt -s nullglob`, `${var:?}`, `--` before paths, atomic `mv` | |
| **Exit status** | deterministic 0/1/2/3, plus the container's status | see below |

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | success |
| `1` | bad arguments or usage (unknown option, bad `--mem`, unknown image or container) |
| `2` | permission denied: not root and `sudo` not possible |
| `3` | runtime or isolation error (mount, cgroup, download, checksum, start-up failure) |
| *n* | foreground `box run` returns **the container's own exit status**: `137` = killed by SIGKILL (OOM or `stop`), `130` = SIGINT, `143` = SIGTERM |

---

## Files and on-disk layout

```
ushell-box/
├── box            the engine (single Bash script)
├── setup.sh       host verification + bootstrap
├── demo.sh        automated evaluation (A–D)
├── README.md
└── VIVA_PREP.md   20 viva questions with answers

/var/lib/ushell-box/                    (BOX_ROOT)
├── images/alpine/
│   ├── rootfs/                         pristine, read-only lower layer
│   └── image.meta                      version, SHA-256, source URL
├── containers/<12-hex-id>/
│   ├── config                          KEY=VALUE state (never sourced)
│   ├── cmd                             argv, NUL-separated
│   ├── volumes                         host:ctr:mode per line
│   ├── console.log                     detached containers only
│   ├── upper/  work/                   overlay writable layer
│   └── merged/                         container root (mounted only inside its namespace)
└── tmp/                                partial downloads (removed by trap)

/sys/fs/cgroup/ushell-box/<id>/         v2  (v1: /sys/fs/cgroup/{memory,cpu,pids}/ushell-box/<id>)
```

---

## Limitations

These are deliberate scope limits for a teaching engine, and good viva material:

* **`chroot`, not `pivot_root`.** A process holding `CAP_SYS_CHROOT` can escape a chroot. Docker uses
  `pivot_root`, drops capabilities and applies seccomp.
* **No network namespace.** Containers share the host network (so `apk add` works out of the box).
  `box inspect` shows `net … shared`.
* **No user namespace.** Root in the container is real root (`user … shared`).
* **No capability dropping or seccomp**, for the same reason: this is a learning tool, not a security boundary.
* `box exec` cannot allocate a new pseudo-terminal; it reuses yours.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `bash\r: No such file or directory` | Windows line endings: `sed -i 's/\r$//' setup.sh box demo.sh` |
| `must run as root` (exit 2) | prefix with `sudo`; interactive shells re-exec through sudo automatically |
| `cgroups unavailable — cannot enforce --mem/--cpu` | old kernel or a container without cgroup access; run `box info` and `sudo ./setup.sh` |
| `overlay mount failed` | `BOX_ROOTFS_MODE=copy sudo -E box run …` |
| `Dead (stale)` in `box ps -a` | the engine was killed hard: `sudo box cleanup` |
| want a clean slate | `sudo box cleanup --all && sudo rm -rf /var/lib/ushell-box` |
| debug a failure | `sudo BOX_DEBUG=1 box run …` (full `set -x` trace with function names) |
