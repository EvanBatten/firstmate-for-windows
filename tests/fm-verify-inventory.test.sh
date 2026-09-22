#!/usr/bin/env bash
# The behavior inventory: what counts as a hole, and what counts as proof.
#
# inventory.sh check is the doctor's gate over behaviors.tsv, and inventory.sh
# verdict is the fraction verify.sh run appends after a drive. Each case here
# copies the real tests/verification/ suite and the real verify-firstmate
# skill into a throwaway git checkout, mutates one thing, and asserts the
# literal line the tool prints, so a change that silently stops checking
# something cannot pass this suite by accident.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# fm_verify_fixture: build a throwaway git checkout holding a copy of the real
# tests/verification/ suite and .agents/skills/verify-firstmate/ skill, commit
# it, and print its root. Every case mutates its own copy, so cases never share
# state and a removed row in one never leaks into another.
fm_verify_fixture() {
  local tmp
  tmp=$(fm_test_tmproot fm-verify-inventory) || fail "cannot create a tmp root"
  mkdir -p "$tmp/repo/bin" "$tmp/repo/tests" "$tmp/repo/.agents/skills" || fail "cannot scaffold the fixture"
  cp -r "$ROOT/tests/verification" "$tmp/repo/tests/verification" || fail "cannot copy tests/verification"
  cp -r "$ROOT/.agents/skills/verify-firstmate" "$tmp/repo/.agents/skills/verify-firstmate" \
    || fail "cannot copy the verify-firstmate skill"
  cp "$ROOT/README.md" "$tmp/repo/README.md" || fail "cannot copy README.md"
  git -C "$tmp/repo" -c core.autocrlf=false init -q || fail "cannot git init the fixture"
  git -C "$tmp/repo" -c core.autocrlf=false -c user.email=t@t -c user.name=t add -A \
    || fail "cannot git add the fixture"
  git -C "$tmp/repo" -c core.autocrlf=false -c user.email=t@t -c user.name=t commit -q -m fixture \
    || fail "cannot git commit the fixture"
  printf '%s\n' "$tmp/repo"
}

# fm_verify_counts_line <behaviors.tsv>: the exact "ok - inventory: ..." line
# inventory.sh check prints for that table, computed the same way the tool
# counts so a test failure means the tool disagreed with the data, not that
# this helper drifted from it.
fm_verify_counts_line() {
  awk -F'\t' '
    NR==1 { next }
    { total++ }
    $4=="proven"      { proven++ }
    $4=="unproven"    { unproven++ }
    $4=="broken"      { broken++ }
    $4=="blocked-here"{ blocked++ }
    END {
      printf "ok - inventory: %d behaviors, %d proven, %d unproven, %d broken, %d blocked here\n", \
        total+0, proven+0, unproven+0, broken+0, blocked+0
    }
  ' "$1"
}

test_check_passes_on_the_committed_table() {
  local fix tsv out rc want
  fix=$(fm_verify_fixture)
  tsv="$fix/.agents/skills/verify-firstmate/behaviors.tsv"
  want=$(fm_verify_counts_line "$tsv")
  out=$(bash "$fix/.agents/skills/verify-firstmate/inventory.sh" check); rc=$?
  expect_code 0 "$rc" "inventory.sh check must pass on the committed table"
  assert_contains "$out" "$want" "the counts line must report the table's real numbers"
  pass "inventory.sh check passes clean on the committed table and prints the real counts"
}

test_check_names_a_missing_bin_row() {
  local fix tsv out rc
  fix=$(fm_verify_fixture)
  tsv="$fix/.agents/skills/verify-firstmate/behaviors.tsv"
  awk -F'\t' '$2!="bin:fm-spawn.sh"' "$tsv" > "$tsv.new" && mv "$tsv.new" "$tsv"
  out=$(bash "$fix/.agents/skills/verify-firstmate/inventory.sh" check); rc=$?
  expect_code 1 "$rc" "a coverage.tsv entry with no bin: row must fail the check"
  assert_contains "$out" \
    "not ok - coverage.tsv names 'fm-spawn.sh' (kind=entry) with no bin:fm-spawn.sh row" \
    "the missing script must be named"
  pass "inventory.sh check names the exact coverage.tsv entry with no bin: row"
}

test_check_names_a_proven_row_with_no_script() {
  local fix tsv out rc
  fix=$(fm_verify_fixture)
  tsv="$fix/.agents/skills/verify-firstmate/behaviors.tsv"
  awk -F'\t' -v OFS='\t' '{ if ($2=="bin:fm-spawn.sh") { $4="proven"; $5="no-such-script" } print }' \
    "$tsv" > "$tsv.new" && mv "$tsv.new" "$tsv"
  out=$(bash "$fix/.agents/skills/verify-firstmate/inventory.sh" check); rc=$?
  expect_code 1 "$rc" "a proven row whose ref names no script must fail the check"
  assert_contains "$out" \
    "not ok - row 'fm-spawn' is proven but ref 'no-such-script' names no tests/verification/no-such-script.verify.sh" \
    "the offending row must be named"
  pass "inventory.sh check names a proven row whose ref matches no verification script"
}

