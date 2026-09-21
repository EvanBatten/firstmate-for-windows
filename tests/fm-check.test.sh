#!/usr/bin/env bash
# bin/fm-check.sh: the order of its layers and the shape of its interface.
#
# The layers themselves are owned and tested elsewhere (fm-lint, the doc
# audience check, the repository invariants). What this pins is what fm-check
# adds: a fixed cheapest-first order, a stop at the first failing layer that
# names it, and a refusal of arguments it does not know.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-check.sh"

test_layers_run_cheapest_first() {
  local listed
  listed=$("$CHECK" --list) || fail "fm-check.sh --list failed"
  [ "$(printf '%s\n' "$listed" | sed -n '1,3p' | tr '\n' ' ')" = "syntax docs lint " ] \
    || fail "the static layers must run in the order syntax, docs, lint; got: $listed"
  assert_contains "$listed" "tests (with --tests)" "the test layer must be listed as opt-in"
  pass "fm-check.sh runs syntax, then docs, then lint, and tests only when asked"
}

test_unknown_arguments_are_refused() {
  "$CHECK" --no-such-flag >/dev/null 2>&1
  expect_code 2 $? "an unknown flag must be bad usage, not a silent full run"
  "$CHECK" --tests extra >/dev/null 2>&1
  expect_code 2 $? "a second argument must be bad usage"
  pass "fm-check.sh refuses arguments it does not know"
}

test_a_failing_layer_stops_the_run_and_is_named() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-check-stop)
  mkdir -p "$tmp/repo/bin"
  cp "$CHECK" "$tmp/repo/bin/fm-check.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/repo/bin/fm-lint.sh"
  printf '#!/usr/bin/env bash\necho "docs ran"; exit 1\n' > "$tmp/repo/bin/fm-doc-audience-check.sh"
  printf '#!/usr/bin/env bash\necho "tests ran"\n' > "$tmp/repo/bin/fm-test-run.sh"
  chmod +x "$tmp/repo/bin/"*.sh
  out=$("$tmp/repo/bin/fm-check.sh" --tests 2>&1); rc=$?
  expect_code 1 "$rc" "a failing layer must fail the check"
  assert_contains "$out" "FAILED at the docs layer" "the failing layer must be named"
  assert_not_contains "$out" "== lint" "no later layer may run after a failure"
  assert_not_contains "$out" "tests ran" "the test layer must not run after a failure"
  pass "fm-check.sh stops at the first failing layer and names it"
}

test_layers_run_cheapest_first
test_unknown_arguments_are_refused
test_a_failing_layer_stops_the_run_and_is_named
