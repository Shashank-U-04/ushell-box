# ushell-box — Viva Preparation

20 high-probability questions for **B24EF0506 UNIX Shell Programming Lab**, with concise, technically
accurate answers. Every answer is tied to something you can **show live** with `box` or `demo.sh`.

> Tip: answer in three beats: **definition → how ushell-box uses it → proof on screen**.

---

### Q1. What is a container, and how is it different from a virtual machine?

A container is an **ordinary Linux process** that the kernel shows a restricted view of the system:
its own PID numbers, mount table, hostname and so on (**namespaces**). Its resources are capped
(**cgroups**), and its root filesystem is a separate directory tree (**chroot/pivot_root**).

A VM runs a **separate kernel** on virtualised hardware, managed by a hypervisor. Containers **share the
host kernel**, so they start in milliseconds and cost megabytes, not gigabytes. The trade-off is weaker
isolation: a kernel bug affects every container.

*Show:* `box run -d --name x alpine sleep 600`, then `ps -ef | grep 'sleep 600'` on the host. It's just a process.

---

### Q2. What is the difference between `chroot` and Docker's namespaces? ★

| | `chroot` | Docker (namespaces + more) |
|---|---|---|
| What changes | only the process's **root directory** used for path lookup | PID, mount, network, UTS, IPC, user, cgroup **views** |
| Processes | still sees and can signal every host process | sees only its own (PID 1 = its command) |
| Network, hostname, IPC | shared with host | separate |
| Resource limits | none | cgroups |
| Security | root can **escape** (`mkdir d; chroot d; cd ../../..; chroot .`) | `pivot_root` + dropped capabilities + seccomp + AppArmor |
| Mount table | shared, so a mount affects the host | private mount namespace |

`chroot` is a **filesystem jail only**. ushell-box combines `chroot` with PID/mount/UTS/IPC namespaces
and cgroups. That is why `ps aux` inside shows 2 processes, even though `chroot` alone would show hundreds.

---

### Q3. What are Linux namespaces? Which ones does ushell-box use?

A namespace wraps a global system resource so that processes inside see their own isolated instance.
Linux has 8: **mnt** (2002), **uts**, **ipc**, **pid**, **net**, **user**, **cgroup**, **time**.
Each process's memberships are visible as symlinks in `/proc/<pid>/ns/`, and the **inode number**
identifies the namespace.

ushell-box uses **pid, mnt, uts, ipc**. It deliberately shares **net** (so `apk add` works), **user**
(root is real root) and **cgroup**.

*Show:* `box inspect <name>` prints each namespace inode and whether it is `ISOLATED` or `shared`.

---

### Q4. Difference between `fork()`, `clone()` and `unshare()`? ★

* **`fork()`** creates a child that is a copy of the parent (copy-on-write memory). The child shares
  all of the parent's namespaces. (glibc implements it with `clone()`.)
* **`clone(flags)`** is the general primitive. Flags choose what the child **shares** with the parent
  (`CLONE_VM`, `CLONE_FILES`, … which is how threads are made) and which **new namespaces** it gets
  (`CLONE_NEWPID`, `CLONE_NEWNS`, `CLONE_NEWUTS`, …).
* **`unshare(flags)`** creates **no process**. It moves the *calling* process into new namespaces.
  Exception: `CLONE_NEWPID` doesn't move the caller, only its **future children**.
* (**`setns(fd)`** joins an *existing* namespace via `/proc/<pid>/ns/*`, which is how `box exec`/`nsenter` work.)

In ushell-box: `( … ) &` is a fork, `exec unshare --mount --uts --ipc` is `unshare(2)` + `execve(2)`,
`exec unshare --pid` is `unshare(CLONE_NEWPID)`, and the reaper's `"$@" &` fork creates PID 1.

---

### Q5. Why is `mount -t proc` required inside a new PID namespace? ★

`ps`, `top` and `kill` don't ask the kernel for a process list. They **read the `/proc` directory**.
A procfs instance shows the processes of the **PID namespace of whoever mounted it**. After
`unshare --pid`, the inherited `/proc` still belongs to the *host's* namespace, so `ps` would list
every host process (with host PIDs) and break the illusion. Mounting a **fresh** procfs from inside the
new namespace makes `/proc` contain only the container's processes, numbered from 1.

