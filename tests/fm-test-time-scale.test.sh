#!/usr/bin/env bash
# tests/lib.sh sizes wall-clock budgets from a measured host time scale, so a
# budget written on Linux holds on a host where a spawn is an order of magnitude
# slower without becoming a bigger constant everywhere.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-time-scale)
LIB="$ROOT/tests/lib.sh"

# run_with_scale <scale-or-empty> <bash -c body>: a fresh shell that sources the
# library under that pin; an empty pin lets the library measure.
run_with_scale() {
  local pin=$1 body=$2
  if [ -n "$pin" ]; then
    FM_TEST_TIME_SCALE=$pin bash -c ". \"$LIB\"; $body"
  else
    env -u FM_TEST_TIME_SCALE bash -c ". \"$LIB\"; $body"
  fi
}

test_measured_scale_is_a_bounded_positive_integer() {
  local scale
  scale=$(run_with_scale '' 'printf "%s\n" "$FM_TEST_TIME_SCALE"' 2>/dev/null | tail -1)
  case "$scale" in
    ''|*[!0-9]*) fail "the measured scale is not an integer: '$scale'" ;;
  esac
  [ "$scale" -ge 1 ] || fail "the measured scale must be at least 1, got $scale"
  [ "$scale" -le "$FM_TEST_TIME_SCALE_MAX" ] || fail "the measured scale exceeds its cap: $scale"
  pass "time scale: the library measures a bounded positive integer scale"
}

test_pinned_scale_wins_and_sizes_every_budget_shape() {
  local out
  out=$(run_with_scale 3 'printf "%s %s %s %s\n" "$FM_TEST_TIME_SCALE" "$(fm_test_seconds 2)" "$(fm_test_budget_ms 0.5)" "$(fm_test_budget_ms 4)"')
  [ "$out" = "3 6 1500 12000" ] || fail "a pinned scale of 3 should size 2 s to 6, 0.5 s to 1500 ms and 4 s to 12000 ms, got: $out"
  out=$(run_with_scale 1 'printf "%s %s\n" "$(fm_test_seconds 3)" "$(fm_test_budget_ms .25)"')
  [ "$out" = "3 250" ] || fail "a pinned scale of 1 must reproduce the raw budgets, got: $out"
  pass "time scale: a pinned FM_TEST_TIME_SCALE wins and sizes integer and decimal budgets"
}

test_a_bad_pin_is_refused_when_the_library_loads() {
  local out status
  for bad in abc 0 -2 1.5; do
    status=0
    out=$(run_with_scale "$bad" 'echo reached' 2>&1) || status=$?
    [ "$status" -ne 0 ] || fail "FM_TEST_TIME_SCALE=$bad was accepted"
    assert_contains "$out" "FM_TEST_TIME_SCALE must be a positive integer" "FM_TEST_TIME_SCALE=$bad did not name the rule"
    assert_not_contains "$out" "reached" "the suite kept running under FM_TEST_TIME_SCALE=$bad"
  done
  pass "time scale: a malformed pin stops the suite with the rule, never a silent scale of 1"
}

test_wait_until_returns_as_soon_as_the_condition_holds() {
  local flag start elapsed status
  flag="$TMP_ROOT/appears"
  ( sleep 0.3; : > "$flag" ) &
  start=$(fm_test_now_ms)
  status=0
  FM_TEST_TIME_SCALE=1 fm_test_wait_until 10 test -e "$flag" || status=$?
  elapsed=$(( $(fm_test_now_ms) - start ))
  wait
  [ "$status" -eq 0 ] || fail "wait_until returned $status although the file appeared"
  [ "$elapsed" -lt 8000 ] || fail "wait_until held for the whole budget (${elapsed} ms) instead of returning on the condition"
  pass "time scale: wait_until returns the moment its condition holds, well inside the budget"
}

test_wait_until_times_out_at_the_host_sized_deadline() {
  local start elapsed status
  start=$(fm_test_now_ms)
  status=0
  FM_TEST_TIME_SCALE=2 fm_test_wait_until 0.4 test -e "$TMP_ROOT/never" || status=$?
  elapsed=$(( $(fm_test_now_ms) - start ))
  [ "$status" -eq 124 ] || fail "wait_until should return 124 at the deadline, got $status"
  [ "$elapsed" -ge 800 ] || fail "a 0.4 s budget at scale 2 returned after only ${elapsed} ms"
  [ "$elapsed" -lt 15000 ] || fail "the deadline was not bounded: ${elapsed} ms"
  pass "time scale: wait_until returns 124 once the host-sized deadline passes"
}

test_wait_for_exit_honors_the_scaled_deadline_not_a_tick_count() {
  local status
  # A child that outlives the raw 0.3 s budget but not the host-sized one.
  sleep 0.9 &
  status=0
  FM_TEST_TIME_SCALE=5 wait_for_exit $! 3 || status=$?
  [ "$status" -eq 0 ] || fail "wait_for_exit killed a child that exited inside the scaled deadline (rc=$status)"
  sleep 5 &
  status=0
  FM_TEST_TIME_SCALE=1 wait_for_exit $! 3 || status=$?
  [ "$status" -eq 124 ] || fail "wait_for_exit should report 124 for a child that outlives the deadline, got $status"
  pass "time scale: wait_for_exit waits for a host-sized deadline and still bounds a hung child"
}

test_measured_scale_is_a_bounded_positive_integer
test_pinned_scale_wins_and_sizes_every_budget_shape
test_a_bad_pin_is_refused_when_the_library_loads
test_wait_until_returns_as_soon_as_the_condition_holds
test_wait_until_times_out_at_the_host_sized_deadline
test_wait_for_exit_honors_the_scaled_deadline_not_a_tick_count
