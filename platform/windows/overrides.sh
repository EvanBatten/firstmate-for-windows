# shellcheck shell=bash
# Sourced by the one-line hook at the end of each hooked upstream library, so
# it runs again after every library that may have just redefined a function
# below. Each override keeps the upstream function's name, arguments, output
# and status, and replaces only how a process is read: in-process from /proc
# and the cached Win32 walk in proc.sh, instead of a `ps` fork per field.
#
# Nothing is overridden unless the `ps` on PATH is this overlay's shim. A test
# fixture that puts its own fake `ps` first keeps the upstream bodies, which
# read that fake exactly as they do on Linux.

# shellcheck source=platform/windows/herdr.sh
! declare -F fm_backend_herdr_cli >/dev/null || . "${FM_PLATFORM_OVERLAY%/*}/herdr.sh"

IFS=: read -r -a _fm_win_dirs <<< "$PATH"
for _fm_win_d in "${_fm_win_dirs[@]}"; do
  [ -n "$_fm_win_d" ] && [ -x "$_fm_win_d/ps" ] && break
done
if [ "$_fm_win_d" != "${FM_PLATFORM_OVERLAY%/*}/bin" ]; then
  unset _fm_win_dirs _fm_win_d
  [ -z "${_FM_WIN_PS_FN:-}" ] || unset -f ps
  unset _FM_WIN_PS_FN
  return 0
fi
unset _fm_win_dirs _fm_win_d
# shellcheck source=platform/windows/proc.sh
declare -F fm_win_proc >/dev/null || . "${FM_PLATFORM_OVERLAY%/*}/proc.sh"

# Upstream's fm_harness_process_matches costs about 250 ms of forks per process
# here (basename, grep, Cursor path canonicalization), and the walk asks it once
# per hop. Each of its rules reads only the comm and argv[0], except the bare
# interpreter rule, and each needs a harness name, Cursor's name or a symlink
# there. A process with none of them is answered as no match without asking.
# The name list is upstream's own, so a new harness reaches this check as is.
_fm_win_is_harness() {  # <comm> <args>
  local text="$1 ${2%% *}" name
  FM_HARNESS_IS_CLAUDE=0
  [ -L "$1" ] || for name in "${FM_HARNESS_NAMES[@]}" cursor agent MainThread node python; do
    case $text in *"$name"*) break ;; esac
    name=
  done
  [ -n "${name:-}" ] || [ -L "$1" ] || return 1
  fm_harness_process_matches "$1" "$2"
}

# Every other `ps` in a hooked library answers from the same rows in-process,
# without starting the shim.
ps() { fm_win_ps "$@"; }
_FM_WIN_PS_FN=1

