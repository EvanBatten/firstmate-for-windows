#!/usr/bin/env bash
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1
# shellcheck source=platform/windows/env.sh
. platform/windows/env.sh
# shellcheck source=tests/lib.sh
. tests/lib.sh

home=$(fm_test_tmproot fm-win-test-home)/home
mkdir -p "$home/state"
printf '#!/usr/bin/env bash\nexit 0\n' > "$home/state/custom.check.sh"
chmod 0700 "$home/state/custom.check.sh"
out=$(FM_HOME=$home bin/fm-check-register.sh custom 2>&1) \
  || fail "fm-check-register refused a private check in a test home: $out"
pass "fm-check-register accepts a private check in a test home"

out=$(FM_HOME=$home bash -c umask)
[ "$out" = 0077 ] || fail "a product child for a test home ran at umask $out, not 0077"
pass "a product child for a test home runs at 077"
