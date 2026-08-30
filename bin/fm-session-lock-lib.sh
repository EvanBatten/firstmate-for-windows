#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# It owns TWO proofs of that one question: the process ancestry, and - only
# where the ancestry walk dead-ends - the harness session identity recorded
# beside the lock (see the section at the end of this file).
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

# bin/fm-proc-lib.sh is the one owner of "which process is this, and is it
# alive". On macOS and Linux its helpers run exactly the `ps -o ...` and
# `kill -0` calls this file used to run itself; on Git Bash they are the only
# thing that can answer, and there the walk yields the harness's WIN32 pid, so
# the pid this file hands bin/fm-lock.sh to record in state/.lock is a Win32
# pid and must be probed with fm_pid_alive rather than a bare `kill -0`.
# shellcheck source=bin/fm-proc-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-proc-lib.sh"

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  fm_proc_chain_prime "$pid"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(fm_proc_comm "$pid") || break
    args=$(fm_proc_args "$pid")
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(fm_proc_ppid "$pid")
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  fm_pid_alive "$pid" || return 1
  fm_proc_chain_prime "$pid"
  comm=$(fm_proc_comm "$pid") || return 1
  args=$(fm_proc_args "$pid")
  fm_harness_process_matches "$comm" "$args"
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}

# --- session identity: the proof that survives a severed ancestry ------------
#
# Every predicate above walks upward from this process. On Git Bash that walk
# can be cut at the first hop, and the tracked hook registrations are exactly
# where it happens: MSYS implements exec() by starting a NEW Win32 process and
# exiting the old one, so a hook body reached through `exec` (or through bash's
# implicit exec of a `-c` script's final command) is left with a Win32 parent
# that has already exited and an MSYS ppid of 1. Both halves of the hybrid walk
# dead-end there, `fm_harness_ancestry_pids` finds no harness at all, and a
# Stop hook can never prove it belongs to the session that holds the lock
# (docs/windows/measurement.md, finding 22).
#
# So the lock carries a SECOND, ancestry-free proof: the harness's own session
# identity, recorded beside the pid when the lock is acquired and presented back
# by the hook out of the payload the harness delivers to it. It is a fallback,
# never a replacement - the ancestry proof above is tried first and its answer
# always stands - so macOS and Linux never reach this path and decide exactly
# what they decided before.
#
# The pair lives in its own file rather than in state/.lock, whose one-bare-pid
# format is a contract shared by fourteen readers in bin/ and every fixture in
# tests/: fm_session_lock_owned_by_self itself rejects a lock that is not purely
# numeric, so a second line there would make every session on every platform
# lock-less.
FM_SESSION_LOCK_SIDECAR=.lock.session

# True when $1 is shaped like a harness session identity: 8-128 characters of
# unreserved ASCII. Bounded and charset-checked because it is written to a state
# file and compared by equality; a UUID (36) and any opaque token fit.
fm_session_id_wellformed() {  # <id>
  local id=${1-}
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#id}" -ge 8 ] && [ "${#id}" -le 128 ]
}

# Print this process's harness session identity, or return 1 when there is none.
#
# FM_HARNESS_SESSION_ID is the explicit form a hook entrypoint can set from the
# payload it just parsed. CLAUDE_CODE_SESSION_ID is what Claude Code itself
# exports into every hook process AND every Bash tool shell, which is the only
# source that covers how the lock is really acquired: bin/fm-session-start.sh
# runs bin/fm-lock.sh, and a Claude primary normally runs session start as a
# tool call rather than inside the SessionStart hook.
#
# MEASURED (Claude Code 2.1.251, 2026-08-29): the variable equals the payload's
# session_id for SessionStart and Stop alike, and a NESTED `claude -p` started
# from inside another session OVERRIDES it with its own id rather than
# inheriting. That override is load-bearing - it is what keeps a nested session
# from recording the outer session's identity - so re-verify it when the harness
# is upgraded. It is not a documented interface: when it disappears, no identity
# is found, no pair is recorded, the fallback never fires, and every platform
# degrades to exactly the ancestry-only behavior it has today.
fm_harness_session_id() {
  local id=${FM_HARNESS_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}
  fm_session_id_wellformed "$id" || return 1
  printf '%s\n' "$id"
}

# Record "<pid> <session-id>" beside the lock in state $1 for the pid $2 that
# was just verified into it, or REMOVE the pair when this process has no session
# identity. Refreshing unconditionally is what keeps the pair honest: a lock
# acquired by a harness that has no session id (every non-Claude adapter, or a
# future Claude Code without the variable) must not leave the previous session's
# id behind for a reused pid to match. Best effort by design - the lock is
# already published and verified, and this proof is an addition to it.
fm_session_lock_record_session() {  # <state> <pid>
  local state=$1 pid=$2 id file="$1/$FM_SESSION_LOCK_SIDECAR"
  if id=$(fm_harness_session_id); then
    { printf '%s %s\n' "$pid" "$id" > "$file"; } 2>/dev/null || true
  else
    rm -f "$file" 2>/dev/null || true
  fi
  return 0
}

# True when state dir $1 holds a session lock recorded by the harness session
# whose identity is $2 - the ancestry-free proof of the same question
# fm_session_lock_owned_by_self answers.
#
# Every clause fails closed, and three of them carry the whole contract:
#   - the ancestry walk must have found NO harness at all. When it can name one,
#     that answer is the decision, whether or not it matched the lock: a hook
#     whose walk reaches a DIFFERENT live session must stay inert exactly as it
#     does today. This is what leaves macOS and Linux byte-identical.
#   - the recorded pid must still be the lock pid, so a pair left by an earlier
#     session can never speak for the current one.
#   - that pid must still be a live harness. Without this the fallback would
#     prove only that a session with this id once wrote the lock, and a resumed
#     session whose original process is dead would take ownership of a home
#     nobody holds instead of going through fm-lock.sh's guarded recovery.
#
# Two known residuals, both Low and both bounded by what a pid can promise:
#   - a walk that resolves a harness which is not the lock owner refuses here
#     even when the ancestry was truncated below the real owner. That shape is
#     not what a severed hook produces (measured: no harness at all), and
#     admitting it would weaken the competing-session boundary above.
#   - nothing deletes the pair when its owner dies, so a resumed session
#     carrying the same id whose recorded pid has since been REUSED by another
#     harness-shaped process passes every clause. That is the pid-reuse exposure
#     fm_harness_pid_alive already carries for the plain lock, not a new one.
# The clause ORDER is cost, not logic: every one of them must hold, and the two
# process questions are the expensive pair - each costs a PowerShell-backed
# ancestry walk on Git Bash (measured at 2.1 s and 0.9 s), where the file reads
# above them cost nothing. A firing that is going to refuse almost always
# refuses on the pair or the identity, so it refuses before paying for either.
fm_session_lock_owned_by_session() {  # <state> <session-id>
  local state=$1 claimed=${2-} file line recorded_pid recorded_id lock_pid
  fm_session_id_wellformed "$claimed" || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  file="$state/$FM_SESSION_LOCK_SIDECAR"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  IFS= read -r line < "$file" 2>/dev/null || return 1
  case "$line" in
    *' '*) : ;;
    *) return 1 ;;
  esac
  recorded_pid=${line%% *}
  recorded_id=${line#* }
  [ "$recorded_pid" = "$lock_pid" ] || return 1
  [ "$recorded_id" = "$claimed" ] || return 1
  fm_harness_ancestry_pids >/dev/null 2>&1 && return 1
  fm_harness_pid_alive "$lock_pid"
}