test_verdict_counts_a_pass_only_for_a_proven_row() {
  local fix tsv log want_m want_h want_u out out2
  fix=$(fm_verify_fixture)
  tsv="$fix/.agents/skills/verify-firstmate/behaviors.tsv"
  log="$fix/run.log"
  printf 'result: captain-decision passed\n' > "$log"

  want_m=$(awk -F'\t' 'NR>1{n++} END{print n+0}' "$tsv")
  want_h=$(awk -F'\t' 'NR>1 && $4=="blocked-here"{n++} END{print n+0}' "$tsv")
  want_u=$((want_m - want_h))

  out=$(bash "$fix/.agents/skills/verify-firstmate/inventory.sh" verdict "$log")
  assert_contains "$out" \
    "proven 0 of $want_m behaviors; $want_u unproven; 0 broken; $want_h blocked here" \
    "no row is proven yet, so a passing script still proves nothing"

  awk -F'\t' -v OFS='\t' '{ if ($2=="bin:fm-spawn.sh") { $4="proven"; $5="captain-decision" } print }' \
    "$tsv" > "$tsv.new" && mv "$tsv.new" "$tsv"
  out2=$(bash "$fix/.agents/skills/verify-firstmate/inventory.sh" verdict "$log")
  assert_contains "$out2" \
    "proven 1 of $want_m behaviors; $((want_u - 1)) unproven; 0 broken; $want_h blocked here" \
    "a proven row whose script passed in this run must count toward the fraction"
  pass "inventory.sh verdict counts a pass toward proven only for a row that says proven"
}

test_verdict_never_counts_a_skip_as_proven() {
  local fix tsv log want_m want_h want_u out
  fix=$(fm_verify_fixture)
  tsv="$fix/.agents/skills/verify-firstmate/behaviors.tsv"
  awk -F'\t' -v OFS='\t' '{ if ($2=="bin:fm-spawn.sh") { $4="proven"; $5="captain-decision" } print }' \
    "$tsv" > "$tsv.new" && mv "$tsv.new" "$tsv"

  want_m=$(awk -F'\t' 'NR>1{n++} END{print n+0}' "$tsv")
  want_h=$(awk -F'\t' 'NR>1 && $4=="blocked-here"{n++} END{print n+0}' "$tsv")
  want_u=$((want_m - want_h))

  log="$fix/run.log"
  printf 'result: captain-decision skipped\n' > "$log"
  out=$(bash "$fix/.agents/skills/verify-firstmate/inventory.sh" verdict "$log")
  assert_contains "$out" \
    "proven 0 of $want_m behaviors; $want_u unproven; 0 broken; $want_h blocked here" \
    "a proven row whose script skipped this run must count as unproven, never as proven"
  pass "inventory.sh verdict counts a skipped proven-row script as unproven"
}

test_doctor_refuses_a_missing_feature_row() {
  local fix tsv out rc
  fix=$(fm_verify_fixture)
  tsv="$fix/.agents/skills/verify-firstmate/behaviors.tsv"
  awk -F'\t' '$2!="feature:wake-queue"' "$tsv" > "$tsv.new" && mv "$tsv.new" "$tsv"
  out=$(bash "$fix/.agents/skills/verify-firstmate/verify.sh" doctor); rc=$?
  expect_code 1 "$rc" "a missing feature: row must make the doctor refuse the checkout"
  assert_contains "$out" "not ok - features/wake-queue.md has no feature:wake-queue row" \
    "the doctor must relay the inventory's own hole message"
  pass "verify.sh doctor refuses a checkout whose inventory is missing a feature row"
}


test_check_refuses_a_row_proven_by_a_drive() {
  local fix tsv out rc
  fix=$(fm_verify_fixture)
  tsv="$fix/.agents/skills/verify-firstmate/behaviors.tsv"
  awk -F'\t' -v OFS='\t' '{ if ($2=="feature:wake-queue") { $4="proven"; $5="wake-queue" } print }' \
    "$tsv" > "$tsv.new" && mv "$tsv.new" "$tsv"
  out=$(bash "$fix/.agents/skills/verify-firstmate/inventory.sh" check); rc=$?
  expect_code 1 "$rc" "a row proven by a drive script must fail the check"
  assert_contains "$out" \
    "not ok - row 'feature-wake-queue' is proven by 'wake-queue', which drives scripts itself instead of running a session; only a session script proves a behavior" \
    "the offending row must be named"
  awk -F'\t' -v OFS='\t' '{ if ($2=="feature:wake-queue") { $5="ship-three-parallel" } print }' \
    "$tsv" > "$tsv.new" && mv "$tsv.new" "$tsv"
  out=$(bash "$fix/.agents/skills/verify-firstmate/inventory.sh" check); rc=$?
  expect_code 0 "$rc" "the same row proven by a session script must pass the check"
  pass "inventory.sh check accepts a proven row only when a session script proves it"
}

test_check_passes_on_the_committed_table
test_check_names_a_missing_bin_row
test_check_names_a_proven_row_with_no_script
test_check_refuses_a_row_proven_by_a_drive
test_verdict_counts_a_pass_only_for_a_proven_row
test_verdict_never_counts_a_skip_as_proven
test_doctor_refuses_a_missing_feature_row
