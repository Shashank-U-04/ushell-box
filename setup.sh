#!/usr/bin/env bash
# =============================================================================
#  setup.sh — verify the host and bootstrap ushell-box
#
#    1. fixes Windows CRLF line endings (common when cloned via Windows git)
#    2. checks bash, kernel, namespaces, cgroups (v2 → v1 fallback), overlayfs
#    3. functional probe: a real unshare + /proc mount
#    4. chmod +x the scripts, links `box` into /usr/local/bin
#    5. downloads + verifies the Alpine minirootfs (no user interaction)
#
#  usage: sudo ./setup.sh [--no-pull] [--no-link] [--image alpine|ubuntu-mini]
#  exit : 0 ready · 1 bad arguments · 2 not root · 3 host cannot run containers
# =============================================================================
set -Eeuo pipefail

DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
BOX="$DIR/box"
DO_PULL=1 DO_LINK=1 IMAGE=alpine

while (( $# )); do
    case $1 in
        --no-pull) DO_PULL=0 ;;
        --no-link) DO_LINK=0 ;;
        --image)   [[ -n ${2:-} ]] || { echo "--image needs a value" >&2; exit 1; }; IMAGE=$2; shift ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 1 ;;
    esac
    shift
done

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m' B=$'\033[1m' D=$'\033[2m' N=$'\033[0m'
else
    G='' Y='' R='' B='' D='' N=''
fi

PASS=0 WARN=0 FAIL=0
ok()   { printf '  %s✔%s %-34s %s\n' "$G" "$N" "$1" "${2:-}"; PASS=$(( PASS + 1 )); }
warn() { printf '  %s⚠%s %-34s %s\n' "$Y" "$N" "$1" "${2:-}"; WARN=$(( WARN + 1 )); }
bad()  { printf '  %s✖%s %-34s %s\n' "$R" "$N" "$1" "${2:-}"; FAIL=$(( FAIL + 1 )); }
hdr()  { printf '\n%s%s%s\n' "$B" "$1" "$N"; }

# ---- root ----------------------------------------------------------------
if (( EUID != 0 )); then
    if command -v sudo >/dev/null 2>&1; then
        echo "setup.sh needs root (namespaces, mounts, cgroups) — re-running with sudo…" >&2
        exec sudo --preserve-env=BOX_ROOT,NO_COLOR "$BASH" "$0" "$@"
    fi
    echo "setup.sh must run as root" >&2
    exit 2
fi

# Here-document banner
cat <<EOF
${B}ushell-box setup${N}  ${D}($DIR)${N}
EOF

# ---- 1. line endings -------------------------------------------------------
hdr "1. Source files"
for f in "$BOX" "$DIR/demo.sh"; do
    if [[ ! -f $f ]]; then bad "${f##*/} present" "missing!"; continue; fi
    if grep -q $'\r' "$f"; then
        sed -i 's/\r$//' "$f"
        warn "${f##*/} line endings" "converted CRLF → LF"
    else
        ok "${f##*/} line endings" "LF"
    fi
    bash -n "$f" && ok "${f##*/} syntax" "bash -n clean" || bad "${f##*/} syntax" "bash -n failed"
done

# ---- 2. host ---------------------------------------------------------------
hdr "2. Host"
kver=$(uname -r)
kmaj=${kver%%.*}; kmin=${kver#*.}; kmin=${kmin%%.*}
if (( kmaj > 4 || (kmaj == 4 && kmin >= 15) )); then ok "kernel" "$kver"
else warn "kernel" "$kver (>= 4.15 recommended)"; fi
if grep -qi microsoft /proc/version; then ok "platform" "WSL 2 detected"; else ok "platform" "native/VM Linux"; fi
if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
    ok "bash" "$BASH_VERSION"
else
    bad "bash" "$BASH_VERSION (need >= 4.4)"
fi
[[ $(uname -m) =~ ^(x86_64|aarch64|arm64)$ ]] && ok "architecture" "$(uname -m)" || warn "architecture" "$(uname -m) (untested)"

# ---- 3. tools --------------------------------------------------------------
hdr "3. Required tools"
for t in unshare nsenter setsid flock chroot mount umount tar gzip sha256sum awk sed grep sort cut stat ps pgrep hostname; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t" "$(command -v "$t")"; else bad "$t" "not found"; fi
done
if command -v setpriv >/dev/null 2>&1; then ok "setpriv" "pdeathsig support"; else warn "setpriv" "missing (containers may outlive a crashed engine)"; fi
if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
    ok "downloader" "$(command -v curl || command -v wget)"
else
    bad "downloader" "need curl or wget"
fi
uver=$(unshare --version | awk '{ print $NF }')
ok "util-linux" "$uver"

# ---- 4. namespaces ---------------------------------------------------------
hdr "4. Namespaces"
for ns in pid mnt uts ipc; do
    if [[ -e /proc/self/ns/$ns ]]; then ok "$ns namespace" "$(readlink /proc/self/ns/$ns)"; else bad "$ns namespace" "unsupported"; fi
done
kconf=""
if [[ -r /proc/config.gz ]]; then kconf=$(zcat /proc/config.gz 2>/dev/null || true)
elif [[ -r /boot/config-$kver ]]; then kconf=$(< "/boot/config-$kver"); fi
if [[ -n $kconf ]]; then
    for opt in PID_NS UTS_NS IPC_NS CGROUPS MEMCG CGROUP_PIDS CFS_BANDWIDTH OVERLAY_FS; do
        val=$(grep -E "^CONFIG_${opt}=" <<< "$kconf" | cut -d= -f2) || val=""
        case $val in y|m) ok "CONFIG_$opt" "$val" ;; *) warn "CONFIG_$opt" "${val:-not set}" ;; esac
    done
else
    warn "kernel config" "not readable — skipped"
fi
# Inside: we must be PID 1, and our own host PID ($$ of setup.sh) must be invisible.
if unshare --pid --mount --uts --ipc --fork --mount-proc \
        sh -c '[ "$$" = 1 ] && [ -d /proc/1 ] && [ ! -e "/proc/$1" ]' probe "$$" 2>/dev/null; then
    ok "functional probe" "unshare + mount -t proc → PID 1"
else
    bad "functional probe" "unshare failed (is this a restricted container?)"
fi

# ---- 5. cgroups ------------------------------------------------------------
hdr "5. Control groups"
cgfs=$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo none)
if [[ $cgfs == cgroup2fs ]]; then
    ok "hierarchy" "cgroup v2 (unified)"
    ctrls=$(< /sys/fs/cgroup/cgroup.controllers)
    for c in memory cpu pids; do
        [[ " $ctrls " == *" $c "* ]] && ok "controller: $c" "available" || bad "controller: $c" "missing from cgroup.controllers"
    done
    probe="/sys/fs/cgroup/ushell-box-probe.$$"
    if mkdir "$probe" 2>/dev/null; then rmdir "$probe"; ok "cgroup writable" "/sys/fs/cgroup"
    else bad "cgroup writable" "cannot mkdir under /sys/fs/cgroup"; fi
elif [[ -d /sys/fs/cgroup/memory ]]; then
    ok "hierarchy" "cgroup v1 (legacy/hybrid) — fallback mode"
    for c in memory cpu pids; do
        [[ -d /sys/fs/cgroup/$c ]] && ok "controller: $c" "/sys/fs/cgroup/$c" || warn "controller: $c" "not mounted"
    done
else
    bad "hierarchy" "no cgroup filesystem mounted (limits unavailable)"
fi

# ---- 6. overlayfs ----------------------------------------------------------
hdr "6. Filesystem"
grep -qw overlay /proc/filesystems || modprobe overlay 2>/dev/null || true
if grep -qw overlay /proc/filesystems; then ok "overlayfs" "copy-on-write rootfs enabled"
else warn "overlayfs" "unavailable — box will copy images instead"; fi
broot=${BOX_ROOT:-/var/lib/ushell-box}
bfs=$(stat -fc %T "$(dirname "$broot")" 2>/dev/null || echo unknown)
case $bfs in
    9p|v9fs|fuseblk) bad "state dir filesystem" "$broot is on $bfs (Windows) — use a Linux path" ;;
    *) ok "state dir filesystem" "$broot [$bfs]" ;;
