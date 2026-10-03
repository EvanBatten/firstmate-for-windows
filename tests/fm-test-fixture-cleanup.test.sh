#!/usr/bin/env bash
# Behavior tests for tests/lib.sh's shared fixture-tempdir helper
# (fm_test_tmproot / fm_test_cleanup / fm_test_reap_orphans) and its
# owned-process reaping (tests/proc-owner.sh), through both tests/lib.sh and
# bin/fm-test-run.sh.
#
# The near-universal call pattern across this suite is
# `TMP_ROOT=$(fm_test_tmproot prefix)`, which forks a subshell to capture the
# function's stdout. These tests spawn real, separate bash processes that use
# that exact pattern and assert the fixture root is actually gone once the
# owning process's guarded teardown has run - on a normal exit and on a
# terminating signal - plus that a stale marked fixture from a killed prior
# run gets reaped on the next source. Nothing here inspects tests/lib.sh's
# source text; it only observes filesystem state around the real helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"

test_fixture_root_gone_after_normal_exit() {
  local child_out child_dir
  child_out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-exit)
    printf "%s\n" "$d"
    if [ -d "$d" ]; then printf "mid:present\n"; else printf "mid:missing\n"; fi
  ')
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  assert_contains "$child_out" "mid:present" \
    "the fixture root was not present while its owning process was still alive"
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived its owning process's normal exit"
  pass "fm_test_tmproot cleans up its fixture root on normal exit"
}

test_fixture_root_gone_after_sigterm() {
  local harness dirfile child_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-sigterm-harness)
  dirfile="$harness/child-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-term)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the child never published its fixture root before the wait timed out"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the child's fixture root did not exist before it was signaled"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived SIGTERM to its owning process"
  pass "fm_test_tmproot cleans up its fixture root on SIGTERM"
}

test_cleanup_registry_resists_precreation() {
  local harness shared_tmp victim
  harness=$(fm_test_tmproot fm-test-cleanup-registry-harness)
  shared_tmp="$harness/shared-tmp"
  victim="$harness/victim"
  mkdir -p "$shared_tmp" "$victim"

  TMPDIR="$shared_tmp" bash -c '
    printf "%s\n" "$1" > "$TMPDIR/.fm-test-cleanup.$$"
    . "$2"
  ' _ "$victim" "$LIB"

  assert_present "$victim" \
    "a precreated predictable cleanup registry injected an arbitrary deletion target"
  pass "the cleanup registry cannot be injected through path precreation"
}

test_fixture_registration_failure_rolls_back_root() {
  local harness failure_tmp registry_dir output leaked_root
  harness=$(fm_test_tmproot fm-test-cleanup-registration-harness)
  failure_tmp="$harness/tmp"
  registry_dir="$harness/registry-dir"
  mkdir -p "$failure_tmp" "$registry_dir"

  if output=$(TMPDIR="$failure_tmp" FM_TEST_CLEANUP_REGISTRY="$registry_dir" \
    fm_test_tmproot fm-test-cleanup-registration-failure 2>/dev/null); then
    fail "fm_test_tmproot succeeded after its cleanup registry rejected registration"
  fi
  [ -z "$output" ] || fail "fm_test_tmproot published an unregistered fixture root"
  for leaked_root in "$failure_tmp"/fm-test-cleanup-registration-failure.*; do
    [ ! -e "$leaked_root" ] || fail "fm_test_tmproot leaked a root after registration failed"
  done
  pass "failed fixture registration rolls back the new root"
}

test_orphan_sweep_respects_fixture_ownership() {
  local harness dirfile active_dir stale_dir fresh_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-orphan-harness)
  dirfile="$harness/active-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-active)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the active child never published its fixture root before the wait timed out"
  active_dir=$(cat "$dirfile")
  touch -t 202001010000 "$active_dir/.fm-test-fixture"

  stale_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-stale.XXXXXX")
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"
  fresh_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-fresh.XXXXXX")
  : > "$fresh_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
  '

  assert_absent "$stale_dir" \
    "a stale fixture root whose PID was reused by another process was not reaped"
  assert_present "$active_dir" \
    "the orphan reaper removed an old fixture root whose owning process was still alive"
  assert_present "$fresh_dir" \
    "the orphan reaper removed a fresh marked fixture root it does not own yet"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$active_dir" \
    "the active fixture root survived its owning process's teardown"
  rm -rf "$fresh_dir"
  pass "the orphan sweep reaps only old fixtures without a live owner"
}