if declare -F fm_harness_ancestry_pids >/dev/null; then
  # bin/fm-session-lock-lib.sh: the contiguous harness run above $$, innermost
  # first. The Win32 half of the chain is what makes claude.exe reachable.
  # Every pid printed is a Win32 pid, an MSYS hop's own winpid, because the
  # MSYS and Win32 pid spaces overlap: a lock that could hold either kind can
  # read a dead MSYS holder as a live Win32 process of the same number.
  fm_harness_ancestry_pids() {
    local pid=$$ space=msys extending=0 printed=0 hop
    for ((hop = 0; hop < 16; hop++)); do
      fm_win_proc "$pid" "$space" || break
      if _fm_win_is_harness "$FM_PROC_COMM" "$FM_PROC_ARGS"; then
        printf '%s\n' "$FM_PROC_WINPID"
        printed=1
        [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
        extending=1
      elif [ "$extending" -eq 1 ]; then
        break
      fi
      pid=$FM_PROC_PPID space=$FM_PROC_PSPACE
      case "$pid" in '' | *[!0-9]*) break ;; esac
      [ "$pid" -ge 1 ] || break
    done
    [ "$printed" -eq 1 ]
  }

  # A recorded lock pid is a Win32 pid (above), so liveness asks only the Win32
  # space. `kill -0` cannot see a Win32 pid at all.
  fm_harness_pid_alive() {
    fm_win32_alive "$1" && _fm_win_is_harness "$FM_PROC_COMM" "$FM_PROC_ARGS"
  }

  # Upstream's body with its `kill -0` and `ps` probes answered in the Win32
  # space: a live harness is held, any other live process is unknown, and a
  # pid no process holds is stale.
  # shellcheck disable=SC2034 # Output globals, read by fm-lock.sh status and fm-inbox.sh ready.
  fm_session_lock_inspect() {  # <state>
    local state=$1 lock pid
    FM_LOCK_INSPECT_STATE=unknown
    FM_LOCK_INSPECT_PID=
    FM_LOCK_INSPECT_LIVE_HARNESS=unknown
    lock="$state/.lock"
    if [ ! -e "$lock" ]; then
      FM_LOCK_INSPECT_STATE=free
      FM_LOCK_INSPECT_LIVE_HARNESS=false
      return 0
    fi
    if [ ! -f "$lock" ] || [ -L "$lock" ]; then
      FM_LOCK_INSPECT_STATE=unreadable
      return 0
    fi
    pid=$(cat "$lock" 2>/dev/null) || {
      FM_LOCK_INSPECT_STATE=unreadable
      return 0
    }
    pid=${pid%%$'\n'*}
    FM_LOCK_INSPECT_PID=$pid
    case "$pid" in '' | *[!0-9]*) return 0 ;; esac
    if fm_win32_alive "$pid"; then
      if _fm_win_is_harness "$FM_PROC_COMM" "$FM_PROC_ARGS"; then
        FM_LOCK_INSPECT_STATE=held
        FM_LOCK_INSPECT_LIVE_HARNESS=true
      else
        FM_LOCK_INSPECT_LIVE_HARNESS=false
      fi
      return 0
    fi
    FM_LOCK_INSPECT_STATE=stale
    FM_LOCK_INSPECT_LIVE_HARNESS=false
  }
fi

if declare -F fm_lock_abs_path >/dev/null; then
  # bin/fm-wake-lib.sh: a lock is a symlink to its owner directory, claimed
  # only when readlink returns the exact path written. A native symlink reads
  # back through the mount table, so a directory that /tmp also maps reads back
  # as /tmp/... even when it was written as /c/.../Temp/..., and the claim spins.
  # Spell the owner the way readlink will: the Windows path, then back.
  fm_lock_abs_path() {
    local path=$1 dir base
    fm_dirname_to dir "$path"
    fm_basename_to base "$path"
    dir=$(cd "$dir" 2>/dev/null && pwd -W) || return 1
    dir=$(cygpath -u -- "$dir") || return 1
    printf '%s/%s\n' "$dir" "$base"
  }
fi

if declare -F harness_process_verdict >/dev/null; then
  # bin/fm-harness.sh: the nearest harness verdict above a pid. Upstream's
  # verdict costs about 400 ms of forks per process here. Every verdict it can
  # print names a harness that also appears in the matched comm or argv[0], or
  # comes from a bare interpreter or a symlink, so a process with none of them
  # is skipped. The names are read from upstream's own verdict lines.
  _fm_win_verdict_names=" node python agent MainThread "
  _fm_win_body=$(declare -f harness_process_verdict)
  _fm_win_re='echo "(comm|args) ([a-z-]+)"'
  while [[ $_fm_win_body =~ $_fm_win_re ]]; do
    _fm_win_verdict_names+="${BASH_REMATCH[2]} "
    _fm_win_body=${_fm_win_body#*"${BASH_REMATCH[0]}"}
  done
  unset _fm_win_body _fm_win_re

  harness_ancestry() {  # [<pid>]
    local pid=${1:-$$} space=msys verdict text name hop
    for ((hop = 0; hop < 8; hop++)); do
      fm_win_proc "$pid" "$space" || break
      text="$FM_PROC_COMM ${FM_PROC_ARGS%% *}"
      for name in $_fm_win_verdict_names; do
        case $text in *"$name"*) break ;; esac
        name=
      done
      if [ -n "$name" ] || [ -L "$FM_PROC_COMM" ]; then
        verdict=$(harness_process_verdict "$pid")
        [ -z "$verdict" ] || { echo "$verdict"; return; }
      fi
      pid=$FM_PROC_PPID space=$FM_PROC_PSPACE
      case "$pid" in '' | *[!0-9]*) break ;; esac
      [ "$pid" -ge 1 ] || break
    done
    return 0
  }
fi
