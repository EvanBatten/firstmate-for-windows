#!/usr/bin/env bash
# tests/lib.sh helpers that have no suite of their own.
#
# fm_test_sha256 is proven on each of its two tools with the other one masked.
# The mask is a BASH_ENV shim rather than a fakebin, because both tools live in
# system directories a fixture PATH still needs (tests/fm-bootstrap.test.sh uses
# the same trick for git). Each run asserts, inside the masked shell, that the
# masked tool is really unreachable before it takes the digest, and the digest is
# compared against a literal, so a helper that printed nothing, printed the
# wrong field, or quietly used the masked tool cannot pass.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-lib)

# printf 'fm_test_sha256 fixture\n', hashed by sha256sum, shasum -a 256 and
# node's crypto, which agree.
SHA256_FIXTURE_DIGEST=5af52fb8ed5a9715d3ed8db9e113adb70dacc3d17e1581f9c696fe3759ad90f3
SHA256_FIXTURE="$TMP_ROOT/sha256 fixture"
printf 'fm_test_sha256 fixture\n' > "$SHA256_FIXTURE"

# write_mask <file> <tool>...: a BASH_ENV shim under which each named tool is
# neither found by `command -v` nor runnable.
write_mask() {
  local file=$1 tool
  shift
  {
    printf 'FM_MASKED_TOOLS="%s"\n' "$*"
    cat <<'SH'
command() {
  local tool
  if [ "${1:-}" = -v ] || [ "${1:-}" = -V ]; then
    for tool in $FM_MASKED_TOOLS; do
      [ "${2:-}" = "$tool" ] && return 1
    done
  fi
  builtin command "$@"
}
SH
    for tool in "$@"; do
      printf '%s() { printf "%%s: command not found\\n" %s >&2; return 127; }\n' "$tool" "$tool"
    done
  } > "$file"
}

# run_masked <mask-file> <body>: a fresh shell under the mask, with this file's
# fm_test_sha256 and fm_test_sha256_stdin definitions and the fixture path as $1.
run_masked() {
  BASH_ENV="$1" bash -c "$(declare -f fm_test_sha256 fm_test_sha256_stdin)
$2" _ "$SHA256_FIXTURE"
}

# shellcheck disable=SC2016  # the body is evaluated by the masked shell
MASKED_DIGESTS='
set -u
tool=$FM_MASKED_TOOLS
if command -v "$tool" >/dev/null 2>&1; then
  echo "mask-leak: command -v still finds $tool"; exit 3
fi
"$tool" </dev/null >/dev/null 2>&1
rc=$?
[ "$rc" -eq 127 ] || { echo "mask-leak: $tool still runs (rc=$rc)"; exit 3; }
printf "file=%s\n" "$(fm_test_sha256 "$1")"
printf "stdin=%s\n" "$(printf "fm_test_sha256 fixture\n" | fm_test_sha256_stdin)"
'

assert_both_forms_digest() {  # <out> <which>
  assert_contains "$1" "file=$SHA256_FIXTURE_DIGEST" "$2: the file form did not print the fixture digest"
  assert_contains "$1" "stdin=$SHA256_FIXTURE_DIGEST" "$2: the stdin form did not print the fixture digest"
}

test_sha256_uses_sha256sum_when_shasum_is_absent() {
  local mask out rc=0
  command -v sha256sum >/dev/null 2>&1 || {
    echo "skip: sha256sum not on this host, so its branch cannot be proven here"
    return 0
  }
  mask="$TMP_ROOT/no-shasum.bash"
  write_mask "$mask" shasum
  out=$(run_masked "$mask" "$MASKED_DIGESTS" 2>&1) || rc=$?
  expect_code 0 "$rc" "the shasum-masked run: $out"
  assert_both_forms_digest "$out" "shasum masked"
  pass "fm_test_sha256 digests a file and stdin with sha256sum alone (shasum proven unreachable)"
}

test_sha256_falls_back_to_shasum_when_sha256sum_is_absent() {
  local mask out rc=0
  command -v shasum >/dev/null 2>&1 || {
    echo "skip: shasum not on this host, so the fallback branch cannot be proven here"
    return 0
  }
  mask="$TMP_ROOT/no-sha256sum.bash"
  write_mask "$mask" sha256sum
  out=$(run_masked "$mask" "$MASKED_DIGESTS" 2>&1) || rc=$?
  expect_code 0 "$rc" "the sha256sum-masked run: $out"
  assert_both_forms_digest "$out" "sha256sum masked"
  pass "fm_test_sha256 digests a file and stdin with shasum -a 256 alone (sha256sum proven unreachable)"
}

# shellcheck disable=SC2016  # the body is evaluated by the masked shell
test_sha256_fails_loudly_with_neither_tool() {
  local mask out err rc=0
  mask="$TMP_ROOT/no-hashers.bash"
  write_mask "$mask" sha256sum shasum
  out=$(run_masked "$mask" 'fm_test_sha256 "$1"' 2>"$TMP_ROOT/neither.err") || rc=$?
  err=$(cat "$TMP_ROOT/neither.err")
  [ "$rc" -ne 0 ] || fail "fm_test_sha256 succeeded with no hasher: out='$out'"
  [ -z "$out" ] || fail "fm_test_sha256 printed a non-digest with no hasher: '$out'"
  assert_contains "$err" "fm_test_sha256: neither sha256sum nor shasum -a 256 produced a digest" \
    "fm_test_sha256 did not say why it failed"
  rc=0
  out=$(fm_test_sha256 "$TMP_ROOT/absent" 2>/dev/null) || rc=$?
  if [ "$rc" -eq 0 ] || [ -n "$out" ]; then
    fail "fm_test_sha256 on a missing file: rc=$rc out='$out'"
  fi
  pass "fm_test_sha256 fails with nothing on stdout when no digest can be taken"
}

test_sha256_uses_sha256sum_when_shasum_is_absent
test_sha256_falls_back_to_shasum_when_sha256sum_is_absent
test_sha256_fails_loudly_with_neither_tool
