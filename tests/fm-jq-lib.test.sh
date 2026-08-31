#!/usr/bin/env bash
# tests/fm-jq-lib.test.sh - unit tests for bin/fm-jq-lib.sh, the single owner of
# multi-row `jq -r` reads whose records go back into a shell loop.
#
# The subject is BYTES. A native jq.exe opens stdout in text mode and ends every
# record CR LF; command substitution drops only the final terminator, so every
# record but the last reaches the caller with a trailing CR. fm_jq_rows undoes
# exactly that terminator on a Windows userland and is a byte-identical
# passthrough everywhere else.
#
# Every case forces the branch with OSTYPE inside the invoking shell (bash only
# sets OSTYPE when it is not already set, but a snippet assignment is what the
# sibling suite tests/fm-backend-herdr-windows.test.sh already uses and it keeps
# the fake toolchain's own children on the host's real value), so both branches
# run on every platform.
#
# shellcheck disable=SC2016 # Every `jqlib` snippet is source for a CHILD shell:
# the $1 and \$want inside it belong to that shell, which is the only way to
# hand a jq filter through without the parent expanding it first.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Every case wraps a REAL jq: the library's contract is about what it does to
# jq's own byte stream, and a scripted answer cannot prove a filter still means
# what it meant.
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-jq-lib-tests)

# jqlib <fakebin|""> <code> [args...]: run one snippet with bin/fm-jq-lib.sh
# sourced, optionally with <fakebin> at the front of PATH. Always under `set -u`,
# because every script that sources this library runs that way and an unset
# local is a crash there, not a falsy value.
jqlib() {
  local fb=$1 code=$2
  shift 2
  if [ -n "$fb" ]; then
    PATH="$fb:$PATH" bash -c "set -u; . \"\$0/bin/fm-jq-lib.sh\"; $code" "$ROOT" "$@"
  else
    bash -c "set -u; . \"\$0/bin/fm-jq-lib.sh\"; $code" "$ROOT" "$@"
  fi
}

# A `jq` that behaves like a native jq.exe: every record terminated CR LF.
#
# On a host whose jq ALREADY writes that way the real binary IS the fake, so the
# cases assert against the genuine article rather than a model of it. Anywhere
# else the real binary is wrapped and each LF terminator is widened to CR LF,
# which is exactly what the platform's text-mode stdout does.
#
# The wrapper WIDENS and never strips. A record whose value itself ends in CR has
# to leave the fake as CR CR LF, because that ambiguity - is this CR data, or half
# a terminator - is the whole reason fm_jq_rows captures through a sentinel
# instead of trimming. It widens with bash's own `read` rather than awk or sed:
# the MinGW gawk on the port machine opens stdin in text mode and eats the very
# byte this fake exists to produce.
make_text_mode_jq() {  # <dir> -> echoes fakebin dir
  local fb real bytes
  fb=$(fm_fakebin "$1")
  real=$(command -v jq)
  # `x` plus its terminator: 2 bytes under a POSIX jq, 3 under a text-mode one.
  bytes=$(printf '%s' '{}' | "$real" -r '"x"' | wc -c | tr -d ' ')
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -u\n'
    printf 'real=%q\n' "$real"
    if [ "$bytes" = 3 ]; then
      cat <<'SH'
exec "$real" "$@"
SH
    else
      cat <<'SH'
"$real" "$@" | while IFS= read -r line || [ -n "$line" ]; do printf '%s\r\n' "$line"; done
exit "${PIPESTATUS[0]}"
SH
    fi
  } > "$fb/jq"
  chmod +x "$fb/jq"
  printf '%s\n' "$fb"
}

# Every assertion below reads stdout with CR and LF made visible (`tr '\r\n'
# 'RN'`), because the bytes ARE the subject and a terminal renders a stray CR as
# nothing at all - which is how this defect survived a passing-looking output for
# as long as it did.

test_posix_branch_passes_every_byte_through() {
  local fb out
  fb=$(make_text_mode_jq "$TMP_ROOT/posix-bytes")
  out=$( jqlib "$fb" 'OSTYPE=linux-gnu; fm_jq_rows "$1" ".x[]" | tr "\r\n" "RN"' \
    '{"x":["p","q"]}' )
  [ "$out" = "pRNqRN" ] ||
    fail "the POSIX branch must hand back jq's bytes untouched, got '$out'"
  pass "fm_jq_rows: a POSIX host still gets jq's own bytes, CRs included"
}

test_msys_branch_removes_the_record_terminator_cr() {
  local fb out
  fb=$(make_text_mode_jq "$TMP_ROOT/msys-strip")
  out=$( jqlib "$fb" 'OSTYPE=msys; fm_jq_rows "$1" ".x[]" | tr "\r\n" "RN"' \
    '{"x":["p","q"]}' )
  [ "$out" = "pNqN" ] ||
    fail "a text-mode jq's CR must not survive into a multi-row read, got '$out'"
  pass "fm_jq_rows: a Windows userland gets LF-terminated rows out of a text-mode jq"
}

test_msys_branch_keeps_a_cr_inside_a_value() {
  local fb out
  fb=$(make_text_mode_jq "$TMP_ROOT/msys-interior")
  out=$( jqlib "$fb" 'OSTYPE=msys; fm_jq_rows "$1" ".x[]" | tr "\r\n" "RN"' \
    '{"x":["a\rb","c"]}' )
  [ "$out" = "aRbNcN" ] ||
    fail "only the CR jq added before its own LF may be removed, got '$out'"
  pass "fm_jq_rows: a CR inside a value survives - the undo is exact, not a blanket strip"
}