test_orphan_sweep_reaps_read_only_package_tree() {
  local stale_dir package_dir
  stale_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-read-only.XXXXXX")
  package_dir="$stale_dir/packages/extension"
  mkdir -p "$package_dir"
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  printf 'installed package\n' > "$package_dir/entrypoint.py"
  chmod -R a-w "$stale_dir/packages"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
  ' _ "$LIB"

  assert_absent "$stale_dir" \
    "the orphan reaper left a stale fixture containing a read-only package tree"
  pass "the orphan sweep reaps read-only package fixtures"
}

# A child suite starts a loop that ignores TERM and detaches from it, the shape
# of the fixtures that proved tree kills and then outlived their suites. It is
# launched the way the runner launches a script: on Linux a forked subshell
# carries only its suite's exec-time tag.
start_owned_loop_suite() {  # <pidfile> <then: exit|block>
  exec bash "$ROOT/tests/proc-owner.sh" -c '
    # shellcheck source=tests/lib.sh
    . "$1"
    ( trap "" TERM HUP INT; while :; do sleep 0.1; done ) </dev/null >/dev/null 2>&1 &
    printf "%s\n" "$!" > "$2"
    [ "$3" = exit ] || while :; do sleep 0.1; done
  ' _ "$LIB" "$1" "$2"
}

wait_for_file() {  # <file>
  local tries=0
  while [ ! -s "$1" ] && [ "$tries" -lt 100 ]; do sleep 0.05; tries=$((tries + 1)); done
  [ -s "$1" ] || fail "the child suite never published $1"
}

pid_gone_within() {  # <pid>
  local tries=0
  while kill -0 "$1" 2>/dev/null && [ "$tries" -lt 40 ]; do sleep 0.05; tries=$((tries + 1)); done
  ! kill -0 "$1" 2>/dev/null
}

test_owned_processes_gone_after_normal_exit() {
  local harness loop
  if [ -z "${FM_TEST_PROC_OWNER:-}" ]; then
    printf 'skip: no /proc/<pid>/environ to find owned processes by\n'
    return 0
  fi
  harness=$(fm_test_tmproot fm-test-cleanup-procs-exit)
  (start_owned_loop_suite "$harness/loop" exit)
  loop=$(cat "$harness/loop")
  pid_gone_within "$loop" ||
    { kill -KILL "$loop" 2>/dev/null; fail "a TERM-ignoring loop outlived its suite's normal exit"; }
  pass "a suite's exit kills every process it started, even one that ignores TERM"
}

test_hard_killed_suite_processes_reaped_by_next_suite() {
  local harness loop suite live_loop live_suite
  if [ -z "${FM_TEST_PROC_OWNER:-}" ]; then
    printf 'skip: no /proc/<pid>/environ to find owned processes by\n'
    return 0
  fi
  harness=$(fm_test_tmproot fm-test-cleanup-procs-kill)
  start_owned_loop_suite "$harness/loop" block &
  suite=$!
  start_owned_loop_suite "$harness/live-loop" block &
  live_suite=$!
  wait_for_file "$harness/loop"
  wait_for_file "$harness/live-loop"
  loop=$(cat "$harness/loop")
  live_loop=$(cat "$harness/live-loop")
  kill -KILL "$suite"
  wait "$suite" 2>/dev/null
  kill -0 "$loop" 2>/dev/null || fail "the loop died with its hard-killed suite, so this case proves nothing"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
  ' _ "$LIB"

  if ! pid_gone_within "$loop"; then
    kill -KILL "$loop" "$live_loop" "$live_suite" 2>/dev/null
    fail "the next suite left a hard-killed suite's loop running"
  fi
  kill -0 "$live_loop" 2>/dev/null || fail "the next suite killed a loop whose suite is still running"
  kill -TERM "$live_suite"
  wait "$live_suite" 2>/dev/null
  pid_gone_within "$live_loop" || fail "a TERM-ignoring loop outlived its suite's SIGTERM"
  pass "the next suite reaps only processes whose suite is gone"
}

