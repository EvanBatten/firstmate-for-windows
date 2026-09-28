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
  fm_harness_ancestry_pids() {
    local pid=$$ extending=0 printed=0 hop
    for ((hop = 0; hop < 16; hop++)); do
      fm_win_proc "$pid" || break
      if _fm_win_is_harness "$FM_PROC_COMM" "$FM_PROC_ARGS"; then
        printf '%s\n' "$pid"
        printed=1
        [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
        extending=1
      elif [ "$extending" -eq 1 ]; then
        break
      fi
      pid=$FM_PROC_PPID
      case "$pid" in '' | *[!0-9]*) break ;; esac
      [ "$pid" -ge 1 ] || break
    done
    [ "$printed" -eq 1 ]
  }

  # A recorded lock pid can be an MSYS pid or a Win32 pid, and the two spaces
  # overlap, so a harness in either one keeps the lock live. `kill -0` cannot
  # see a Win32 pid at all.
  fm_harness_pid_alive() {
    local pid=$1
    case "$pid" in '' | *[!0-9]*) return 1 ;; esac
    fm_win_msys_proc "$pid" && _fm_win_is_harness "$FM_PROC_COMM" "$FM_PROC_ARGS" && return 0
    fm_win32_alive "$pid" && _fm_win_is_harness "$FM_PROC_COMM" "$FM_PROC_ARGS"
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
    local pid=${1:-$$} verdict text name hop
    for ((hop = 0; hop < 8; hop++)); do
      fm_win_proc "$pid" || break
      text="$FM_PROC_COMM ${FM_PROC_ARGS%% *}"
      for name in $_fm_win_verdict_names; do
        case $text in *"$name"*) break ;; esac
        name=
      done
      if [ -n "$name" ] || [ -L "$FM_PROC_COMM" ]; then
        verdict=$(harness_process_verdict "$pid")
        [ -z "$verdict" ] || { echo "$verdict"; return; }
      fi
      pid=$FM_PROC_PPID
      case "$pid" in '' | *[!0-9]*) break ;; esac
      [ "$pid" -ge 1 ] || break
    done
    return 0
  }
fi
