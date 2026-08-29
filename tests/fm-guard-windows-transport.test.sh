#!/usr/bin/env bash
# tests/fm-guard-windows-transport.test.sh - unit tests for the two places the
# PreToolUse seatbelt transports have to know they are running on a Windows
# userland: the jq field read, whose native jq.exe writes every interior LF as
# CRLF, and the watcher-arm policy invocation, whose `/`-leading arguments MSYS
# rewrites before a native node.exe ever sees them.
#
# Both defects are FAIL-OPEN in guards whose whole job is to refuse a command.
# A corrupted command stops looking like a watcher command, and a --home that
# arrives as `C:/fm` while the command words stay `/c/fm` stops the blessed
# x-mode `source` from being recognized. So every case here is keyed on a FAKED
# userland - $OSTYPE, plus a jq, a cygpath and a node on PATH that model the
# Windows tools' exact behavior - and both branches run on Linux, macOS and
# Windows alike. Nothing here needs a Windows host.
#
# shellcheck disable=SC2016 # Every single-quoted printf format below is the
# SOURCE of a fake tool: the $@ and $2 inside must reach that script's own
# positional parameters rather than expand in this shell.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-guard-windows-transport)

LIB="$ROOT/bin/fm-hook-host-lib.sh"
CHECK="$ROOT/bin/fm-arm-pretool-check.sh"
US=$'\x1f'

# --- fm_hook_payload_string: undoing a native jq's CRLF ---------------------

# A jq that ignores its filter and prints <emit-file> verbatim, so a case can
# plant the exact bytes a text-mode stdout would have produced.
make_jq() {  # <dir> <emit-file> -> echoes fakebin dir
  local fb="$1/fakebin" emit=$2
  mkdir -p "$fb"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'cat %s\n' "$(printf '%q' "$emit")"
  } > "$fb/jq"
  chmod +x "$fb/jq"
  printf '%s\n' "$fb"
}

# read_field <fakebin> <ostype>: source the lib in a child shell with a faked
# userland and echo what fm_hook_payload_string handed back, byte for byte.
read_field() {
  local fb=$1 ostype=$2
  OSTYPE="$ostype" PATH="$fb:$PATH" bash -c '
    set -u
    . "$1"
    printf "%s" "$(fm_hook_payload_string "{}" ".ignored")"
  ' bash "$LIB"
}

# read_field_status <fakebin> <ostype>: the status a caller would fail open on.
read_field_status() {
  local fb=$1 ostype=$2
  OSTYPE="$ostype" PATH="$fb:$PATH" bash -c '
    set -u
    . "$1"
    fm_hook_payload_string "{}" ".ignored" >/dev/null
  ' bash "$LIB"
  printf '%s\n' "$?"
}

# case_dir <name> <true-bytes> <emitted-bytes>: build a case whose fake jq emits
# <emitted-bytes> and whose correct answer is <true-bytes>; echoes the fakebin.
make_case() {  # <name> <printf-format-for-true> <printf-format-for-emitted>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  # shellcheck disable=SC2059 # the formats are literals owned by each case.
  printf "$2" > "$dir/true"
  # shellcheck disable=SC2059
  printf "$3" > "$dir/emit"
  make_jq "$dir" "$dir/emit"
}

test_msys_undoes_the_crlf_a_native_jq_writes() {
  local fb out
  # A `\` + newline line continuation, the shape the classifier joins back into
  # `bin/fm-watch-arm.sh` before it recognizes the watcher.
  fb=$(make_case crlf 'bin/fm-watc\\\nh-arm.sh &' 'bin/fm-watc\\\r\nh-arm.sh &\r\n')
  out=$(read_field "$fb" msys)
  [ "$out" = "$(cat "$TMP_ROOT/crlf/true")" ] \
    || fail "MSYS read must hand back the value jq was given: $(printf '%s' "$out" | od -c | head -2)"
  case "$out" in
    *$'\r'*) fail "MSYS read left a CR in a multi-line value" ;;
  esac
  pass "payload read: a native jq's CRLF is undone, so a line continuation survives"
}