In ushell-box, `unshare --mount-proc=<rootfs>/proc` runs **as PID 1** (it must be *inside* the PID
namespace), just before `chroot`.

*Show:* `box exec demo ps aux` lists only PID 1 and PID 2.

---

### Q6. Why does `unshare --pid` usually need `--fork`? Why does ushell-box use two stages?

Because `unshare(CLONE_NEWPID)` doesn't move the caller, only its **next children**, and **the first
child becomes PID 1**. If PID 1 exits, the namespace is dead and further forks fail.

ushell-box therefore does all forking setup work (`mount`, `mkdir`, `hostname`) **before**
`unshare --pid`. Then a reaper forks **exactly once**, and that child `exec`s through
`setpriv → unshare --mount-proc → env → chroot → command` without forking. Result: the user's command
*is* PID 1, and the reaper's `wait` gets its true exit status.

---

### Q7. What is special about PID 1 inside a PID namespace?

1. **Signal protection:** the kernel drops signals sent to PID 1 *unless PID 1 installed a handler*. Even
   `kill -9` from *inside* the namespace is ignored.
2. **Orphan reaper:** orphaned processes in the namespace are re-parented to it, and it must `wait()` for
   them or they stay zombies.
3. **Namespace lifetime:** when PID 1 dies, the kernel **SIGKILLs every other process** in the namespace.

*Show:* in `demo.sh` section B, `box stop` on `sleep` (no handler) waits out the grace period and
needs SIGKILL. `demo-trap` (with `trap … TERM`) exits gracefully with code 0.

---

### Q8. How do signals (`SIGTERM`, `kill -9`) propagate across namespace boundaries? ★

* A process can only signal PIDs it can **see**. A container can't name host processes, so it can't
  signal them.
* The host (ancestor namespace) **can** see container processes under their host PIDs, so
  `kill <hostpid>` works with normal permission checks.
* Exception for the container's **PID 1**: from the ancestor namespace, only signals PID 1 **has a
  handler for** are delivered. **SIGKILL and SIGSTOP are always forcibly delivered** from an ancestor.
  (The receiver sees `si_pid = 0` because the sender has no PID in its namespace.)
* When PID 1 dies, the kernel sends SIGKILL to all remaining processes in that namespace.

This is exactly why `box stop` does **SIGTERM → grace period (`-t`, default 5 s) → SIGKILL** on the host PID.

---

### Q9. What are cgroups? How does cgroups v1 differ from v2? ★

**Control groups** organise processes into a hierarchy and let controllers **account for and limit**
resources (memory, CPU, PIDs, I/O) per group. They are driven entirely through files: `mkdir`
creates a group, writing a PID to `cgroup.procs` moves a process, and writing limit files sets limits.

| | cgroup v1 (legacy) | cgroup v2 (unified, default since Ubuntu 21.10) |
|---|---|---|
| Hierarchies | **one per controller** (`/sys/fs/cgroup/memory`, `/cpu`, …) | **single** tree at `/sys/fs/cgroup` |
| Membership | a process can be in different groups per controller | one group for all controllers |
| Enabling controllers | implicit by mount | explicit: `echo +memory > cgroup.subtree_control` |
| Memory limit | `memory.limit_in_bytes` (+ `memsw`) | `memory.max`, `memory.high`, `memory.swap.max` |
| CPU limit | `cpu.cfs_quota_us` + `cpu.cfs_period_us` | `cpu.max` = `"quota period"` |
| Rules | processes allowed in inner nodes | **"no internal processes"**: only leaves hold processes |
| Extras | — | PSI `*.pressure`, `cgroup.kill`, safe delegation, `memory.events` |

ushell-box checks `stat -fc %T /sys/fs/cgroup`: `cgroup2fs` means v2, a `cgroupfs` memory directory means v1.

---

### Q10. How is `--mem 50M` enforced? What happens at the limit?

`box` writes `52428800` to `memory.max` **before** the container starts, then puts the shim's PID in
`cgroup.procs`. Every descendant inherits the group. When usage reaches the ceiling, the kernel first
**reclaims** (page cache, …). If that fails, the **cgroup-local OOM killer** sends **SIGKILL** to a
process in that group only, never to host processes.

