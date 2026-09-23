#!/usr/bin/env bash
# fm-home-operable-lib.sh - the ONE executable owner of the early home-operable
# marker format and match rule.
#
# Sourced, never executed.
#
# WHY THIS EXISTS. Session start's bulky digest is not what blocks captain work.
# Once this session holds the fleet lock and the local detect-only bootstrap that
# gates dispatch has finished, agents and bin/fm-control.sh may start. Waiting
# for the rest of the digest, or re-running bin/fm-session-start.sh to wait for
# it, is the Windows control-trace stall this marker removes.
#
# CONTRACT, owned here and documented for callers by bin/fm-session-start.sh:
#   path    $STATE/.home-operable  (regular file, never a symlink)
#   body    one line: the lock owner's pid, the same bytes as state/.lock
#   match   both files are regular, not symlinks, and those pids are equal
#           and numeric. No ancestry walk. A poller is not the lock holder.
#   write   only a lock-owning session start, after that detect-only bootstrap,
#           atomically (temp file next to the marker, then mv).
#   stale   a pid that does not match state/.lock, a symlink, or a missing
#           file. Callers treat that as not operable.
#
# bin/fm-session-start.sh owns when the marker is written, cleared, or used to
# cheapen a second start. This file owns only the bytes and the match.
#
# NO SECRETS. The pid is the same public lock identity state/.lock already
# carries. Nothing else is stored.
set -u

fm_home_operable_file() {  # <state>
  printf '%s/.home-operable\n' "$1"
}

fm_home_operable_pid() {  # <state>
  local file pid
  file=$(fm_home_operable_file "$1")
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  pid=$(cat "$file" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$pid"
}

fm_home_operable_matches_lock() {  # <state>
  local state=$1 lock_pid marker_pid
  [ -n "$state" ] || return 1
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  marker_pid=$(fm_home_operable_pid "$state") || return 1
  [ "$marker_pid" = "$lock_pid" ]
}

fm_home_operable_write() {  # <state> <lock-pid>
  local state=$1 lock_pid=$2 file tmp
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -n "$state" ] && [ -d "$state" ] || return 1
  file=$(fm_home_operable_file "$state")
  tmp=$(mktemp "$state/.home-operable.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n' "$lock_pid" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$file" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}
