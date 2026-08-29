#!/usr/bin/env bash
# fm-proc-lib.sh - one owner of "what process is this, and is it alive".
#
# bin/fm-harness.sh, bin/fm-session-lock-lib.sh and bin/fm-wake-lib.sh used to
# spell `ps -o comm=/args=/ppid= -p <pid>` and `kill -0 <pid>` themselves. That
# is portable across macOS and Linux and works nowhere else, so this file owns
# the platform branch rather than scattering it through three hot callers.
# This file is sourced by scripts and has no side effects on source beyond
# resolving FM_PROC_UNAME and FM_PROC_OS once. It is a LEAF: it sources
# nothing, so any caller may source it in any order.
#
# ON macOS AND LINUX EVERY HELPER RUNS EXACTLY THE COMMAND ITS CALLER RAN
# BEFORE. fm_proc_comm is `ps -o comm= -p`, fm_proc_args is `ps -o args= -p`,
# fm_proc_ppid is `ps -o ppid= -p` piped through `tr`, fm_proc_pgid is
# `ps -o pgid= -p` piped through `tr`, fm_pid_alive is `kill -0`, and
# fm_proc_chain_prime is a no-op that returns 0 without forking.
# Those platforms must see no behavior change at all; the MSYS branches below
# are the only new code that ever executes, and callers still start their walks
# at $$ exactly as they did before.
#
# WHY MSYS NEEDS A BRANCH (measured on Windows 11 26200, Git Bash 5.2 MINGW64;
# docs/windows/measurement.md rows 2 and 3):
#   - MSYS `ps` rejects `-o` outright ("unknown option -- o"), so every field
#     query returns nothing.
#   - A bash started by a native Windows process reports PPID 1, so the MSYS
#     process table cannot express the chain past its own boundary. Only Win32
#     knows that a Git Bash hook descends from claude.exe.
#   - `kill -0 <win32 pid>` reports "No such process" for a native process
#     (claude.exe, herdr.exe) that is plainly running; `ps -W` lists it.
#
# The Win32 half needs `pwsh` (PowerShell 7: `.Parent` does not exist in 5.1).
# Without it the chain simply stops at the MSYS boundary and native ancestors
# are unidentifiable - exactly the pre-library behavior, so nothing regresses.
# fm_pid_alive keeps working either way, because `ps -W` needs no PowerShell.
#
# THE MSYS WALK IS HYBRID, in two segments, because each half of the chain has
# exactly one authority:
#   1. MSYS processes are read straight out of /proc: `exename` is the same
#      string `ps -o comm=` prints, `cmdline` is the real NUL-separated
#      argument vector, and `ppid` is correct between MSYS processes. Pure file
#      reads, no fork, measured at 64 ms for a two-hop segment.
#   2. At the boundary - the outermost MSYS process, the one reporting PPID 1 -
#      its `winpid` is handed to ONE pwsh process that walks the rest in Win32
#      pids with Get-Process and repeated .Parent. Measured at 0.83 s, and it
#      reaches claude.exe -> node.exe -> pwsh.exe -> herdr.exe.
# Timings for the whole six-hop chain, which is why the walk looks like this:
#   one `Get-CimInstance Win32_Process -Filter ProcessId=N` per hop  22-24 s
#   one bulk `Get-CimInstance Win32_Process` for the whole table     4.7-5.1 s
#   this hybrid walk                                                 0.9 s
# Reading `.CommandLine` off a PowerShell 7 Process object costs a hidden
# per-process CIM query - 38 s for those same six hops - so it is NOT read; see
# the fm_proc_args header for what that costs.
#
# TWO PID SPACES, ONE CHAIN. Segment 1 rows are keyed by MSYS pid and segment 2
# rows by Win32 pid, joined where the boundary row's parent is a Win32 pid.
# Callers only ever follow the ppid link, so they never need to know which is
# which, and fm_pid_alive answers for both. A pid with a readable
# /proc/<pid>/exename is treated as an MSYS pid and anything else as a Win32
# pid; Cygwin pids are allocated below 65536 while this machine's Win32 pids
# run well above it, so the two only collide if Windows hands out a low pid
# that also names a live MSYS process.
#
# This matters past the walk: bin/fm-lock.sh writes fm_harness_ancestry_pid
# into state/.lock, so on MSYS the session lock records the harness's WIN32
# pid, and every liveness probe of it has to go through fm_pid_alive rather
# than a bare `kill -0`. bin/fm-lease-lib.sh still probes that pid with a bare
# `kill -0` (fm_lease_live) and so reads a live Pi lease as stale on Windows -
# fail-closed, Pi-only, and recorded in docs/windows/measurement.md rather than
# fixed here, because that file is outside this patch's four callers.
#
# ONE pwsh PROCESS PER WALK. Every caller runs its field queries inside command
# substitution, and a subshell cannot write back to its parent, so a memo that
# filled itself lazily would be discarded on every hop. Callers therefore prime
# the memo ONCE, in their own shell, before the loop:
#     fm_proc_chain_prime "$pid"
# after which the per-hop fm_proc_comm/args/ppid calls read it from inside
# their subshells. A lookup that misses the memo still answers correctly, at
# the cost of its own walk. The memo is deliberately not time-bounded: it is
# refilled by the next prime, it never answers a liveness question
# (fm_pid_alive always probes the live process table), and a stale identity for
# an already-dead pid can only make a caller keep a lock it would otherwise
# steal, which is the safe direction.

