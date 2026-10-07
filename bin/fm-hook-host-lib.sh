#!/usr/bin/env bash
# Shared "which harness delivered this hook payload?" predicate for the tracked
# Claude-shaped hook entries.
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

FM_HOOK_FOREIGN_HOST_JQ='type == "object" and has("cursor_version") and (.cursor_version | type) == "string"'

# Return 0 when payload $1 was delivered by a foreign host whose own tracked
# Firstmate registration already covers this event.
fm_hook_payload_is_foreign_host() {  # <payload>
  local payload=${1-}
  [ -n "$payload" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$payload" | jq -e "$FM_HOOK_FOREIGN_HOST_JQ" >/dev/null 2>&1
}

# shellcheck disable=SC2034 # FM_HOOK_COMMAND is the result the sourcing hook reads.
# Reads a PreToolUse payload on stdin with one jq run and sets FM_HOOK_COMMAND
# to its shell command (Grok toolInput.command, else tool_input.command). It is
# empty when stdin is empty or carries no command, and, unless <own-host> is 1,
# when a foreign host delivered the payload. Returns 1 on a malformed payload.
fm_hook_pretool_command() {  # <own-host 0|1>
  local out tag
  FM_HOOK_COMMAND=
  # shellcheck disable=SC2016 # $own is a jq variable.
  out=$(jq -r --argjson own "$1" '
    if $own == 0 and ('"$FM_HOOK_FOREIGN_HOST_JQ"') then "foreign"
    else "command", (.toolInput.command // .tool_input.command // empty) end
  ' 2>/dev/null) || return 1
  tag=${out%%$'\n'*}
  [ "${tag%$'\r'}" = command ] || return 0
  [ "$tag" = "$out" ] || FM_HOOK_COMMAND=${out#*$'\n'}
}
