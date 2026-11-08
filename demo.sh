#!/usr/bin/env bash
# =============================================================================
#  demo.sh — automated evaluation of ushell-box  (B24EF0506 mini-project)
#
#    A. Filesystem jail     : `ls /` is Alpine; no way back to the Ubuntu host
#    B. Process isolation   : `ps aux` inside shows only PID 1 and PID 2; the
#                             host sees the same process under a normal PID
#    C. cgroup enforcement  : a memory hog is OOM-killed at exactly 50M; a busy
#                             loop is throttled to 20% CPU
#    D. Clean tear-down     : even after `kill -9` of the engine, nothing is
#                             left in /proc/mounts or /sys/fs/cgroup
#
#  usage: sudo ./demo.sh [-y|--yes]      (-y: no pauses between sections)
#  exit : 0 all checks passed · 2 not root · 3 one or more checks failed
# =============================================================================
set -Eeuo pipefail

DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"
BOX=("$BASH" "$DIR/box")
PAUSE=1
for a in "$@"; do
    case $a in
        -y|--yes) PAUSE=0 ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option $a" >&2; exit 1 ;;
    esac
done
[[ -t 0 ]] || PAUSE=0

if (( EUID != 0 )); then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo --preserve-env=BOX_ROOT,BOX_CGROUP,BOX_ROOTFS_MODE,NO_COLOR "$BASH" "$0" "$@"
    fi
    echo "demo.sh must run as root" >&2; exit 2
fi
BOX_ROOT=${BOX_ROOT:-/var/lib/ushell-box}
export BOX_QUIET=0

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    G=$'\033[32m' R=$'\033[31m' Y=$'\033[33m' C=$'\033[36m' B=$'\033[1m' D=$'\033[2m' N=$'\033[0m'
else
    G='' R='' Y='' C='' B='' D='' N=''
fi

PASS=0 FAIL=0 SKIP=0
DEMO_NAMES=(demo-jail demo-ps demo-trap demo-oom demo-cpu demo-crash)
HOG_PID=""

