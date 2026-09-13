#!/usr/bin/env bash
# Print the one-line session-start instruction only for a genuine firstmate
# primary whose current harness session has not already acquired the home lock.
# Every silence and error path exits 0 because Claude SessionStart exit 2 blocks
# session initialization.
#
# Usage: fm-sessionstart-nudge.sh [--no-harness-ancestry]
#   --no-harness-ancestry
#     The caller has already walked THIS process's ancestry and found no
#     harness in it, so no lock can be proven to belong to this session and the
#     ownership check below has nothing left to learn. Skipping it drops a
#     second ancestry walk and, on a Windows userland, the `ps -W` table scan
#     its liveness probe runs first. The one case where the two answers could
#     differ is a Windows pid the lock names and the OS has since reused: the
#     check would go silent for a lock that is not this session's, while
#     skipping it fires the nudge so bin/fm-lock.sh can reclaim that lock,
#     which is the safer direction. Only bin/fm-sessionstart-run.sh passes it,
#     after its own walk; the Grok registration and the OpenCode plugin invoke
#     this script without it and are unchanged.
#
#     An ARGUMENT rather than an environment variable, deliberately. An
#     exported answer outlives this process: it is inherited by the digest, by
#     bin/fm-spawn.sh, and by every crew harness and hook those start, which
#     live for hours and have ancestries of their own. An argument reaches this
#     process and nothing it goes on to spawn.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

NO_HARNESS_ANCESTRY=0
for arg in "$@"; do
  case "$arg" in
    --no-harness-ancestry) NO_HARNESS_ANCESTRY=1 ;;
  esac
done

# shellcheck source=bin/fm-proc-lib.sh
. "$SCRIPT_DIR/fm-proc-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

fm_is_gate_agent "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

lock_is_in_ancestry() {
  local lock_pid pid=$$ _
  [ -f "$STATE/.lock" ] || return 1
  IFS= read -r lock_pid < "$STATE/.lock" 2>/dev/null || return 1
  case "$lock_pid" in
    ''|*[!0-9]*|1) return 1 ;;
  esac
  # Both the liveness probe and the walk go through bin/fm-proc-lib.sh, which
  # runs exactly `kill -0` and `ps -o ppid= -p` on macOS and Linux. The lock
  # this compares against is written by bin/fm-session-lock-lib.sh, which on a
  # Windows userland records the harness's WIN32 pid - a pid `kill -0` reports
  # as absent and a pid no MSYS ppid chain reaches - so without the library
  # this ancestry test answered "no" for every session there and the nudge
  # fired at a primary that had already taken the lock.
  fm_pid_alive "$lock_pid" || return 1
  fm_proc_chain_prime "$pid"
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$pid" = "$lock_pid" ] && return 0
    pid=$(fm_proc_ppid "$pid")
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

if [ "$NO_HARNESS_ANCESTRY" = 0 ] && lock_is_in_ancestry; then
  exit 0
fi
nudge=
fm_operational_input_encode session-start \
  "Run \`bin/fm-session-start.sh\` now, exactly once, before executing any other instructions." \
  nudge || exit 0
printf '%s\n' "$nudge"
exit 0