test_msys_branch_keeps_a_cr_that_ends_a_value() {
  local fb msys posix
  fb=$(make_text_mode_jq "$TMP_ROOT/msys-terminal-cr")
  # A value that legitimately ENDS in CR. A text-mode jq renders it `1 CR CR LF`,
  # which is the same byte sequence a POSIX jq would produce for the value `1 CR
  # CR`. The Windows branch must remove the terminator's CR and nothing else - a
  # funnel that guessed the trailing CR was half a terminator would answer `1`,
  # silently rewriting data on one platform only. The POSIX branch, handed the
  # same bytes, must not touch them at all.
  msys=$( jqlib "$fb" 'OSTYPE=msys; fm_jq_rows "$1" ".x[]" | tr "\r\n" "RN"' \
    '{"x":["1\r"]}' )
  posix=$( jqlib "$fb" 'OSTYPE=linux-gnu; fm_jq_rows "$1" ".x[]" | tr "\r\n" "RN"' \
    '{"x":["1\r"]}' )
  [ "$msys" = "1RN" ] && [ "$posix" = "1RRN" ] ||
    fail "the Windows branch must undo the text-mode terminator and nothing else, got msys='$msys' posix='$posix'"
  pass "fm_jq_rows: a CR that is the last byte of a VALUE survives - the undo is exact, not a guess"
}

test_empty_answer_emits_nothing_and_succeeds() {
  local fb posix msys posix_status msys_status
  fb=$(make_text_mode_jq "$TMP_ROOT/empty")
  posix=$( jqlib "$fb" 'OSTYPE=linux-gnu; fm_jq_rows "$1" ".x[]" | wc -c | tr -d " "' \
    '{"x":[]}' )
  msys=$( jqlib "$fb" 'OSTYPE=msys; fm_jq_rows "$1" ".x[]" | wc -c | tr -d " "' \
    '{"x":[]}' )
  [ "$posix" = 0 ] && [ "$msys" = 0 ] ||
    fail "an empty answer must stay empty on both branches (a blank line is one loop iteration to every \`while read\` caller), got posix=$posix msys=$msys"
  # And it must SUCCEED. An empty row set is the ordinary case for callers that
  # ask "which of these exist"; a status the caller treats as fatal would turn
  # every such read into a refusal.
  jqlib "$fb" 'OSTYPE=linux-gnu; fm_jq_rows "$1" ".x[]"' '{"x":[]}' >/dev/null 2>&1
  posix_status=$?
  jqlib "$fb" 'OSTYPE=msys; fm_jq_rows "$1" ".x[]"' '{"x":[]}' >/dev/null 2>&1
  msys_status=$?
  [ "$posix_status" = 0 ] && [ "$msys_status" = 0 ] ||
    fail "an empty answer is a success, not a failure; got posix=$posix_status msys=$msys_status"
  pass "fm_jq_rows: an empty answer emits zero bytes and exits 0 on both branches"
}

test_jq_exit_status_reaches_the_caller() {
  local fb expected posix msys posix_out msys_out
  fb=$(make_text_mode_jq "$TMP_ROOT/status")
  # jq's own status for this failure, taken from the same binary rather than
  # hard-coded, so a jq that renumbers its exit codes does not fail this case.
  printf '%s' '{}' | "$fb/jq" -r '.x[' >/dev/null 2>&1
  expected=$?
  [ "$expected" != 0 ] || fail "the failing-jq case needs a filter jq actually rejects"
  posix_out=$( jqlib "$fb" 'OSTYPE=linux-gnu; fm_jq_rows "$1" ".x["' '{}' 2>/dev/null )
  posix=$?
  msys_out=$( jqlib "$fb" 'OSTYPE=msys; fm_jq_rows "$1" ".x["' '{}' 2>/dev/null )
  msys=$?
  [ "$posix" = "$expected" ] && [ "$msys" = "$expected" ] ||
    fail "jq's own exit status is what callers refuse on; expected $expected, got posix=$posix msys=$msys"
  [ -z "$posix_out" ] && [ -z "$msys_out" ] ||
    fail "a failing jq must print no rows; got posix='$posix_out' msys='$msys_out'"
  pass "fm_jq_rows: a failing jq's status reaches the caller on both branches, with no rows"
}

test_extra_jq_arguments_are_forwarded() {
  local fb posix msys
  fb=$(make_text_mode_jq "$TMP_ROOT/args")
  posix=$( jqlib "$fb" 'OSTYPE=linux-gnu; fm_jq_rows "$1" --arg want beta ".a[] | select(.l == \$want) | .l" | tr "\r\n" "RN"' \
    '{"a":[{"l":"alpha"},{"l":"beta"}]}' )
  msys=$( jqlib "$fb" 'OSTYPE=msys; fm_jq_rows "$1" --arg want beta ".a[] | select(.l == \$want) | .l" | tr "\r\n" "RN"' \
    '{"a":[{"l":"alpha"},{"l":"beta"}]}' )
  [ "$posix" = "betaRN" ] ||
    fail "every argument after the JSON must reach jq unchanged, got '$posix'"
  [ "$msys" = "betaN" ] ||
    fail "the Windows branch may only change what comes BACK from jq, never what goes in, got '$msys'"
  pass "fm_jq_rows: arguments past the JSON reach jq unchanged on both branches"
}

test_posix_branch_passes_every_byte_through
test_msys_branch_removes_the_record_terminator_cr
test_msys_branch_keeps_a_cr_inside_a_value
test_msys_branch_keeps_a_cr_that_ends_a_value
test_empty_answer_emits_nothing_and_succeeds
test_jq_exit_status_reaches_the_caller
test_extra_jq_arguments_are_forwarded
