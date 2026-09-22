#!/usr/bin/env bash
# The state/ lock treats one directory reached by two spellings as one owner,
# and a takeover never recurses past a takeover of a takeover (#82). On Git
# Bash the temp directory's /tmp alias gave every lock two spellings; a fresh
# home there grew a .steal chain one level every two seconds until the path
# limit. The second spelling here is a symlinked directory, which every
# platform can make.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK_TMP=$(fm_test_tmproot fm-lock-two-spellings)
mkdir -p "$LOCK_TMP/real/state"
ln -s "$LOCK_TMP/real" "$LOCK_TMP/alias"
LOCK_STATE="$LOCK_TMP/real/state"

test_a_differently_spelled_link_still_points_to_its_owner() {
  local owner="$LOCK_TMP/alias/state/.x.lock.owner.abc" other="$LOCK_TMP/alias/state/.x.lock.owner.def" rc
  mkdir -p "$owner" "$other"
  ln -s "$LOCK_STATE/.x.lock.owner.abc" "$LOCK_STATE/.x.lock"
  (
    FM_HOME="$LOCK_TMP/real" FM_STATE_OVERRIDE="$LOCK_STATE" . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_points_to_owner "$LOCK_STATE/.x.lock" "$owner"
  )
  expect_code 0 $? "a link whose target is the owner directory under another spelling must count as pointing to it"
  (
    FM_HOME="$LOCK_TMP/real" FM_STATE_OVERRIDE="$LOCK_STATE" . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_points_to_owner "$LOCK_STATE/.x.lock" "$other"
  )
  rc=$?
  expect_code 1 "$rc" "a link to a different owner directory must not count as pointing to this one"
  pass "the lock compares owner directories by identity, not by the text of their paths"
}

test_a_takeover_never_recurses_past_two_levels() {
  local out rc deeper
  # Every claim fails, as it did when the two spellings were compared as
  # text; the bounded wait keeps retrying, which is what grew the chain.
  # shellcheck disable=SC2016 # the inner shell expands these, not this one
  out=$(timeout 60 bash -c '
    FM_HOME="$1" FM_STATE_OVERRIDE="$2" . "$3/bin/fm-wake-lib.sh"
    fm_lock_points_to_owner() { return 1; }
    FM_LOCK_WAIT_DEADLINE=$(( $(date +%s) + 25 ))
    fm_lock_acquire_wait "$2/.y.lock"
    printf "rc=%s\n" "$?"
  ' _ "$LOCK_TMP/real" "$LOCK_STATE" "$ROOT" 2>&1)
  rc=$?
  expect_code 0 "$rc" "a bounded wait whose every claim fails must give up at its deadline (timeout means it hung)"
  assert_contains "$out" "rc=1" "a bounded wait whose every claim fails must report that it gave up"
  deeper=$(find "$LOCK_STATE" -maxdepth 1 -name '.y.lock.steal.steal.steal*' | wc -l | tr -d ' ')
  [ "$deeper" -eq 0 ] || fail "a takeover chain deeper than two levels was created: $(find "$LOCK_STATE" -maxdepth 1 -name '.y.lock.steal.steal.steal*' | sed 's|.*/||' | tr '\n' ' ')"
  pass "a takeover stops at a takeover of a takeover instead of growing without bound"
}

test_a_differently_spelled_link_still_points_to_its_owner
test_a_takeover_never_recurses_past_two_levels