test_msys_keeps_a_lone_cr() {
  local fb out
  fb=$(make_case lonecr 'echo a\rb\nfm-watch' 'echo a\rb\r\nfm-watch\r\n')
  out=$(read_field "$fb" msys)
  [ "$out" = "$(cat "$TMP_ROOT/lonecr/true")" ] \
    || fail "the undo must not touch a CR that is not part of a CRLF"
  pass "payload read: a lone CR inside the command is preserved"
}

test_msys_keeps_an_original_crlf() {
  local fb out
  # The command's OWN line ending is CRLF, so text mode wrote CR CR LF; undoing
  # one CRLF has to land back on exactly CR LF.
  fb=$(make_case crcrlf 'echo a\r\nfm-watch' 'echo a\r\r\nfm-watch\r\n')
  out=$(read_field "$fb" msys)
  [ "$out" = "$(cat "$TMP_ROOT/crcrlf/true")" ] \
    || fail "a command whose own line ending is CRLF must survive the undo unchanged"
  pass "payload read: an original CRLF in the command is not eaten"
}

test_posix_read_is_byte_identical() {
  local fb out
  # The same CRLF-writing jq on a POSIX userland: the branch must not run, so
  # the caller sees jq's bytes untouched. This is what proves macOS and Linux
  # are unaffected by the correction.
  fb=$(make_case posix 'echo a\nfm-watch' 'echo a\r\nfm-watch\r\n')
  out=$(read_field "$fb" linux-gnu)
  case "$out" in
    *$'\r'$'\n'*) : ;;
    *) fail "a POSIX host must pass jq's bytes through untouched: $(printf '%s' "$out" | od -c | head -2)" ;;
  esac
  pass "payload read: a POSIX host runs the same jq call it always ran"
}

test_jq_failure_keeps_its_status_on_both_branches() {
  local fb rc
  fb="$TMP_ROOT/failjq/fakebin"
  mkdir -p "$fb"
  printf '#!/usr/bin/env bash\nexit 3\n' > "$fb/jq"
  chmod +x "$fb/jq"
  rc=$(read_field_status "$fb" msys)
  [ "$rc" != 0 ] || fail "MSYS branch must report a failing jq so the caller can fail open"
  rc=$(read_field_status "$fb" linux-gnu)
  [ "$rc" != 0 ] || fail "POSIX branch must report a failing jq so the caller can fail open"
  pass "payload read: a failing jq keeps its non-zero status on both branches"
}

# --- the arm transport's policy invocation ---------------------------------

# A checkout-shaped fixture whose bin/ holds the real transport, a policy file
# node never actually reads, and a node that records how it was called.
make_transport_fixture() {  # <dir> -> echoes dir
  local dir=$1
  mkdir -p "$dir/bin" "$dir/fakebin"
  # The fakebin is the child's WHOLE PATH, so a case that wants cygpath absent
  # really gets it - on a Windows host the real one is otherwise still there.
  fm_fakebin_link "$dir/fakebin" bash sh dirname sed tr
  cp "$CHECK" "$dir/bin/fm-arm-pretool-check.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  : > "$dir/bin/fm-arm-command-policy.mjs"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -u\n'
    printf '{\n'
    printf '  printf "ARGV"\n'
    printf '  for a in "$@"; do printf "\\037%%s" "$a"; done\n'
    printf '  printf "\\n"\n'
    printf '  printf "EXCL=%%s\\n" "${MSYS2_ARG_CONV_EXCL-<unset>}"\n'
    printf '} > %s\n' "$(printf '%q' "$dir/node.log")"
    printf 'printf "allow\\n"\n'
  } > "$dir/fakebin/node"
  chmod +x "$dir/fakebin/node"
  printf '%s\n' "$dir"
}

# A cygpath whose body the case chooses, so the three ways it can let the
# transport down - a good answer, a blank answer, a non-zero exit - are all
# reachable. The default only has to prove it was consulted and its answer used.
make_cygpath() {  # <dir> [body]
  local dir=$1 body=${2:-'printf "WIN32:%s\n" "$2"'}
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$body"
  } > "$dir/fakebin/cygpath"
  chmod +x "$dir/fakebin/cygpath"
}

