#!/usr/bin/env bash
# session-time.sh - wall-clock one full firstmate session trace.
#
# Measures tests/verification/restart-primary.verify.sh the way
# .agents/skills/verify-firstmate/verify.sh runs it: doctor, then the session
# script. Does not reimplement the scenario or change its predicates.
#
# Usage: tools/fm-control/session-time.sh [<trace>]
#   <trace> defaults to restart-primary.
#
# Environment:
#   VERIFY_* values are passed through to verify.sh (VERIFY_REAL_SESSION is
#   forced to 1 so this is a session, not a skip or an empty-directory ping).
#
# Prints one JSON object on stdout:
#   trace    feature name
#   wallMs   process start to the scenario predicate (or first failure)
#   pass     true only when the scenario's own success predicate passed
#   split    readyMs (primary ready) and afterReadyMs (ready to predicate),
#            when the ready line is seen; otherwise both null
#   predicate  the claim that ended the timing (pass, first not-ok, skip, or
#              the auth/doctor stop)
#
# Claude authentication is probed once. A missing CLI or a failed probe stops
# immediately and does not start the session. Tokens are never invented.
set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'session-time: %s is not inside a git checkout\n' "$HERE" >&2
  exit 2
}
VERIFY="$ROOT/.agents/skills/verify-firstmate/verify.sh"
TRACE=${1:-restart-primary}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
  exit 0
fi

[ -x "$VERIFY" ] || [ -f "$VERIFY" ] || {
  printf 'session-time: verify entry is missing: %s\n' "$VERIFY" >&2
  exit 2
}

now_ms() {
  local t=${EPOCHREALTIME} sec frac
  sec=${t%.*}
  frac=${t#*.}000
  printf '%d\n' $((10#$sec * 1000 + 10#${frac:0:3}))
}

emit_json() {
  local wall=$1 pass=$2 ready=$3 predicate=$4 after=null
  if [ "$ready" != null ] && [ "$wall" -ge "$ready" ]; then
    after=$((wall - ready))
  fi
  jq -n \
    --arg trace "$TRACE" \
    --argjson wallMs "$wall" \
    --argjson pass "$pass" \
    --argjson readyMs "$ready" \
    --argjson afterReadyMs "$after" \
    --arg predicate "$predicate" \
    '{
      trace: $trace,
      wallMs: $wallMs,
      pass: $pass,
      split: {readyMs: $readyMs, afterReadyMs: $afterReadyMs},
      predicate: $predicate
    }'
}

T0=$(now_ms)
READY_MS=
PREDICATE=
PASS=false

# One auth probe. No retries. No token invention.
claude_auth_probe() {
  if ! command -v claude >/dev/null 2>&1; then
    printf 'session-time: claude is not installed; authentication is missing\n' >&2
    return 1
  fi
  if claude auth status >/dev/null 2>&1; then
    printf 'session-time: claude auth: ok\n' >&2
    return 0
  fi
  printf 'session-time: claude authentication is missing or failed (one probe, no retry)\n' >&2
  return 1
}

if ! claude_auth_probe; then
  emit_json $(( $(now_ms) - T0 )) false null \
    "claude authentication is missing or failed"
  exit 1
fi

command -v jq >/dev/null 2>&1 || {
  printf 'session-time: jq is required to print the metric JSON\n' >&2
  emit_json $(( $(now_ms) - T0 )) false null "jq is not installed"
  exit 2
}

STAMPED=$(mktemp "${TMPDIR:-/tmp}/fm-session-time.XXXXXX")
trap 'rm -f "$STAMPED"' EXIT

printf 'session-time: driving %s via %s (VERIFY_REAL_SESSION=1)\n' \
  "$TRACE" "$VERIFY" >&2

set +e
VERIFY_REAL_SESSION=1 bash "$VERIFY" run "$TRACE" 2>&1 \
  | while IFS= read -r line || [ -n "$line" ]; do
      printf '%s\t%s\n' "$(now_ms)" "$line" >> "$STAMPED"
      printf '%s\n' "$line" >&2
    done
STATUS=${PIPESTATUS[0]}
set -e

READY_LINE='ok - a real firstmate primary is running in its own Herdr tab, past its trust prompt'
RESULT_PASS="result: ${TRACE} passed"
RESULT_FAIL="result: ${TRACE} failed"
RESULT_SKIP="result: ${TRACE} skipped"

while IFS=$'\t' read -r ts line; do
  case "$line" in
    "$READY_LINE")
      [ -n "$READY_MS" ] || READY_MS=$((ts - T0))
      ;;
    'not ok - '*)
      if [ -z "$PREDICATE" ]; then
        PREDICATE=${line#not ok - }
        PASS=false
        WALL_MS=$((ts - T0))
      fi
      ;;
    'skip: '*)
      if [ -z "$PREDICATE" ]; then
        PREDICATE=${line#skip: }
        PASS=false
        WALL_MS=$((ts - T0))
      fi
      ;;
    "$RESULT_PASS")
      PREDICATE=$line
      PASS=true
      WALL_MS=$((ts - T0))
      ;;
    "$RESULT_FAIL"|"$RESULT_SKIP")
      [ -n "$PREDICATE" ] || PREDICATE=$line
      PASS=false
      [ -n "${WALL_MS:-}" ] || WALL_MS=$((ts - T0))
      ;;
    '# doctor: not worth driving'*|'verify: doctor refused'*)
      if [ -z "$PREDICATE" ]; then
        PREDICATE=$line
        PASS=false
        WALL_MS=$((ts - T0))
      fi
      ;;
  esac
done < "$STAMPED"

if [ -z "${WALL_MS:-}" ]; then
  WALL_MS=$(( $(now_ms) - T0 ))
  if [ -z "$PREDICATE" ]; then
    if [ "$STATUS" -eq 0 ]; then
      PREDICATE=$RESULT_PASS
      PASS=true
    else
      PREDICATE="verify.sh exited $STATUS with no scenario predicate"
      PASS=false
    fi
  fi
fi

READY_JSON=null
[ -n "$READY_MS" ] && READY_JSON=$READY_MS

if [ "$PASS" = true ]; then
  emit_json "$WALL_MS" true "$READY_JSON" "$PREDICATE"
  exit 0
fi
emit_json "$WALL_MS" false "$READY_JSON" "$PREDICATE"
exit 1
