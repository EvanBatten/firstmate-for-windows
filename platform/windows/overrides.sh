# shellcheck shell=bash
# shellcheck source=platform/windows/herdr.sh
! declare -F fm_backend_herdr_cli >/dev/null || . "${FM_PLATFORM_OVERLAY%/*}/herdr.sh"

# A test fixture that puts its own fake `ps` first on PATH keeps the upstream
# bodies, which read that fake as they do on Linux. MSYS's own ps is not a
# fixture: Git's bin/bash.exe, which Claude runs hooks through, puts /usr/bin
# ahead of the overlay's bin. A native parent hands FM_PLATFORM_OVERLAY back in
# drive spelling, so compare files.
_fm_win_ps=
IFS=: read -r -a _fm_win_dirs <<< "$PATH"
for _fm_win_d in "${_fm_win_dirs[@]}"; do
  [ -n "$_fm_win_d" ] && [ -x "$_fm_win_d/ps" ] && _fm_win_ps=$_fm_win_d/ps && break
done
unset _fm_win_dirs _fm_win_d
if [ -n "$_fm_win_ps" ] && [ ! "$_fm_win_ps" -ef "${FM_PLATFORM_OVERLAY%/*}/bin/ps" ] \
  && [ ! "$_fm_win_ps" -ef /usr/bin/ps ]; then
  unset _fm_win_ps
  [ -z "${_FM_WIN_PS_FN:-}" ] || unset -f ps
  unset _FM_WIN_PS_FN
  return 0
fi
unset _fm_win_ps
# shellcheck source=platform/windows/proc.sh
declare -F fm_win_proc >/dev/null || . "${FM_PLATFORM_OVERLAY%/*}/proc.sh"

# Upstream's matcher forks for about 250 ms per process here. A process whose
# comm and argv[0] carry no harness name and no symlink cannot match, so it is
# answered without asking.
_fm_win_is_harness() {
  local text="$1 ${2%% *}" name
  FM_HARNESS_IS_CLAUDE=0
  [ -L "$1" ] || for name in "${FM_HARNESS_NAMES[@]}" cursor agent MainThread node python; do
    case $text in *"$name"*) break ;; esac
    name=
  done
  [ -n "${name:-}" ] || [ -L "$1" ] || return 1
  fm_harness_process_matches "$1" "$2"
}

ps() { fm_win_ps "$@"; }
_FM_WIN_PS_FN=1

if declare -F fm_harness_ancestry_pids >/dev/null; then
  fm_harness_ancestry_pids() {
    local pid=$$ space=msys extending=0 printed=0 win32_parent_gone=0 hop
    for ((hop = 0; hop < 16; hop++)); do
      fm_win_proc "$pid" "$space" || break
      if _fm_win_is_harness "$FM_PROC_COMM" "$FM_PROC_ARGS"; then
        if [ "$space" = msys ]; then
          printf '%s\n' "$pid"
          printed=1
        fi
        [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
        extending=1
      elif [ "$extending" -eq 1 ]; then
        break
      fi
      [ "$space.$FM_PROC_PSPACE.$FM_PROC_PPID" != msys.w32.0 ] || win32_parent_gone=1
      pid=$FM_PROC_PPID space=$FM_PROC_PSPACE
      case "$pid" in '' | *[!0-9]*) break ;; esac
      [ "$pid" -ge 1 ] || break
    done
    [ "$printed" -eq 0 ] && [ "$win32_parent_gone" -eq 1 ] && _fm_win_claude_pid_msys && printed=1
    [ "$printed" -eq 1 ]
  }

  # Claude's SessionStart hook execs a `#!/usr/bin/env bash` script, which
  # leaves that script with no live Win32 parent.
  _fm_win_claude_pid_msys() {
    local msys
    case ${CLAUDE_PID:-} in '' | *[!0-9]*) return 1 ;; esac
    fm_win_msys_pid "$CLAUDE_PID" || return 1
    msys=$FM_WIN_MSYS_PID
    fm_win_proc "$msys" msys || return 1
    _fm_win_is_harness "$FM_PROC_COMM" "$FM_PROC_ARGS" && [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || return 1
    printf '%s\n' "$msys"
  }
fi

if declare -F fm_lock_abs_path >/dev/null; then
  # A lock is a symlink to its owner directory, claimed
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
  # Upstream's verdict forks for about 400 ms per process here, so a process
  # that names none of the harnesses in its verdict lines is skipped.
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