run_transport() {  # <dir> <ostype> [command]
  local dir=$1 ostype=$2 cmd=${3:-'bin/fm-watch-arm.sh &'}
  rm -f "$dir/node.log"
  OSTYPE="$ostype" PATH="$dir/fakebin" \
    "$dir/bin/fm-arm-pretool-check.sh" --command "$cmd" >/dev/null 2>&1
  [ -f "$dir/node.log" ] || fail "the transport never reached node (ostype $ostype)"
}

test_msys_converts_the_policy_path_and_stops_argument_conversion() {
  local dir argv
  dir=$(make_transport_fixture "$TMP_ROOT/tx-msys")
  make_cygpath "$dir"
  run_transport "$dir" msys
  argv=$(sed -n 1p "$dir/node.log")
  assert_contains "$argv" "${US}WIN32:$dir/bin/fm-arm-command-policy.mjs" \
    "node must be handed the policy path cygpath -w produced, not the POSIX one"
  assert_contains "$argv" "${US}--root${US}$dir${US}" \
    "--root must reach node in the POSIX spelling the command words use"
  assert_contains "$(sed -n 2p "$dir/node.log")" "EXCL=*" \
    "MSYS argument conversion must be off for the whole call"
  pass "arm transport: MSYS converts only the policy path and disables argument conversion"
}

test_posix_call_is_unchanged() {
  local dir argv expected
  dir=$(make_transport_fixture "$TMP_ROOT/tx-posix")
  make_cygpath "$dir"
  run_transport "$dir" linux-gnu
  argv=$(sed -n 1p "$dir/node.log")
  expected="ARGV${US}$dir/bin/fm-arm-command-policy.mjs${US}--command${US}bin/fm-watch-arm.sh &${US}--root${US}$dir${US}--home${US}$dir"
  [ "$argv" = "$expected" ] \
    || fail "a POSIX host must make the untouched call, got: $argv"
  [ "$(sed -n 2p "$dir/node.log")" = "EXCL=<unset>" ] \
    || fail "a POSIX host must not put MSYS2_ARG_CONV_EXCL in node's environment"
  pass "arm transport: a POSIX host's node invocation is byte-identical"
}

test_msys_without_cygpath_falls_back_to_the_plain_call() {
  local dir argv
  dir=$(make_transport_fixture "$TMP_ROOT/tx-nocygpath")
  # No cygpath at all: there is no safe spelling for the policy path, so the
  # call must stay exactly what it is rather than become unrunnable.
  run_transport "$dir" msys
  argv=$(sed -n 1p "$dir/node.log")
  assert_contains "$argv" "${US}$dir/bin/fm-arm-command-policy.mjs${US}" \
    "without cygpath the policy path must stay POSIX"
  assert_not_contains "$argv" "WIN32:" "without cygpath nothing may be converted"
  [ "$(sed -n 2p "$dir/node.log")" = "EXCL=<unset>" ] \
    || fail "conversion must not be disabled when the policy path could not be converted"
  pass "arm transport: a Windows userland with no cygpath keeps the plain call"
}

test_msys_with_a_blank_cygpath_answer_falls_back() {
  local dir argv
  dir=$(make_transport_fixture "$TMP_ROOT/tx-blankcygpath")
  # cygpath succeeds but says nothing. Taking that answer would hand node an
  # empty script path with conversion disabled, i.e. no policy and a guard that
  # allows everything, so the empty answer has to be refused like a failure.
  make_cygpath "$dir" 'printf "\n"'
  run_transport "$dir" msys
  argv=$(sed -n 1p "$dir/node.log")
  assert_contains "$argv" "${US}$dir/bin/fm-arm-command-policy.mjs${US}" \
    "a blank cygpath answer must leave the POSIX policy path in place"
  [ "$(sed -n 2p "$dir/node.log")" = "EXCL=<unset>" ] \
    || fail "conversion must not be disabled when cygpath answered nothing"
  pass "arm transport: a blank cygpath answer is refused like a failure"
}

test_msys_with_a_failing_cygpath_falls_back() {
  local dir argv
  dir=$(make_transport_fixture "$TMP_ROOT/tx-failcygpath")
  make_cygpath "$dir" 'exit 4'
  run_transport "$dir" msys
  argv=$(sed -n 1p "$dir/node.log")
  assert_contains "$argv" "${US}$dir/bin/fm-arm-command-policy.mjs${US}" \
    "a failing cygpath must leave the POSIX policy path in place"
  [ "$(sed -n 2p "$dir/node.log")" = "EXCL=<unset>" ] \
    || fail "conversion must not be disabled when cygpath failed"
  pass "arm transport: a failing cygpath keeps the plain call"
}