* Exit status **137 = 128 + 9 (SIGKILL)**. `memory.events` gets `oom_kill 1`, and `memory.peak` stays ≤ the limit.
* `memory.swap.max = 0` is set because otherwise (e.g. WSL has swap) the hog would be **swapped out and
  crawl** instead of being killed. The cap would no longer be a real cap.

*Show:* `demo.sh` section C allocates 1 MiB at a time and dies at about 45–50 MiB with exit 137, while the host is unaffected.

---

### Q11. How does `--cpu 20` limit CPU?

It uses the CFS **bandwidth controller**: `cpu.max = "20000 100000"` means 20 000 µs of CPU time per
100 000 µs period. Once the group uses its quota, all its threads are **throttled** until the next
period, giving ≈ 20 % of one core. (`--cpu 150` = 1.5 cores.) `cpu.stat` shows `usage_usec`,
`nr_throttled` and `throttled_usec`. `box stats` samples `usage_usec` over 1 s to compute the percentage.

---

### Q12. What is overlayfs, and why doesn't a container modify the image?

Overlayfs merges a read-only **lowerdir** (the image) with a writable **upperdir** into a **merged** view.
Reading a file comes from lower. Writing triggers **copy-up** into upper. Deleting creates a
**whiteout** in upper. ushell-box mounts it with `lowerdir=images/alpine/rootfs`,
`upperdir=containers/<id>/upper` and `workdir=…/work`, then chroots into `merged/`. Many containers
share one pristine image, which is the same idea as Docker layers.

*Show:* demo section A writes `/etc/demo-file` in the container and proves the image doesn't contain it.

---

### Q13. How do you guarantee bind mounts (/proc, /dev, /sys) are never orphaned?

Structurally, not just with traps. Every mount is made **inside the container's private mount
namespace** (`unshare --mount --propagation private` + `mount --make-rprivate /`), so they never appear
in the host's `/proc/mounts`. A mount namespace is **freed by the kernel when its last process exits**,
which unmounts everything in it. That works even if the engine gets `kill -9` and no trap can run.
`PR_SET_PDEATHSIG` (via `setpriv --pdeathsig KILL`) makes sure the container dies if its reaper dies.
Traps then only clean the cgroup and state, and `box cleanup` handles even that after a hard crash.

*Show:* demo section D: `kill -9` the supervisor and reaper → `grep -c ushell-box /proc/mounts` = 0.

---

### Q14. What does `trap` do? Why `EXIT INT TERM`?

`trap 'commands' SIGNALS` runs commands when the shell receives a signal or on the pseudo-signal
`EXIT` (any exit, including `set -e` failures). ushell-box keeps a **LIFO cleanup stack**
(`cleanup_push`), executed once by `cleanup()` from `trap … EXIT`, `INT` (Ctrl+C), `TERM` (`kill`)
and `HUP` (terminal closed).

Inside cleanup it runs `trap '' INT TERM` so a second Ctrl+C can't abort a half-finished teardown,
then exits with 128+signal (130, 143, 129). `SIGKILL` **cannot** be trapped, which is exactly why Q13's
kernel-level guarantee matters.

---

### Q15. Explain `set -Eeuo pipefail`. Any pitfalls?

* `-e`: exit on any unhandled non-zero status
* `-u`: error on unset variables
* `-o pipefail`: a pipeline fails if *any* stage fails, not just the last
* `-E`: ERR traps are inherited by functions

**Pitfalls (real bugs found while building this):**
1. `cmd | awk '…{print; exit}'`: awk quits early, `cmd` dies of **SIGPIPE (141)**, and pipefail +
   `-e` abort the script. Fix: let awk read everything.
2. `-e` is **ignored** inside `if`, `&&`, `||` and functions called from them.
3. `(( n++ ))` returns 1 when `n` was 0, which kills the script, so use `n=$((n+1))`.
4. `local x=$(cmd)` hides cmd's failure; write `local x; x=$(cmd)`.

---

### Q16. Why separate stdout and stderr? What is the difference between `>f 2>&1` and `2>&1 >f`?

stdout (fd 1) is **data** (the `box ps` table, a container id) and stderr (fd 2) is **diagnostics**.
So `id=$(box run -d …)` captures only the id while progress messages still reach the terminal, and
`box ps | grep alpine` isn't polluted. ushell-box logs with `printf … >&2`.

