#!/usr/bin/env bash
# verify.sh doctor warns on Windows exactly when a verification home comes up
# without the platform overlay. Each case runs the real doctor and the real
# tests/verification/lib.sh in a fixture checkout whose uname reports Windows.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-verify-doctor)
WARN='the suite drives bin/ without platform/windows/env.sh'

# fixture <name> <uname -s>: a checkout holding the doctor, the suite library,
# and an env.sh stub that exports the variable the real overlay exports.
fixture() {
  local repo="$TMP_ROOT/$1"
  fm_git_init_commit "$repo" >/dev/null
  mkdir -p "$repo/.agents/skills/verify-firstmate" "$repo/tests/verification" "$repo/bin" "$repo/platform/windows" "$repo/fakebin"
  cp "$ROOT/.agents/skills/verify-firstmate/verify.sh" "$repo/.agents/skills/verify-firstmate/"
  cp "$ROOT/tests/verification/lib.sh" "$ROOT/tests/verification/run.sh" "$repo/tests/verification/"
  cp "$ROOT/.tasks.toml" "$repo/"
  printf 'FM_PLATFORM_OVERLAY=%s/overrides.sh\nexport FM_PLATFORM_OVERLAY\n' "$repo/platform/windows" > "$repo/platform/windows/env.sh"
  printf '#!/bin/sh\necho %s\n' "$2" > "$repo/fakebin/uname"
  chmod +x "$repo/fakebin/uname"
  printf '%s\n' "$repo"
}

doctor() {  # <repo>
  PATH="$1/fakebin:$PATH" bash "$1/.agents/skills/verify-firstmate/verify.sh" doctor 2>&1
}

repo=$(fixture loads MINGW64_NT-10.0)
assert_not_contains "$(FM_PLATFORM_OVERLAY='' doctor "$repo")" "$WARN" "a suite home that loads the overlay must not warn"
pass "no warning when a suite home loads the overlay"

repo=$(fixture skips MINGW64_NT-10.0)
# shellcheck disable=SC2016 # sed text, not shell
sed -i 's/^  verify_platform_overlay "\$VERIFY_HOME"$/  # verify_platform_overlay "$VERIFY_HOME" would load platform\/windows\/env.sh/' "$repo/tests/verification/lib.sh"
grep -q '^  # verify_platform_overlay' "$repo/tests/verification/lib.sh" || fail "the fixture did not disable the overlay call in lib.sh"
assert_contains "$(FM_PLATFORM_OVERLAY='' doctor "$repo")" "$WARN" "a suite home without the overlay must warn even when lib.sh names env.sh"
pass "a warning when a suite home skips the overlay, whatever lib.sh mentions"

assert_contains "$(FM_PLATFORM_OVERLAY="$repo/platform/windows/overrides.sh" doctor "$repo")" "$WARN" "the caller's own overlay must not stand in for the suite's"
pass "a caller already under the overlay does not hide the warning"

repo=$(fixture absent MINGW64_NT-10.0)
rm "$repo/platform/windows/env.sh"
assert_not_contains "$(doctor "$repo")" "$WARN" "a checkout with no overlay to load must not warn"
pass "no warning when the checkout has no overlay"

repo=$(fixture linux Linux)
# shellcheck disable=SC2016 # sed text, not shell
sed -i 's/^  verify_platform_overlay "\$VERIFY_HOME"$//' "$repo/tests/verification/lib.sh"
assert_not_contains "$(doctor "$repo")" "$WARN" "a non-Windows host must not warn"
pass "no warning off Windows"
