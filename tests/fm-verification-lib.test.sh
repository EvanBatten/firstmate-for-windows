#!/usr/bin/env bash
# Pure helpers of the verification suite (tests/verification/lib.sh), driven
# with the host pinned.
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
