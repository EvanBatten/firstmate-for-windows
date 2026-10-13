#!/usr/bin/env bash
# Pure helpers of the verification suite (tests/verification/lib.sh and
# session-lib.sh), driven with the host and Herdr answers pinned.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-verification-lib)
FIXTURE="$TMP_ROOT/root"
mkdir -p "$FIXTURE/platform/windows"
cp "$ROOT/.tasks.toml" "$FIXTURE/"
printf 'FM_PLATFORM_OVERLAY=stub-overlay\nexport FM_PLATFORM_OVERLAY\n' > "$FIXTURE/platform/windows/env.sh"

# overlay_after_home <uname -s>: what FM_PLATFORM_OVERLAY a fresh suite home
# leaves behind on that host, with env.sh replaced by a stub.
overlay_after_home() {
  local host=$1
  (
    unset FM_PLATFORM_OVERLAY
    VERIFY_ARTIFACT_DIR="$TMP_ROOT/artifacts-overlay"
    # shellcheck source=tests/verification/lib.sh
    . "$ROOT/tests/verification/lib.sh"
    # shellcheck disable=SC2329 # called by verify_platform_overlay
    uname() { printf '%s\n' "$host"; }
    VERIFY_ROOT=$FIXTURE
    VERIFY_TMP=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
    verify_home
    printf '%s' "${FM_PLATFORM_OVERLAY:-none}"
  )
}

for host in MINGW64_NT-10.0 MSYS_NT-10.0 CYGWIN_NT-10.0; do
  assert_equals "$(overlay_after_home "$host")" stub-overlay "a suite home on $host loads the overlay"
done
assert_equals "$(overlay_after_home Linux)" none "a suite home off Windows leaves the overlay alone"
assert_equals "$(overlay_after_home Darwin)" none "a suite home on macOS leaves the overlay alone"
pass "verify_home loads the overlay exactly on Windows hosts"

# cleanup_answered <agent status> <pane text>: whether the steer-worker cleanup
# wait counts the primary as having answered.
cleanup_answered() {
  local agent_status=$1 pane_text=$2
  (
    VERIFY_ARTIFACT_DIR="$TMP_ROOT/artifacts-cleanup"
    # shellcheck source=tests/verification/lib.sh
    . "$ROOT/tests/verification/lib.sh"
    # shellcheck source=tests/verification/session-lib.sh
    . "$ROOT/tests/verification/session-lib.sh"
    # shellcheck disable=SC2329 # called by session_answered_cleanup
    session_agent_status() { printf '%s\n' "$agent_status"; }
    # shellcheck disable=SC2329 # called by session_answered_cleanup
    session_pane_text() { printf '%s\n' "$pane_text"; }
    if session_answered_cleanup; then echo yes; else echo no; fi
  )
}

# The primary's own words after a cleanup request, from a real cleanup-refusal
# drive at f2b27476, laid out as the question it would park on.
ON_TOPIC='To finish the cleanup, pick one:
1. Keep it parked (my recommendation): the isolated copy stays until you decide on greet.sh.
2. Discard it now: say "discard greet.sh" and I will remove the isolated copy and the branch.
3. Land it, then clean up: say go and I will land it on local main, then clean up normally.'
OFF_TOPIC='Which colour theme should the README use? 1. Dark 2. Light'

assert_equals "$(cleanup_answered idle '')" yes "a primary that finished its turn answered"
assert_equals "$(cleanup_answered 'done' '')" yes "a primary whose turn is done answered"
assert_equals "$(cleanup_answered working "$ON_TOPIC")" no "a primary still working has not answered"
assert_equals "$(cleanup_answered blocked "$ON_TOPIC")" yes "a question about the cleanup is an answer"
assert_equals "$(cleanup_answered blocked "$OFF_TOPIC")" no "a question about something else is not an answer to the cleanup request"
pass "the cleanup wait counts only a finished turn or a question about the cleanup"
