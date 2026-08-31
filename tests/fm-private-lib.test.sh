#!/usr/bin/env bash
# tests/fm-private-lib.test.sh - unit tests for bin/fm-private-lib.sh, the one
# owner of decision D6: create and check mode-700/600 private state on
# filesystems that may not carry POSIX modes (ledger row 21).
#
# The library branches on ONE measured fact: whether a chmod 700 under the
# target's own directory reads back as 700. Both branches are driven from any
# host by putting a scripted `stat` on PATH - a stat that reports 700 is a
# mode-capable filesystem, one that reports 755 is a noacl mount - while
# mktemp, chmod, and mkdir stay real, so the operations themselves still run.
# The cases are therefore the same cases everywhere, not two sets that only
# ever run on one machine each.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-private-lib)
LIB="$ROOT/bin/fm-private-lib.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-$(fm_test_base_path)}

# A fakebin whose stat reports the scripted mode for every path, logging each
# call to FAKE_STAT_LOG when set so a case can count probe reads.
mode_stat_fakebin() {  # <dir> <mode>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/stat" <<SH
#!/usr/bin/env bash
[ -z "\${FAKE_STAT_LOG:-}" ] || printf '%s\n' "\$*" >> "\$FAKE_STAT_LOG"
printf '%s\n' "$2"
SH
  chmod +x "$fakebin/stat"
  printf '%s\n' "$fakebin"
}

# Run <expression> against the library in a child bash. The fake stat (when a
# fakebin is given) wins over the real one; everything else resolves from the
# base path. One child per call, so each case measures a fresh process.
lib_sh() {  # <fakebin-or-empty> <expression> [args...]
  local extra=$1 expr=$2 p
  shift 2
  p=$BASE_PATH
  [ -z "$extra" ] || p="$extra:$BASE_PATH"
  FM_TEST_LIB="$LIB" FM_TEST_EXPR="$expr" PATH="$p" "$BASH" -c \
    '. "$FM_TEST_LIB"; eval "$FM_TEST_EXPR"' _ "$@"
}

# ---------------------------------------------------------------------------

test_capable_exact_mode_passes_silently() {
  local dir fakebin f err
  dir="$TMP_ROOT/cap-exact"; mkdir -p "$dir"
  fakebin=$(mode_stat_fakebin "$dir" 700)
  f="$dir/secret"; : > "$f"
  err=$(lib_sh "$fakebin" 'fm_private_mode_ok "$1" 700' "$f" 2>&1 >/dev/null) \
    || fail "an exact mode must pass on a mode-capable filesystem"
  [ -z "$err" ] || fail "an exact mode must pass without a warning (got: $err)"
  pass "a matching mode passes with no probe noise on a capable filesystem"
}

test_capable_wrong_mode_refused() {
  local dir fakebin f
  dir="$TMP_ROOT/cap-wrong"; mkdir -p "$dir"
  fakebin=$(mode_stat_fakebin "$dir" 700)
  f="$dir/secret"; : > "$f"
  lib_sh "$fakebin" 'fm_private_mode_ok "$1" 600' "$f" 2>/dev/null \
    && fail "a wrong mode must still be refused where modes are representable"
  lib_sh "$fakebin" 'fm_private_file_chmod 600 "$1"' "$f" 2>/dev/null \
    && fail "a chmod whose readback disagrees must fail where modes are representable"
  pass "a capable filesystem still refuses a wrong mode"
}

test_capable_operations_match_their_old_shape() {
  local dir fakebin f
  dir="$TMP_ROOT/cap-ops"; mkdir -p "$dir"
  fakebin=$(mode_stat_fakebin "$dir" 700)
  : > "$dir/tool"
  lib_sh "$fakebin" 'fm_private_mkdir "$1/sub" && fm_private_file_chmod 700 "$2"' \
    "$dir" "$dir/tool" 2>/dev/null \
    || fail "private mkdir and chmod must succeed when the readback agrees"
  [ -d "$dir/sub" ] || fail "private mkdir must create the directory"
  # Leading zeros never change the answer: 0600 and 600 are one octal mode.
  dir="$TMP_ROOT/cap-zeros"; mkdir -p "$dir"
  fakebin=$(mode_stat_fakebin "$dir" 600)
  f="$dir/f"; : > "$f"
  lib_sh "$fakebin" 'fm_private_file_chmod 0600 "$1"' "$f" 2>/dev/null \
    || fail "a leading zero in the requested mode must compare as the same octal"
  pass "capable-branch operations create, chmod, and verify exactly"
}

