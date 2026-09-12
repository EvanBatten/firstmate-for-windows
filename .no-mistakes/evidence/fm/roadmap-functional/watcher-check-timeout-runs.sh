#!/usr/bin/env bash
# Round-2 evidence for the scaled per-check bound in run_watcher_bounded
# (tests/fm-pr-check-security.test.sh). Runs one-case copies of the suite
# (every helper, one invocation) from the worktree's tests/ directory.
#   lane "repeat": the formerly flaky case, unchanged, N times in a row.
#   lane "mechanism": the same case with the fake forge's state query slowed
#     to 2 s (FM_TEST_GH_SLEEP, the knob test_static_poll_contract already uses),
#     once under the old literal one-second bound (FM_TEST_CHECK_TIMEOUT=1) and
#     once under the new host-scaled default; then test_static_poll_contract,
#     the one case that depends on a one-second timeout, unchanged.
# usage: watcher-check-timeout-runs.sh <worktree> <repeat|mechanism> [N]
set -u
wt=$1 lane=$2 n=${3:-3}
cd "$wt" || exit 2
run() {  # <label> <suite> [env...]
  local label=$1 suite=$2 start end rc out
  shift 2
  start=$(date +%s)
  out=$(env "$@" bash "tests/$suite" 2>&1)
  rc=$?
  end=$(date +%s)
  echo "### $label"
  printf '%s\n' "$out" | grep -E '^(ok|not ok) - |^# host time scale' | cut -c1-220
  echo "exit=$rc $((end - start))s"
}
case "$lane" in
  repeat)
    i=1
    while [ "$i" -le "$n" ]; do
      run "run $i: test_valid_recording_and_merge_derivation (default, host-scaled check bound)" \
        fm-zz-onecase-valid_recording_and_merge_derivation.test.sh
      i=$((i + 1))
    done
    ;;
  mechanism)
    run "slow check (2 s) under the OLD literal one-second bound: FM_TEST_CHECK_TIMEOUT=1 FM_TEST_GH_SLEEP=2" \
      fm-zz-onecase-valid_recording_and_merge_derivation.test.sh FM_TEST_CHECK_TIMEOUT=1 FM_TEST_GH_SLEEP=2
    run "slow check (2 s) under the NEW default host-scaled bound: FM_TEST_GH_SLEEP=2" \
      fm-zz-onecase-valid_recording_and_merge_derivation.test.sh FM_TEST_GH_SLEEP=2
    run "test_static_poll_contract (needs its direct run_check to time out at a literal 1 s)" \
      fm-zz-onecase-static_poll_contract.test.sh
    ;;
esac
