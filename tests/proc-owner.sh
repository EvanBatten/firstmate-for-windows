# shellcheck shell=bash
# tests/proc-owner.sh - owned-process reaping shared by tests/lib.sh and
# bin/fm-test-run.sh.
#
# A fixture that blocks forever, or ignores TERM to prove a tree kill, outlives
# its suite whenever cleanup misses it or never runs: a hard kill skips every
# trap, and on Windows a Win32 tree kill does not reach an MSYS child behind
# Git's bin/bash.exe launcher. Each leftover keeps polling, and a few dozen of
# them starve the host. So every process a suite starts inherits
# FM_TEST_PROC_OWNER, naming the suite's shell by pid and start time, and a
# tagged process whose owner is gone is killed by the next sweep.
#
# The runner execs each script with the tag already set, so it sits in the
# suite's exec-time environment and every fork and child carries it; Linux
# /proc/<pid>/environ shows only that exec-time block, so a tag a shell exports
# later reaches its exec'd children but not its forked subshells. tests/lib.sh
# tags a directly run suite the same way, which Git Bash/MSYS (whose environ is
# live) covers completely. A host without /proc/<pid>/environ keeps only the
# traps.

fm_test_proc_starttime() {  # <pid>
  local stat_line
  # A name no suite uses: shellcheck tracks variable types across sourced files.
  local -a _fm_proc_stat
  { read -r stat_line < "/proc/$1/stat"; } 2>/dev/null || return 1
  read -r -a _fm_proc_stat <<< "${stat_line##*)}"
  printf '%s\n' "${_fm_proc_stat[19]:-}"
}

# fm_test_proc_owner_tag: print this shell's tag, or nothing without /proc.
fm_test_proc_owner_tag() {
  [ -r /proc/self/environ ] || return 0
  printf '%s:%s\n' "$$" "$(fm_test_proc_starttime "$$")"
}

# fm_test_proc_owner_alive <tag>: the tag's suite is still running. Its start
# time is the usual proof, but on Git Bash exec starts a new process with a new
# start time, so a suite the runner tagged before exec is matched instead by
# the tag it still carries in its own environment.
fm_test_proc_owner_alive() {
  local pid=${1%%:*}
  [ "$(fm_test_proc_starttime "$pid")" != "${1#*:}" ] || return 0
  env -u FM_TEST_PROC_OWNER grep -a -q -z -x -F "FM_TEST_PROC_OWNER=$1" "/proc/$pid/environ" 2>/dev/null
}

# fm_test_kill_tagged <own|orphans> <scan-file>
#   own      kill every process tagged with this shell's FM_TEST_PROC_OWNER
#   orphans  kill every tagged process whose owner is no longer running
# <scan-file> is a private path the caller owns; it is overwritten and removed.
# Always returns 0, so a caller under set -e survives an empty or racing scan.
fm_test_kill_tagged() {
  local mode=$1 scan=$2 rec pid owner live=' ' dead=' '
  [ -r /proc/self/environ ] || return 0
  [ "$mode" != own ] || [ -n "${FM_TEST_PROC_OWNER:-}" ] || return 0
  # Scan into a file before parsing: a pipeline stage is a tagged fork until it
  # execs, so one running during the scan would report itself. Parsing stays in
  # builtins because every fork costs tens of milliseconds on Git Bash.
  env -u FM_TEST_PROC_OWNER grep -a -z -H '^FM_TEST_PROC_OWNER=' /proc/[0-9]*/environ \
    > "$scan" 2>/dev/null || true
  while IFS= read -r -d '' rec; do
    rec=${rec#/proc/}
    pid=${rec%%/*}
    owner=${rec#*:FM_TEST_PROC_OWNER=}
    [ "$pid" != "$$" ] || continue
    case $mode in
      own) [ "$owner" = "$FM_TEST_PROC_OWNER" ] || continue ;;
      orphans)
        [ "${owner%%:*}" != "$$" ] || continue
        case $live in *" $owner "*) continue ;; esac
        case $dead in
          *" $owner "*) ;;
          *)
            if fm_test_proc_owner_alive "$owner"; then
              live+="$owner "
              continue
            fi
            dead+="$owner "
            ;;
        esac
        ;;
    esac
    kill -KILL "$pid" 2>/dev/null || true
  done < "$scan"
  rm -f "$scan"
}

# Run as a script, it tags itself and becomes `bash <script> [args...]`; exec
# keeps this pid and start time, so the tag names the suite itself.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  FM_TEST_PROC_OWNER=$(fm_test_proc_owner_tag)
  export FM_TEST_PROC_OWNER
  exec bash "$@"
fi