if [ -n "${FM_PROC_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_PROC_LIB_SOURCED=1

FM_PROC_UNAME=$(uname -s 2>/dev/null || echo unknown)
case "$FM_PROC_UNAME" in
  MINGW*|MSYS*|CYGWIN*) FM_PROC_OS=msys ;;
  *) FM_PROC_OS=posix ;;
esac
# CAPABILITY, NOT PLATFORM, HAS THE LAST WORD. Any `ps` that accepts -o answers
# everything the POSIX helpers need, wherever it is running, so a Windows host
# that has one is served by the plain path: the test suite shims exactly such a
# `ps` to model a process table, and a future MSYS ps could grow the flag. The
# probe is guarded by the platform verdict, so macOS and Linux never run it and
# pay nothing; MSYS pays one ~90 ms fork at source time, where the alternative
# is every ps-faking test in tests/ silently bypassing its own fixture.
# LC_ALL=C is pinned for the same reason every other parsed `ps` call in bin/
# pins it: the answer must not depend on the ambient locale, and a stub `ps`
# that records the locale it was called under (tests/fm-watcher-lock.test.sh)
# must not see this probe arrive under the caller's.
if [ "$FM_PROC_OS" = msys ] && LC_ALL=C ps -o comm= -p $$ >/dev/null 2>&1; then
  FM_PROC_OS=posix
fi

# The memo filled by fm_proc_chain_prime: fm_proc_chain output text, or empty.
FM_PROC_CHAIN_MEMO=

# Where the MSYS process files are read from. Overridable so the test suite can
# fake a Windows process tree on Linux, the same way it fakes `herdr`.
FM_PROC_MSYS_PROC_ROOT=${FM_PROC_MSYS_PROC_ROOT:-/proc}

# _fm_proc_msys_row <pid>: one "pid<TAB>ppid<TAB>comm<TAB>args" row read from
# MSYS /proc, or return 1 when <pid> is not a live MSYS process. `exename` is
# what `ps -o comm=` would have printed and `cmdline` is the real argument
# vector, so an MSYS process is described exactly, not approximated.
_fm_proc_msys_row() {
  local pid=$1 root=$FM_PROC_MSYS_PROC_ROOT exe ppid args
  [ -r "$root/$pid/exename" ] || return 1
  # These files carry no trailing newline, so `read` sets the variable and then
  # reports EOF; the value, not the status, is what says whether it worked.
  exe=
  { read -r exe < "$root/$pid/exename"; } 2>/dev/null || true
  [ -n "$exe" ] || return 1
  ppid=0
  { read -r ppid < "$root/$pid/ppid"; } 2>/dev/null || true
  case "$ppid" in ''|*[!0-9]*) ppid=0 ;; esac
  # Every read here brackets its redirection: bash applies redirections left to
  # right, so `< missing-file 2>/dev/null` still reports the failure on the
  # caller's stderr. A process that exits mid-walk must be silent, not noisy.
  args=$({ tr '\0\n\t' '   ' < "$root/$pid/cmdline"; } 2>/dev/null) || args=
  args=${args%"${args##*[![:space:]]}"}
  [ -n "$args" ] || args=$exe
  printf '%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$exe" "$args"
}

