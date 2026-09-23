#!/usr/bin/env bash
# Safe throwaway / verify-home auto-answers.
# Usage: . bin/fm-verify-home-lib.sh
#
# A verify home is a throwaway measurement or verification home, never a
# captain fleet. Detection is exact and fail-closed:
#   - FM_VERIFY_HOME=1
#   - FM_SESSION_START_FAST=1
#   - a regular file <home>/.fm-control-throwaway
# Any other value, a missing home, or a symlinked marker is inactive.
# bin/fm-verify-home.sh is the public command surface; this file owns the
# bytes, mutation contract, and pane-text classifier.
#
# Safe auto-answers only (stable class names for tests):
#   trust-yes              folder-trust dialog -> Yes (rank 10)
#   background-work-enter  /exit "Background work is running" -> Enter (rank 12)
#   skip-permissions       prefer claude --dangerously-skip-permissions
#   pre-grant-land         assigned throwaway work may land without asking again
# Fail-if-seen (never auto-answered):
#   ask-user               ask-user / needs-decision product findings
#   blocked                any other parked question, including tool-install (rank 1)
#
# This library never installs tools, never answers ask-user, never rewrites
# bootstrap MISSING lines, and never copies credentials or mutates
# ~/.claude.json. An existing data/captain.md is left untouched.
# Session-start, herdr polls, and persistent-cd are out of scope.
# No side effects on source. set -u safe.

FM_VERIFY_HOME_MARKER=".fm-control-throwaway"
FM_VERIFY_HOME_CLAUDE_FLAGS="verify-claude-flags.json"

fm_verify_home_flag_on() {
  [ "${1:-}" = 1 ]
}

# fm_verify_home_active [home]
fm_verify_home_active() {
  local home=${1:-${FM_HOME:-}}
  fm_verify_home_flag_on "${FM_VERIFY_HOME:-}" && return 0
  fm_verify_home_flag_on "${FM_SESSION_START_FAST:-}" && return 0
  [ -n "$home" ] || return 1
  [ -f "$home/$FM_VERIFY_HOME_MARKER" ] && [ ! -L "$home/$FM_VERIFY_HOME_MARKER" ]
}

fm_verify_home_config_dir() {
  local home=${1:-${FM_HOME:-}}
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-$home/config}"
}

fm_verify_home_data_dir() {
  local home=${1:-${FM_HOME:-}}
  printf '%s\n' "${FM_DATA_OVERRIDE:-$home/data}"
}

fm_verify_home_captain_text() {
  cat <<'EOF'
# Captain

This is a throwaway verify home, not a captain fleet.

Land the work this session already assigned and approved.
Do not ask again for landing approval on that assigned work.
Prefer claude --dangerously-skip-permissions on this home.
Never answer ask-user or needs-decision findings yourself.
Never install tools from this session.
EOF
}

# Flags a launcher may merge into an isolated CLAUDE_CONFIG_DIR.
# This library never writes that directory, so host login is left alone.
fm_verify_home_claude_flags_text() {
  printf '%s\n' '{"hasTrustDialogAccepted":true,"bypassPermissionsModeAccepted":true}'
}

# fm_verify_home_seed [home]
# Idempotent. Writes the marker, Claude skip-dialog flags, and captain.md
# when that file is absent.
fm_verify_home_seed() {
  local home=${1:-${FM_HOME:-}} config data captain flags
  [ -n "$home" ] || return 1
  config=$(fm_verify_home_config_dir "$home")
  data=$(fm_verify_home_data_dir "$home")
  mkdir -p "$config" "$data" || return 1
  if [ ! -e "$home/$FM_VERIFY_HOME_MARKER" ]; then
    printf '\n' > "$home/$FM_VERIFY_HOME_MARKER" || return 1
  fi
  flags="$config/$FM_VERIFY_HOME_CLAUDE_FLAGS"
  if [ ! -e "$flags" ]; then
    fm_verify_home_claude_flags_text > "$flags" || return 1
  fi
  captain="$data/captain.md"
  if [ ! -e "$captain" ]; then
    fm_verify_home_captain_text > "$captain" || return 1
  fi
}

# fm_verify_home_classify <text>
# Prints exactly one class name for pane or transcript text.
fm_verify_home_classify() {
  local text=$1
  case "$text" in
    *'ask-user'*|*'needs-decision'*|*'AskUser'*)
      printf '%s\n' ask-user
      return 0
      ;;
  esac
  case "$text" in
    *'Yes, I trust this folder'*)
      printf '%s\n' trust-yes
      return 0
      ;;
  esac
  case "$text" in
    *'Background work is running'*)
      printf '%s\n' background-work-enter
      return 0
      ;;
  esac
  case "$text" in
    *'MISSING:'*|*'MISSING_MANUAL:'*|*'which tools'*install*|*'install treehouse'*|*'make an isolated copy'*)
      printf '%s\n' blocked
      return 0
      ;;
  esac
  printf '%s\n' none
}