pass()    { printf '  %s[PASS]%s %s\n' "$G$B" "$N" "$1"; PASS=$(( PASS + 1 )); }
fail()    { printf '  %s[FAIL]%s %s\n' "$R$B" "$N" "$1"; FAIL=$(( FAIL + 1 )); }
skip()    { printf '  %s[SKIP]%s %s\n' "$Y$B" "$N" "$1"; SKIP=$(( SKIP + 1 )); }
expect()  { local d=$1; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
cmdline() { printf '%s  $ %s%s\n' "$C" "$*" "$N"; }
indent()  { sed 's/^/      /'; }
section() { printf '\n%s━━━ %s %s%s\n' "$B" "$1" "$(printf '━%.0s' $(seq 1 $(( 66 - ${#1} ))))" "$N"; }
pause()   { (( PAUSE )) || return 0; read -r -s -n 1 -p "  ${D}▶ press any key to continue…${N}" _ || true; printf '\n'; }
# NB: awk must consume all input — an early `exit` would SIGPIPE `box inspect`
# and, under `set -o pipefail`, abort the whole demo with status 141.
cfg()     { "${BOX[@]}" inspect "$1" 2>/dev/null | awk -F= -v k="$2" '!f && $1 == k { sub(/^[^=]*=/, ""); print; f = 1 }'; }
box_mounts() { awk -v r="$BOX_ROOT" 'index($0, r) || /ushell-box/ { n++ } END { print n + 0 }' /proc/mounts; }
box_cgroups() {
    find /sys/fs/cgroup/ushell-box /sys/fs/cgroup/{memory,cpu,pids}/ushell-box \
        -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l
}

demo_cleanup() {
    local rc=$?
    trap '' INT TERM
    [[ -n $HOG_PID ]] && kill "$HOG_PID" 2>/dev/null || true
    for n in "${DEMO_NAMES[@]}"; do
        BOX_QUIET=1 "${BOX[@]}" rm -f "$n" >/dev/null 2>&1 || true
    done
    exit "$rc"
}
trap demo_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cat <<EOF
${B}${C}
   ┌────────────────────────────────────────────────────────────────────┐
   │  ushell-box · automated evaluation                                 │
   │  namespaces (pid, mnt, uts, ipc) + chroot + cgroups, in pure Bash  │
   └────────────────────────────────────────────────────────────────────┘${N}
   host: $(. /etc/os-release; echo "$PRETTY_NAME") · kernel $(uname -r)
   state: $BOX_ROOT
EOF

# ---- preflight -------------------------------------------------------------
section "0. Preflight"
for n in "${DEMO_NAMES[@]}"; do BOX_QUIET=1 "${BOX[@]}" rm -f "$n" >/dev/null 2>&1 || true; done
if ! "${BOX[@]}" images | awk '$1 == "alpine" { f = 1 } END { exit !f }'; then
    cmdline "box pull alpine"
    "${BOX[@]}" pull alpine
fi
"${BOX[@]}" info | indent
CGV=$("${BOX[@]}" info | awk '$1 == "cgroups" { print $2 }')
pause

# ---- A. filesystem jail -------------------------------------------------------
section "A. Filesystem jail (chroot + overlayfs + mount namespace)"
script='echo "--- /etc/os-release"; head -n 2 /etc/os-release
echo "--- ls /"; ls /
echo "--- escape attempt: cd /../../../.. ; pwd"; cd /../../../..; pwd
echo "--- hostname: $(hostname)"
echo "--- can we see the host state dir?"; ls -d '"$BOX_ROOT"' 2>&1 || true
echo "--- writes stay in the container layer"; echo scratch > /etc/demo-file && ls -l /etc/demo-file'
cmdline "box run --rm --name demo-jail alpine sh -c '…'"
out=$("${BOX[@]}" run --rm --name demo-jail alpine sh -c "$script")
indent <<< "$out"
expect "container root filesystem is Alpine Linux"     grep -q 'Alpine Linux' <<< "$out"
expect "host is still Ubuntu"                          grep -qi 'ubuntu' /etc/os-release
expect "'cd /../../..' cannot climb out of the jail"   grep -qx '/' <<< "$out"
expect "host-only path $BOX_ROOT is invisible"         grep -q 'No such file' <<< "$out"
expect "UTS namespace: hostname is 'demo-jail'"        grep -q 'hostname: demo-jail' <<< "$out"
expect "host hostname unchanged ($(hostname))"         test "$(hostname)" != demo-jail
expect "image stays pristine (no /etc/demo-file)"      test ! -e "$BOX_ROOT/images/alpine/rootfs/etc/demo-file"
pause

# ---- B. process isolation ------------------------------------------------------
section "B. Process isolation (PID namespace + private /proc)"
cmdline "box run -d --name demo-ps alpine sleep 600"
"${BOX[@]}" run -d --name demo-ps alpine sleep 600 | indent
cmdline "box exec demo-ps ps aux"
psout=$("${BOX[@]}" exec demo-ps ps aux)
indent <<< "$psout"
nproc_in=$(awk 'NR > 1' <<< "$psout" | wc -l)
expect "exactly 2 processes visible inside (found $nproc_in)" test "$nproc_in" -eq 2
expect "PID 1 is the container command (sleep)"   awk 'NR == 2 && $1 == 1 && /sleep/ { f = 1 } END { exit !f }' <<< "$psout"
expect "PID 2 is ps itself"                       awk 'NR == 3 && $1 == 2 && /ps/    { f = 1 } END { exit !f }' <<< "$psout"

hpid=$(cfg demo-ps INIT_PID)
printf '\n'
cmdline "ps -ef | grep -E ':[0-9]{2} [s]leep 600\$'   # the host view"
ps -ef | grep -E ':[0-9]{2} [s]leep 600$' | indent || true
cmdline "grep NSpid /proc/$hpid/status"
grep NSpid "/proc/$hpid/status" | indent
cmdline "ps -o pid,ppid,stat,comm -p $(ps -o ppid= -p "$hpid" | tr -d ' '),$hpid"
ps -o pid,ppid,stat,comm -p "$(ps -o ppid= -p "$hpid" | tr -d ' '),$hpid" | indent
host_ns=$(stat -L -c '%i' /proc/self/ns/pid); ctr_ns=$(stat -L -c '%i' "/proc/$hpid/ns/pid")
printf '      pid-namespace inode: host=%s  container=%s\n' "$host_ns" "$ctr_ns"
expect "host sees the container's PID 1 as ordinary PID $hpid" test "$hpid" -gt 1
expect "NSpid maps host PID $hpid → container PID 1" \
    awk '/^NSpid:/ && $NF == 1 { f = 1 } END { exit !f }' "/proc/$hpid/status"
expect "different PID-namespace inodes"            test "$host_ns" != "$ctr_ns"
printf '\n'
cmdline "box ps"
"${BOX[@]}" ps | indent

printf '\n  %sSignals across the namespace boundary:%s\n' "$B" "$N"
cmdline "box stop -t 2 demo-ps     # sleep has no SIGTERM handler → ignored by PID 1"
"${BOX[@]}" stop -t 2 demo-ps 2>&1 | indent
expect "un-handled SIGTERM ignored → SIGKILL → exit 137" test "$(cfg demo-ps EXIT_CODE)" = 137

cmdline "box run -d --name demo-trap alpine sh -c 'trap \"exit 0\" TERM; while :; do sleep 1; done'"
"${BOX[@]}" run -d --name demo-trap alpine sh -c 'trap "echo caught SIGTERM; exit 0" TERM; while :; do sleep 1; done' >/dev/null
"${BOX[@]}" stop -t 5 demo-trap 2>&1 | indent
expect "PID 1 with a SIGTERM handler exits gracefully (code 0)" test "$(cfg demo-trap EXIT_CODE)" = 0
pause

# ---- C. cgroup enforcement ------------------------------------------------------
section "C. Resource limits (cgroup ${CGV:-?})"
if [[ ${CGV:-v0} == v0 ]]; then
    skip "no cgroup hierarchy available — memory and CPU limits not testable"
else
    hog='BEGIN { s = "x"; for (k = 0; k < 20; k++) s = s s        # s = 1 MiB
                 for (i = 1; i <= 200; i++) { a[i] = s i
                     if (i % 10 == 0) { printf "allocated %3d MiB\n", i; fflush() } }
                 print "SURVIVED 200 MiB - limit NOT enforced" }'
    cmdline "box run --name demo-oom --mem 50M alpine awk '<allocate 1 MiB at a time up to 200 MiB>'"
    rc=0
    "${BOX[@]}" run --name demo-oom --mem 50M alpine awk "$hog" 2>&1 | indent || rc=${PIPESTATUS[0]}
    peak=$(cfg demo-oom MEM_PEAK)
    printf '      exit status %s · memory.peak %s bytes · OOM_KILLED=%s\n' "$rc" "${peak:-?}" "$(cfg demo-oom OOM_KILLED)"
    expect "memory hog was killed (exit 137 = 128 + SIGKILL)"    test "$rc" -eq 137
    expect "cgroup memory.events recorded an oom_kill"           test "$(cfg demo-oom OOM_KILLED)" = 1
    expect "peak usage never exceeded the 50M ceiling"           test "${peak:-0}" -le $(( 50 * 1024 * 1024 ))
    expect "host is unharmed (we are still running)"             true
    cmdline "free -m   # host memory, unaffected"
    free -m | indent

    printf '\n'
    cmdline "box run -d --name demo-cpu --cpu 20 alpine sh -c 'while :; do :; done'"
    "${BOX[@]}" run -d --name demo-cpu --cpu 20 alpine sh -c 'while :; do :; done' >/dev/null
    cmdline "( while :; do :; done ) &        # an unrestricted host loop for comparison"
    ( while :; do :; done ) &
    HOG_PID=$!
    jobs -l | indent
    sleep 2
    host_cpu=$(ps -o %cpu= -p "$HOG_PID" | tr -d ' ')
    kill "$HOG_PID"; wait "$HOG_PID" 2>/dev/null || true; HOG_PID=""
    cmdline "box stats demo-cpu"
    st=$("${BOX[@]}" stats demo-cpu)
    indent <<< "$st"
    ctr_cpu=$(awk -F: '/cpu usage/ { v = $2; sub(/%.*/, "", v); gsub(/ /, "", v); print v }' <<< "$st")
    printf '      unrestricted host loop: %s%%   ·   container (cpu.max = 20000 100000): %s%%\n' "$host_cpu" "$ctr_cpu"
    expect "container CPU throttled to ~20% (measured ${ctr_cpu}%)" \
        awk -v v="$ctr_cpu" 'BEGIN { exit !(v > 5 && v < 30) }'
    "${BOX[@]}" stop -t 1 demo-cpu >/dev/null 2>&1