# _fm_proc_msys_winpid <pid>: the Win32 id of an MSYS pid, or return 1.
_fm_proc_msys_winpid() {
  local win=
  [ -r "$FM_PROC_MSYS_PROC_ROOT/$1/winpid" ] || return 1
  { read -r win < "$FM_PROC_MSYS_PROC_ROOT/$1/winpid"; } 2>/dev/null || true
  case "$win" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$win" ;;
  esac
}

# _fm_proc_win_chain <win32 pid>: the Win32 ancestry of that pid in ONE pwsh
# process, innermost first, as "pid<TAB>ppid<TAB>comm<TAB>args" rows. A dead or
# unreachable parent ends the chain with a ppid of 0, which is what a Git Bash
# child sees: MSYS emulates fork(), so the Win32 parent of a bash-spawned
# process is a transient that has already exited. That is exactly why segment 1
# exists and why the pwsh walk starts at the boundary rather than at $$.
#
# pwsh emits raw "pid<TAB>ppid<TAB>windows path" rows and THIS SHELL normalizes
# them, so the shape the callers actually match on is decided in code a Linux
# test can drive (tests/fm-proc-lib.test.sh) instead of inside a PowerShell
# string only Windows can run. The command name is made to look like something
# `ps -o comm=` could have printed: backslashes become slashes so `basename`
# and the callers' path-component matches work, and a trailing .exe is dropped
# so the anchored name tests in bin/fm-harness.sh (kimi, pi, pi-signed) and the
# ^pi$ alternative in FM_HARNESS_RE still match. pwsh writes CRLF, so the CR is
# stripped here too and one process stays exactly one row.
#
# The pid is passed in the environment rather than interpolated into the
# script, which keeps the pwsh source a single-quoted bash string: no bash
# expansion of its $p/$env: variables and no bash command substitution of its
# backtick-t format escapes.
_fm_proc_win_chain() {
  local out lpid lppid lcomm printed=0
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  command -v pwsh >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2016  # single quotes are the point: $p/$q/$c/$env: and the backtick-t format escapes are PowerShell syntax and must reach pwsh unexpanded by bash.
  out=$(FM_PROC_QUERY_PID=$1 pwsh -NoProfile -NonInteractive -Command '
$ErrorActionPreference = "SilentlyContinue"
$p = Get-Process -Id ([int]$env:FM_PROC_QUERY_PID)
for ($i = 0; $i -lt 16 -and $p; $i++) {
  $q = $null; try { $q = $p.Parent } catch {}
  $c = $p.ProcessName; try { if ($p.Path) { $c = $p.Path } } catch {}
  "{0}`t{1}`t{2}" -f $p.Id, $(if ($q) { $q.Id } else { 0 }), $c
  $p = $q
}' 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  while IFS=$'\t' read -r lpid lppid lcomm; do
    lpid=${lpid%$'\r'}
    lppid=${lppid%$'\r'}
    lcomm=${lcomm%$'\r'}
    case "$lpid" in ''|*[!0-9]*) continue ;; esac
    case "$lppid" in ''|*[!0-9]*) lppid=0 ;; esac
    lcomm=${lcomm//\\//}
    case "$lcomm" in
      *.[Ee][Xx][Ee]) lcomm=${lcomm%.???} ;;
    esac
    [ -n "$lcomm" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$lpid" "$lppid" "$lcomm" "$lcomm"
    printed=1
  done <<EOF
$out
EOF
  [ "$printed" -eq 1 ]
}

