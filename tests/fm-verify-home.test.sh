#!/usr/bin/env bash
# Behavior tests for throwaway / verify-home safe auto-answers.
#
# A marked verify home seeds trust-yes, background-work Enter,
# --dangerously-skip-permissions, and pre-grant land. Ask-user and
# tool-install prompts are classified so a caller can fail immediately.
# A captain home is not seeded.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-$(fm_test_base_path)}
TMP_ROOT=$(fm_test_tmproot fm-verify-home)
VERIFY_HOME_BIN="$ROOT/bin/fm-verify-home.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

classify() {
  printf '%s' "$1" | "$VERIFY_HOME_BIN" classify
}

test_unmarked_home_is_not_active_and_not_seeded() {
  local home
  home="$TMP_ROOT/unmarked/home"
  mkdir -p "$home/data" "$home/config"
  "$VERIFY_HOME_BIN" active --home "$home" \
    && fail "active exited 0 on an unmarked captain home"
  [ ! -f "$home/data/captain.md" ] \
    || fail "an unmarked home already had captain.md before seed"
  pass "an unmarked captain home is not a verify home"
}

test_seed_writes_safe_answers_only() {
  local home flags captain
  home="$TMP_ROOT/seed-answers/home"
  mkdir -p "$home"
  "$VERIFY_HOME_BIN" seed --home "$home"
  "$VERIFY_HOME_BIN" active --home "$home" \
    || fail "active exited nonzero after seed"
  [ -f "$home/.fm-control-throwaway" ] \
    || fail "seed did not write .fm-control-throwaway"
  [ -f "$home/config/verify-claude-flags.json" ] \
    || fail "seed did not write config/verify-claude-flags.json"
  [ ! -f "$home/config/skip-tool-install" ] \
    || fail "seed wrote a skip-tool-install flag; tools must not be auto-installed"
  captain=$(cat "$home/data/captain.md")
  assert_contains "$captain" "Land the work this session already assigned and approved." \
    "seeded captain.md missing pre-grant-land"
  assert_contains "$captain" "Prefer claude --dangerously-skip-permissions on this home." \
    "seeded captain.md missing skip-permissions"
  assert_contains "$captain" "Never answer ask-user or needs-decision findings yourself." \
    "seeded captain.md must refuse ask-user auto-answers"
  assert_contains "$captain" "Never install tools from this session." \
    "seeded captain.md must refuse auto-install"
  flags=$(cat "$home/config/verify-claude-flags.json")
  assert_contains "$flags" '"hasTrustDialogAccepted":true' \
    "seeded Claude flags missing trust-yes"
  assert_contains "$flags" '"bypassPermissionsModeAccepted":true' \
    "seeded Claude flags missing skip-permissions"
  assert_not_contains "$flags" 'hasCompletedOnboarding' \
    "seeded Claude flags included out-of-scope onboarding"
  pass "seed writes trust, skip-permissions, and pre-grant land only"
}

test_seed_preserves_existing_captain_md() {
  local home
  home="$TMP_ROOT/preserve-captain/home"
  mkdir -p "$home/data"
  printf 'keep this preference\n' > "$home/data/captain.md"
  "$VERIFY_HOME_BIN" seed --home "$home"
  [ "$(cat "$home/data/captain.md")" = "keep this preference" ] \
    || fail "seed overwrote an existing captain.md"
  pass "seed leaves an existing captain.md untouched"
}

test_env_flags_are_active_without_seed() {
  local home
  home="$TMP_ROOT/env-only/home"
  mkdir -p "$home"
  FM_VERIFY_HOME=1 "$VERIFY_HOME_BIN" active --home "$home" \
    || fail "FM_VERIFY_HOME=1 was not treated as a verify home"
  FM_SESSION_START_FAST=1 "$VERIFY_HOME_BIN" active --home "$home" \
    || fail "FM_SESSION_START_FAST=1 was not treated as a verify home"
  pass "verify env flags mark a home active without writing files"
}

test_classify_safe_and_forbidden_prompts() {
  local class
  class=$(classify '❯ No
Yes, I trust this folder
❯ Yes')
  [ "$class" = trust-yes ] || fail "folder-trust classified as $class"
  class=$(classify 'Background work is running
1. Exit and stop tasks')
  [ "$class" = background-work-enter ] || fail "background-work classified as $class"
  class=$(classify 'needs-decision: ask-user finding about the product copy')
  [ "$class" = ask-user ] || fail "ask-user classified as $class"
  class=$(classify 'MISSING: treehouse (install: curl -fsSL ...)')
  [ "$class" = blocked ] || fail "tool-install classified as $class"
  class=$(classify 'install treehouse or make an isolated copy')
  [ "$class" = blocked ] || fail "treehouse-or-copy classified as $class"
  class=$(classify 'the worker is still building greet.sh')
  [ "$class" = none ] || fail "ordinary pane text classified as $class"
  pass "classify names trust-yes, background-work-enter, ask-user, and blocked"
}

test_scripted_classify_is_fast() {
  local class elapsed
  SECONDS=0
  class=$(classify 'Yes, I trust this folder')
  elapsed=$SECONDS
  [ "$class" = trust-yes ] || fail "timed classify missed trust-yes"
  [ "$elapsed" -lt 5 ] \
    || fail "classify took ${elapsed}s; a parked trust prompt would have sat for ~180s"
  printf 'ok - scripted trust-yes classify finished in %ss (dispatch budget is ~180s)\n' "$elapsed"
}

test_unmarked_bootstrap_still_prints_missing() {
  local home root out
  root="$TMP_ROOT/captain-bootstrap/root"
  home="$TMP_ROOT/captain-bootstrap/home"
  mkdir -p "$home/data" "$home/state" "$home/config" "$root"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  out=$(
    env -u FM_VERIFY_HOME -u FM_SESSION_START_FAST \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
      FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
      PATH="$BASE_PATH" \
      "$BOOTSTRAP"
  )
  assert_contains "$out" "MISSING: treehouse" \
    "an unmarked captain home must still print missing-tool consent"
  pass "an unmarked captain home still surfaces missing-tool consent"
}

test_unmarked_home_is_not_active_and_not_seeded
test_unmarked_bootstrap_still_prints_missing
test_seed_writes_safe_answers_only
test_seed_preserves_existing_captain_md
test_env_flags_are_active_without_seed
test_classify_safe_and_forbidden_prompts
test_scripted_classify_is_fast