fi
pause

# ---- D. clean tear-down ------------------------------------------------------
section "D. Clean tear-down (even after a crash)"
cmdline "box run -d --name demo-crash alpine sleep 300"
"${BOX[@]}" run -d --name demo-crash alpine sleep 300 >/dev/null
sup=$(cfg demo-crash SUPERVISOR_PID); shim=$(cfg demo-crash SHIM_PID); cpid=$(cfg demo-crash INIT_PID)
printf '      supervisor PID %s · reaper PID %s · container PID %s\n' "$sup" "$shim" "$cpid"
printf '      mounts referencing ushell-box while running (host view): %s\n' "$(box_mounts)"
cmdline "kill -9 $sup $shim        # simulate the engine crashing hard"
kill -9 "$sup" "$shim"
sleep 1
expect "container died with its parent (PR_SET_PDEATHSIG)"   test ! -d "/proc/$cpid"
expect "0 orphaned mounts in /proc/mounts after the crash"     test "$(box_mounts)" -eq 0
cmdline "box ps -a"
"${BOX[@]}" ps -a | indent
cmdline "box cleanup"
"${BOX[@]}" cleanup 2>&1 | indent

printf '\n'
for n in "${DEMO_NAMES[@]}"; do BOX_QUIET=1 "${BOX[@]}" rm -f "$n" >/dev/null 2>&1 || true; done
cmdline "grep -c ushell-box /proc/mounts"
printf '      %s\n' "$(box_mounts)"
expect "no ushell-box entries in /proc/mounts"          test "$(box_mounts)" -eq 0
expect "no leftover cgroup directories"                 test "$(box_cgroups)" -eq 0
expect "no leftover container processes"                test -z "$(pgrep -f 'box-reaper' || true)"
expect "no demo containers left in state"               test -z "$("${BOX[@]}" ps -a -q)"

# ---- summary ------------------------------------------------------------------
section "Result"
printf '  %s%d passed%s · %s%d failed%s · %s%d skipped%s\n\n' \
    "$G$B" "$PASS" "$N" "$R$B" "$FAIL" "$N" "$Y$B" "$SKIP" "$N"
(( FAIL == 0 )) || exit 3
exit 0