# _fm_proc_chain_msys <pid> <max-hops>: the two-segment walk described in the
# header. <pid> may be an MSYS pid (the normal case, a caller walking from $$)
# or a Win32 pid (a lock file's recorded harness pid), which skips straight to
# segment 2.
_fm_proc_chain_msys() {
  local pid=$1 max=$2 hops=0 i n win_ppid=0 lpid
  local boundary_win='' win_chain=''
  local -a rpid=() rcomm=() rargs=()
  local row f_pid f_ppid f_comm f_args

  while [ "$hops" -lt "$max" ]; do
    row=$(_fm_proc_msys_row "$pid") || break
    IFS=$'\t' read -r f_pid f_ppid f_comm f_args <<EOF
$row
EOF
    rpid+=("$f_pid")
    rcomm+=("$f_comm")
    rargs+=("$f_args")
    boundary_win=$(_fm_proc_msys_winpid "$f_pid") || boundary_win=
    hops=$((hops + 1))
    [ "$f_ppid" -gt 1 ] || break
    pid=$f_ppid
  done

  n=${#rpid[@]}
  # Segment 2 continues from the outermost MSYS process, or from the requested
  # pid itself when that pid was never an MSYS process to begin with.
  [ "$n" -eq 0 ] && boundary_win=$pid
  if [ -n "$boundary_win" ]; then
    win_chain=$(_fm_proc_win_chain "$boundary_win") || win_chain=
  fi
  if [ -n "$win_chain" ]; then
    IFS=$'\t' read -r lpid win_ppid _ _ <<EOF
$(printf '%s\n' "$win_chain" | head -n 1)
EOF
    case "$win_ppid" in ''|*[!0-9]*) win_ppid=0 ;; esac
  fi

  if [ "$n" -eq 0 ]; then
    [ -n "$win_chain" ] || return 1
    printf '%s\n' "$win_chain"
    return 0
  fi

  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "$((i + 1))" -lt "$n" ]; then
      printf '%s\t%s\t%s\t%s\n' "${rpid[$i]}" "${rpid[$((i + 1))]}" "${rcomm[$i]}" "${rargs[$i]}"
    else
      # The boundary row keeps /proc's exename and real cmdline and takes only
      # its parent from the Win32 walk, whose first row is this same process
      # described less precisely.
      printf '%s\t%s\t%s\t%s\n' "${rpid[$i]}" "$win_ppid" "${rcomm[$i]}" "${rargs[$i]}"
    fi
    i=$((i + 1))
  done
  [ -n "$win_chain" ] && printf '%s\n' "$win_chain" | tail -n +2
  return 0
}

# _fm_proc_row_field <chain-text> <pid> <ppid|comm|args>: one field of <pid>'s
# row in an already-fetched chain, or return 1 when the pid is not in it.
_fm_proc_row_field() {
  local chain=$1 pid=$2 want=$3 lpid lppid lcomm largs
  [ -n "$chain" ] || return 1
  while IFS=$'\t' read -r lpid lppid lcomm largs; do
    [ "$lpid" = "$pid" ] || continue
    case "$want" in
      ppid) printf '%s\n' "$lppid" ;;
      comm) printf '%s\n' "$lcomm" ;;
      args) printf '%s\n' "$largs" ;;
      *) return 1 ;;
    esac
    return 0
  done <<EOF
$chain
EOF
  return 1
}

# _fm_proc_msys_field <pid> <field>: the memo first, then /proc when the pid is
# an MSYS process (free), then a Win32 walk rooted at that pid. The fallback
# walk is NOT written back to the memo: this runs inside the caller's command
# substitution, where the assignment would be discarded anyway.
_fm_proc_msys_field() {
  local pid=$1 want=$2 chain
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  _fm_proc_row_field "$FM_PROC_CHAIN_MEMO" "$pid" "$want" && return 0
  chain=$(_fm_proc_msys_row "$pid") || chain=$(_fm_proc_win_chain "$pid") || return 1
  _fm_proc_row_field "$chain" "$pid" "$want"
}

# fm_proc_chain <pid> [max-hops]: the ancestry of <pid>, innermost first, as
# "pid<TAB>ppid<TAB>comm<TAB>args" rows. Returns 1 when <pid> itself cannot be
# read. A ppid of 0 or 1, or one that cannot be parsed, ends the chain - the
# same stop condition the callers' own loops have always used.
fm_proc_chain() {
  local pid=$1 max=${2:-16} hops=0 printed=0 comm args ppid
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$max" in ''|*[!0-9]*) max=16 ;; esac
  if [ "$FM_PROC_OS" = msys ]; then
    _fm_proc_chain_msys "$pid" "$max"
    return
  fi
  while [ "$hops" -lt "$max" ]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    case "$ppid" in ''|*[!0-9]*) ppid=0 ;; esac
    printf '%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$comm" "$args"
    printed=1
    [ "$ppid" -gt 1 ] || break
    pid=$ppid
    hops=$((hops + 1))
  done
  [ "$printed" -eq 1 ]
}

