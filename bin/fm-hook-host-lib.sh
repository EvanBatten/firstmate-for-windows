#!/usr/bin/env bash
# Shared payload helpers for the tracked Claude-shaped hook entries: the "which
# harness delivered this hook payload?" predicate, and the jq field read those
# entries use to lift a command out of it.
# This file is sourced by hook entrypoints and has no side effects on source.
#
# Why it exists: Cursor Agent CLI loads `<project>/.claude/settings.json` in
# addition to its own `<project>/.cursor/hooks.json` (verified live, cursor-agent
# 2026.08.11-e8db854). A Cursor primary running in a Firstmate checkout therefore
# fires BOTH registrations for every event Cursor's Claude-compatibility map
# covers, which would run session start twice and evaluate each PreToolUse
# seatbelt twice. Firstmate's Cursor registration owns those events, so the
# tracked Claude-shaped entry must stand down.
#
# The signal is the PAYLOAD, not the environment, and that choice is
# load-bearing. Cursor exports CURSOR_INVOKED_AS, CURSOR_PROJECT_DIR, and
# CURSOR_VERSION into every child process, so an environment guard would also
# fire inside a Claude session a human started by hand from a Cursor pane and
# would silently disable Claude's own supervision - the exact hazard
# docs/turnend-guard.md records for GROK_SESSION_ID. The delivered payload
# describes THIS event and cannot be inherited: Cursor stamps every hook payload
# with its own `cursor_version`, and Claude never emits that key.
#
# Fail direction: when the host cannot be determined (no payload, no jq), the
# caller RUNS. A redundant run under Cursor wastes work; a skipped run under
# Claude breaks the primary's supervision, which is the worse failure.

# Return 0 when payload $1 was delivered by a foreign host whose own tracked
# Firstmate registration already covers this event.
fm_hook_payload_is_foreign_host() {  # <payload>
  local payload=${1-}
  [ -n "$payload" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$payload" | jq -e '
    type == "object" and has("cursor_version") and (.cursor_version | type) == "string"
  ' >/dev/null 2>&1
}

# Echo jq's raw (-r) rendering of filter $2 over payload $1, returning jq's own
# exit status so a caller can still fail open when jq itself fails.
#
# WHY THIS IS NOT A BARE `jq -r`: a native Windows jq.exe opens stdout in text
# mode, so every LF inside a multi-line value is written as CRLF (measured on
# both jq-1.6 mingw-w64 and jq-1.8.2, so it is the platform and not one bad
# build). A command substitution strips trailing LINE FEEDS, not a trailing
# CRLF, so even a single-line value arrives with the CR that text mode paired
# with jq's final LF still on the end; a MULTI-LINE one also carries a stray CR
# before every interior newline. That is enough to change what the shell
# classifier is shown: `bin/fm-watc\<newline>h-arm.sh &` stops being a line
# continuation, so the watcher-arm seatbelt ALLOWS a command the shell would have
# run - a fail-open inside the guard's own threat model. Undoing exactly jq's
# translation, every CRLF back to one LF, is lossless: text mode never touches a
# CR that is not immediately followed by an LF, so an original CR LF survives as
# CR LF. (jq 1.7 grew `--binary` for this; we do not depend on it, because jq 1.6
# is still what a Git Bash toolchain commonly ships.) A POSIX host never enters
# the branch and runs the same jq call these callers always ran.
fm_hook_payload_string() {  # <payload> <jq-filter>
  local payload=${1-} filter=${2-} raw
  case "${OSTYPE:-}" in
    msys*|mingw*|cygwin*)
      raw=$(printf '%s' "$payload" | jq -r "$filter" 2>/dev/null) || return
      # The substitution above already ate jq's final LF. In text mode that LF
      # arrived as CR LF, so its CR is still on the end with nothing after it,
      # where the interior pass below can no longer see it as half of a pair.
      raw=${raw%$'\r'}
      printf '%s\n' "${raw//$'\r'$'\n'/$'\n'}"
      return 0
      ;;
  esac
  printf '%s' "$payload" | jq -r "$filter" 2>/dev/null
}