# The runner tags a script before exec, so even a suite that never sources
# tests/lib.sh, or a subshell it forks, cannot outlive the run.
test_runner_reaps_what_a_suite_without_lib_leaves() {
  local harness loop out
  if [ -z "${FM_TEST_PROC_OWNER:-}" ]; then
    printf 'skip: no /proc/<pid>/environ to find owned processes by\n'
    return 0
  fi
  harness=$(fm_test_tmproot fm-test-cleanup-procs-runner)
  cat > "$harness/leaky.test.sh" <<'SH'
#!/usr/bin/env bash
( trap "" TERM HUP INT; while :; do sleep 0.1; done ) </dev/null >/dev/null 2>&1 &
printf '%s\n' "$!" > "$LEAK_PIDFILE"
printf 'ok - left a loop running\n'
SH
  out=$(LEAK_PIDFILE="$harness/loop" bash "$ROOT/bin/fm-test-run.sh" "$harness/leaky.test.sh" 2>&1) ||
    fail "the runner failed the leaky suite: $out"
  loop=$(cat "$harness/loop")
  pid_gone_within "$loop" ||
    { kill -KILL "$loop" 2>/dev/null; fail "a forked loop outlived its suite's run through bin/fm-test-run.sh"; }
  pass "the runner kills what a suite leaves running, even without tests/lib.sh"
}

# The runner tags a suite and then execs it, which on Git Bash starts a new
# process with a new start time. Another suite's sweep must still see it alive.
test_sweep_spares_a_live_suite_the_runner_launched() {
  local harness suite loop
  if [ -z "${FM_TEST_PROC_OWNER:-}" ]; then
    printf 'skip: no /proc/<pid>/environ to find owned processes by\n'
    return 0
  fi
  harness=$(fm_test_tmproot fm-test-cleanup-procs-launched)
  cat > "$harness/blocking.test.sh" <<'SH'
#!/usr/bin/env bash
( trap "" TERM HUP INT; while :; do sleep 0.1; done ) </dev/null >/dev/null 2>&1 &
printf '%s\n' "$!" > "$LEAK_PIDFILE"
while :; do sleep 0.1; done
SH
  LEAK_PIDFILE="$harness/loop" bash "$ROOT/tests/proc-owner.sh" "$harness/blocking.test.sh" &
  suite=$!
  wait_for_file "$harness/loop"
  loop=$(cat "$harness/loop")

  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
  ' _ "$LIB"

  if ! kill -0 "$loop" 2>/dev/null; then
    kill -KILL "$suite" 2>/dev/null
    fail "a sweep killed the loop of a suite the runner launched while that suite still ran"
  fi
  kill -KILL "$suite"
  wait "$suite" 2>/dev/null
  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
  ' _ "$LIB"
  pid_gone_within "$loop" ||
    { kill -KILL "$loop" 2>/dev/null; fail "the loop outlived its hard-killed runner-launched suite"; }
  pass "a sweep spares a live suite the runner launched and reaps it once it is gone"
}

test_fixture_root_gone_after_normal_exit
test_fixture_root_gone_after_sigterm
test_cleanup_registry_resists_precreation
test_fixture_registration_failure_rolls_back_root
test_orphan_sweep_respects_fixture_ownership
test_orphan_sweep_reaps_read_only_package_tree
test_owned_processes_gone_after_normal_exit
test_hard_killed_suite_processes_reaped_by_next_suite
test_runner_reaps_what_a_suite_without_lib_leaves
test_sweep_spares_a_live_suite_the_runner_launched