test_msys_hands_node_the_exact_command_bytes() {
  local dir argv
  dir=$(make_transport_fixture "$TMP_ROOT/tx-cmd")
  make_cygpath "$dir"
  run_transport "$dir" msys '/opt/fm/bin/fm-watch-arm.sh'
  argv=$(sed -n 1p "$dir/node.log")
  assert_contains "$argv" "${US}--command${US}/opt/fm/bin/fm-watch-arm.sh${US}" \
    "the classifier must be shown the exact bytes the shell would run"
  pass "arm transport: a single bare path command reaches the classifier unrewritten"
}

# --- the policy's own path comparisons -------------------------------------

# --- the fixture helper this suite leans on --------------------------------

test_fakebin_link_skips_what_it_cannot_place() {
  local fb
  fb="$TMP_ROOT/linkskip/fakebin"
  mkdir -p "$fb"
  fm_fakebin_link "$fb" definitely-not-a-tool-on-this-host
  assert_absent "$fb/definitely-not-a-tool-on-this-host" \
    "an unresolvable tool must be skipped, not linked to nothing"
  # A shell builtin resolves to a bare name, not a path; linking or wrapping
  # that would put a broken entry on the child's whole PATH.
  if [ "$(command -v printf)" = printf ]; then
    fm_fakebin_link "$fb" printf
    assert_absent "$fb/printf" "a builtin must be skipped, not placed as a path"
  fi
  fm_fakebin_link "$fb" bash
  [ -e "$fb/bash" ] || fail "a real tool must still be placed"
  pass "fakebin helper: places real tools and skips what has no path"
}

# --- the policy's own path comparisons -------------------------------------

# NOTE: this is the one case in this file that CANNOT be faked onto a POSIX
# host. Node keys its `path` export off process.platform, not off anything in
# the environment, so on Linux and macOS the default export already IS
# path.posix and reverting the import in bin/fm-arm-command-policy.mjs cannot
# fail here. Only a Windows leg catches that regression, which is one more
# reason slice 5's CI lane exists.
test_policy_compares_with_posix_separators() {
  local dir rc
  if ! command -v node >/dev/null 2>&1; then
    pass "policy path comparison: skipped, no node on PATH"
    return
  fi
  # Driven through the real transport with the real policy and the real node,
  # because these are the two comparisons a platform-default `path` breaks on
  # Windows: normalize("bin/fm-watch-arm.sh") becomes "bin\\fm-watch-arm.sh" and
  # matches no protected script, so the whole watcher seatbelt ALLOWS; and an
  # absolute x-mode source stops matching --home, so a blessed arm is DENIED.
  dir="$TMP_ROOT/tx-real"
  mkdir -p "$dir/bin"
  cp "$CHECK" "$dir/bin/fm-arm-pretool-check.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/fm-arm-command-policy.mjs"
  FM_HOME='' "$dir/bin/fm-arm-pretool-check.sh" --command 'bin/fm-watch-arm.sh &' >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "a repo-relative protected script must stay protected"
  FM_HOME='' "$dir/bin/fm-arm-pretool-check.sh" \
    --command "source '$dir/config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds 180" >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "the blessed absolute x-mode source must still be recognized"
  pass "policy path comparison: POSIX separators on every host"
}

test_msys_undoes_the_crlf_a_native_jq_writes
test_msys_keeps_a_lone_cr
test_msys_keeps_an_original_crlf
test_posix_read_is_byte_identical
test_jq_failure_keeps_its_status_on_both_branches
test_msys_converts_the_policy_path_and_stops_argument_conversion
test_posix_call_is_unchanged
test_msys_without_cygpath_falls_back_to_the_plain_call
test_msys_with_a_blank_cygpath_answer_falls_back
test_msys_with_a_failing_cygpath_falls_back
test_msys_hands_node_the_exact_command_bytes
test_fakebin_link_skips_what_it_cannot_place
test_policy_compares_with_posix_separators