test_incapable_accepts_and_warns_once_per_process() {
  local dir fakebin f err
  dir="$TMP_ROOT/noacl-warn"; mkdir -p "$dir"
  fakebin=$(mode_stat_fakebin "$dir" 755)
  f="$dir/secret"; : > "$f"
  err=$(lib_sh "$fakebin" 'fm_private_mode_ok "$1" 600 && fm_private_mode_ok "$1" 700' \
    "$f" 2>&1 >/dev/null) || fail "a mount that drops modes must accept the best effort"
  [ "$(printf '%s\n' "$err" | grep -c 'fm-private')" = 1 ] \
    || fail "two accepting checks in one process must warn exactly once (got: $err)"
  pass "the relaxation is accepted with one stderr warning per process"
}

test_incapable_operations_succeed() {
  local dir fakebin f
  dir="$TMP_ROOT/noacl-ops"; mkdir -p "$dir"
  fakebin=$(mode_stat_fakebin "$dir" 755)
  f="$dir/secret"; : > "$f"
  lib_sh "$fakebin" 'fm_private_mkdir "$1/sub" && fm_private_file_chmod 600 "$2"' \
    "$dir" "$f" 2>/dev/null || fail "private mkdir and chmod must accept on a mount that drops modes"
  [ -d "$dir/sub" ] || fail "private mkdir must still create the directory"
  pass "operations succeed as best effort where modes are unrepresentable"
}

test_probe_runs_once_and_cleans_up() {
  local dir fakebin f log leftovers
  dir="$TMP_ROOT/probe-once"; mkdir -p "$dir"
  fakebin=$(mode_stat_fakebin "$dir" 755)
  f="$dir/secret"; : > "$f"
  log="$TMP_ROOT/probe-once.stat.log"
  FAKE_STAT_LOG="$log" lib_sh "$fakebin" \
    'fm_private_mode_ok "$1" 600 && fm_private_mode_ok "$1" 700 && fm_private_file_chmod 600 "$1"' \
    "$f" 2>/dev/null || fail "accepting checks must not fail while counting probes"
  [ "$(grep -c 'fm-private-probe' "$log")" = 1 ] \
    || fail "the capability must be measured exactly once per process (log: $(cat "$log"))"
  leftovers=$(find "$dir" -name '.fm-private-probe.*' -print 2>/dev/null)
  [ -z "$leftovers" ] || fail "the probe directory must be removed: $leftovers"
  pass "the capability probe runs once per process and leaves nothing behind"
}

test_unreadable_or_garbage_modes_refused() {
  local dir fakebin f
  dir="$TMP_ROOT/garbage"; mkdir -p "$dir"
  fakebin=$(mode_stat_fakebin "$dir" notoctal)
  f="$dir/secret"; : > "$f"
  lib_sh "$fakebin" 'fm_private_mode_ok "$1" 600' "$f" 2>/dev/null \
    && fail "a non-octal stat answer must refuse, not probe"
  lib_sh '' 'fm_private_mode_ok "$1" 600' "$TMP_ROOT/absent" 2>/dev/null \
    && fail "a missing path must refuse"
  pass "garbage stat output and missing paths are refusals"
}

test_real_host_end_to_end() {
  local dir
  dir="$TMP_ROOT/e2e"
  lib_sh '' 'fm_private_mkdir "$1/keep" && : > "$1/keep/k" \
    && fm_private_file_chmod 600 "$1/keep/k" \
    && fm_private_mode_ok "$1/keep" 700 && fm_private_mode_ok "$1/keep/k" 600' \
    "$dir" 2>/dev/null || fail "the real host must accept its own private state end to end"
  [ -d "$dir/keep" ] || fail "the end-to-end directory must exist"
  pass "the real filesystem takes whichever branch it measures, end to end"
}

test_capable_exact_mode_passes_silently
test_capable_wrong_mode_refused
test_capable_operations_match_their_old_shape
test_incapable_accepts_and_warns_once_per_process
test_incapable_operations_succeed
test_probe_runs_once_and_cleans_up
test_unreadable_or_garbage_modes_refused
test_real_host_end_to_end