# fm_proc_chain_prime <pid>: fetch <pid>'s ancestry into the process-global memo
# so the caller's per-hop lookups cost no further process. A no-op on macOS and
# Linux, where a per-hop `ps` is already the cheapest thing available. Always
# succeeds: a failed prime only means the lookups pay their own way.
#
# MUST be called from the caller's own shell, never inside `$(...)`.
fm_proc_chain_prime() {
  [ "$FM_PROC_OS" = msys ] || return 0
  FM_PROC_CHAIN_MEMO=$(fm_proc_chain "$1" 2>/dev/null) || FM_PROC_CHAIN_MEMO=
  return 0
}

# fm_proc_comm <pid>: the process's command name, and the exit status of the
# lookup - callers break their ancestry walk on a non-zero status, so it is
# propagated rather than swallowed.
fm_proc_comm() {
  if [ "$FM_PROC_OS" = msys ]; then
    _fm_proc_msys_field "$1" comm
  else
    ps -o comm= -p "$1" 2>/dev/null
  fi
}

# fm_proc_args <pid>: the process's full argument string.
#
# On MSYS this is the real argument vector for an MSYS process, read from
# /proc/<pid>/cmdline. For a NATIVE Windows ancestor it is the executable path
# instead, because the only way to read a Windows command line from PowerShell
# costs a CIM query per process (38 s for a six-hop chain, against 0.9 s for
# the whole walk without it). The consequence is bounded and one-directional:
# `args` is consumed by bin/fm-harness.sh and bin/fm-session-lock-lib.sh only
# to recognise a harness that a bare interpreter is RUNNING (`node
# /path/to/claude`), and for a native ancestor it can now only miss, never
# match something it should not - the value returned is the same string
# fm_proc_comm returns, so it can add no match of its own. A harness launched
# through a native Windows interpreter is therefore identified by the
# CLAUDECODE/PI_CODING_AGENT/GROK_AGENT environment markers those callers test
# first, or not at all; a native harness executable (claude.exe is one) is
# still identified by its path through fm_proc_comm.
fm_proc_args() {
  if [ "$FM_PROC_OS" = msys ]; then
    _fm_proc_msys_field "$1" args
  else
    ps -o args= -p "$1" 2>/dev/null
  fi
}

# fm_proc_ppid <pid>: the parent pid, whitespace stripped. Empty (with a
# non-zero status) when the process is gone.
fm_proc_ppid() {
  if [ "$FM_PROC_OS" = msys ]; then
    _fm_proc_msys_field "$1" ppid
  else
    ps -o ppid= -p "$1" 2>/dev/null | tr -d '[:space:]'
  fi
}

# fm_proc_pgid <pid>: the process group id, whitespace stripped, or empty.
#
# Not part of the chain rows: a process group is not ancestry, nothing walks it,
# and all three callers (bin/fm-procevent.sh's runner-isolation proof and its
# group stop, bin/fm-watch.sh's check-subshell proof) ask about one pid once.
# MSYS has no `ps -o`, but it does publish the answer as a file -
# /proc/<pid>/pgid, the same directory fm_proc_comm and fm_proc_ppid already
# read - so this needs no PowerShell and no extra process at all.
fm_proc_pgid() {
  local pid=$1 pgid=
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$FM_PROC_OS" = msys ]; then
    [ -r "$FM_PROC_MSYS_PROC_ROOT/$pid/pgid" ] || return 1
    # This one is newline-terminated on Cygwin (unlike `exename` beside it), but
    # `read`'s status is ignored either way: the VALUE is what says whether the
    # read worked, and the digits-only test below is what says it is usable.
    { read -r pgid < "$FM_PROC_MSYS_PROC_ROOT/$pid/pgid"; } 2>/dev/null || true
    case "$pgid" in
      ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$pgid"
    return 0
  fi
  ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]'
}

# fm_pid_alive <pid>: true when the pid names a live process.
#
# `kill -0` is asked first everywhere, so on macOS and Linux this IS `kill -0`.
# On MSYS it answers for MSYS pids (the watcher, the daemon, this shell) and
# fails for a native Windows process, whose WINPID the `ps -W` table still
# lists - column 4, next to the MSYS pid in column 1. Only column 4 is matched:
# an MSYS pid has already been settled by `kill -0`, and the two spaces are
# unrelated, so reading a Win32 pid out of the MSYS pid column could only
# invent liveness.
fm_pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null && return 0
  [ "$FM_PROC_OS" = msys ] || return 1
  ps -W 2>/dev/null | awk -v p="$pid" '$4 == p { found = 1 } END { exit !found }'
}