esac
case $(stat -fc %T "$DIR") in
    9p|v9fs) warn "project location" "on a Windows drive (works; ~/ is faster)" ;;
esac

# ---- 7. permissions & install --------------------------------------------
hdr "7. Install"
chmod +x "$BOX" "$DIR/demo.sh" "$DIR/setup.sh" 2>/dev/null && ok "chmod +x" "box demo.sh setup.sh" ||
    warn "chmod +x" "not persisted (Windows drive?) — run scripts via bash"
if (( DO_LINK )); then
    ln -sfn "$BOX" /usr/local/bin/box && ok "symlink" "/usr/local/bin/box → $BOX" || warn "symlink" "could not create"
fi

# ---- summary + image -------------------------------------------------------
printf '\n%sSummary:%s %s%d passed%s, %s%d warnings%s, %s%d failed%s\n' \
    "$B" "$N" "$G" "$PASS" "$N" "$Y" "$WARN" "$N" "$R" "$FAIL" "$N"
if (( FAIL > 0 )); then
    echo "This host cannot run ushell-box reliably — fix the ✖ items above." >&2
    exit 3
fi
if (( DO_PULL )); then
    hdr "8. Image"
    "$BASH" "$BOX" pull "$IMAGE"
fi
cat <<EOF

${G}${B}Ready.${N} Try:
  sudo box run --name hello alpine sh -c 'hostname; ps aux'
  sudo box menu
  sudo ./demo.sh
EOF