Redirections are processed **left to right**:
* `>f 2>&1`: fd1 goes to f, then fd2 becomes a copy of fd1, so **both go to f**.
* `2>&1 >f`: fd2 becomes a copy of the *current* fd1 (the terminal), then fd1 goes to f, so **stderr still goes to the terminal**.

The detached supervisor uses `>> console.log 2>&1`.

---

### Q17. How does `box exec` get inside a running container?

Each namespace a process belongs to is a file under `/proc/<pid>/ns/`. `nsenter --target <hostpid>
--mount --uts --ipc --pid --root --wd` opens those files and calls **`setns(2)`** for each. It then
forks (a PID namespace only applies to children) and chroots to the target's `/proc/<pid>/root`.
The new process is, for example, PID 2 inside. ushell-box first writes the process into the
container's `cgroup.procs`, so `exec`'d commands are limited too.

---

### Q18. How does `box ps` show "host PID → container PID", and how are cgroup tasks scanned?

`/proc/<hostpid>/status` has a line `NSpid: 1233 1` listing the PID in every nested namespace,
outermost first: `awk '/^NSpid:/{print $NF}'`. `MEM USAGE` comes from `memory.current` (v1:
`memory.usage_in_bytes`). `PROCS` is `wc -l < cgroup.procs`. Rows are built tab-separated, then go
through `sort -k1,1n | cut -f2- | while read` and are formatted with `printf`. Liveness is checked with
`/proc/<pid>` **plus the process start time** (field 22 of `/proc/<pid>/stat`), so a recycled PID is
never mistaken for the container.

---

### Q19. What happens if the engine itself is killed with `kill -9` mid-run?

SIGKILL can't be trapped, so `box` gets no chance to clean up. However:
1. **Mounts** vanish with the mount namespace (kernel).
2. If the reaper dies too, **`PR_SET_PDEATHSIG`** makes the kernel SIGKILL the container's PID 1,
   and the kernel then kills the rest of the PID namespace.
3. Only the cgroup directory and state file remain. `box ps -a` shows **`Dead (stale)`**, and
   `box cleanup` reaps them (`cgroup.kill`, then `rmdir`).

That's demonstrated live in `demo.sh` section D.

---

### Q20. Is ushell-box secure? What would you add to harden it?

No. It's a teaching engine, and its limits are documented:
* **chroot escape**: root inside keeps `CAP_SYS_CHROOT`. Fix: `pivot_root` into the new root and
  unmount the old one.
* **real root inside**: no user namespace. Fix: `CLONE_NEWUSER` with a uid map (rootless containers).
* **all capabilities kept**. Fix: drop with `capsh`/`setpriv --bounding-set`, keeping Docker's default ~14.
* **no syscall filter**. Fix: seccomp-bpf.
* **shared network**. Fix: `CLONE_NEWNET` + a veth pair + a bridge/NAT.

Already in place: image checksum verification, symlink-escape checks for volumes and `/etc` writes,
`rm --one-file-system` after re-checking `/proc/mounts`, no `source`-ing of state files, `pids.max`
fork-bomb guard, `memory.swap.max=0`, read-only sysfs, and a minimal `/dev` (no host disks visible).

---

## Rapid-fire one-liners

| Question | Answer |
|---|---|
| Exit code 137? | 128 + 9 = SIGKILL (OOM killer or `kill -9`) |
| Exit 130 / 143? | SIGINT (Ctrl+C) / SIGTERM |
| Where are namespaces visible? | `/proc/<pid>/ns/*`, compared by inode (`stat -L -c %i`) |
| Hostname isolation? | UTS namespace + `sethostname(2)` |
| `$$` vs `$BASHPID`? | `$$` = main shell PID (same in subshells), `$BASHPID` = current (sub)shell PID |
| Why `<&0 &`? | non-interactive Bash points background jobs' stdin at `/dev/null` unless redirected explicitly |
| Zombie? | exited child not yet `wait()`ed for; PID 1 must reap them |
| Here-doc vs here-string? | `<<EOF` multi-line block · `<<< "$var"` single string on stdin |
| `stat -c '%i %y'`? | inode number, last modification time |
| Default mount propagation risk? | `shared` would leak container mounts to the host; we force `private` |
