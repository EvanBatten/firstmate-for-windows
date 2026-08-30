#!/usr/bin/env bash
# tests/fm-backend-herdr-windows.test.sh - unit tests for the three places the
# herdr adapter has to know it is talking to a Windows herdr: the socket path
# it compares identities with, the MSYS argument conversion that rewrites its
# arguments before herdr ever sees them, and the presentation lock namespace
# whose mode a `noacl` mount cannot carry (docs/windows/plan.html findings 5,
# 8, 9 and 12).
#
# Every case is keyed on a faked capability - a `cygpath` on PATH, a `herdr`
# whose first two bytes say PE image, a `stat` that answers like a mode-less
# filesystem - so the Windows branches run on Linux and macOS CI too, and the
# POSIX branches run on Windows. Nothing here needs a herdr binary.
#
# shellcheck disable=SC2016 # Every `adapter` snippet is source for a CHILD
# shell: the $1.. inside it are that shell's positional arguments, which is the
# only way to hand a backslash-bearing Win32 path through unmangled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Herdr injects a pane identity into every process it manages, so a suite run
# from inside the developer's own herdr pane inherits a launcher these fakes
# never model and the adapter goes looking for its socket. Dropped here rather
# than by sourcing tests/herdr-test-safety.sh, since nothing in this file goes
# anywhere near a real herdr.
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION

TMP_ROOT=$(fm_test_tmproot fm-backend-herdr-windows-tests)

US=$'\x1f'

# adapter <fakebin|""> <code> [args...]: run one snippet with
# bin/backends/herdr.sh sourced, optionally with <fakebin> at the front of PATH.
# Always under `set -u`, because the scripts that source this adapter run that
# way and an unset local is a crash there, not a falsy value.
adapter() {
  local fb=$1 code=$2
  shift 2
  if [ -n "$fb" ]; then
    PATH="$fb:$PATH" bash -c "set -u; . \"\$0/bin/backends/herdr.sh\"; $code" "$ROOT" "$@"
  else
    bash -c "set -u; . \"\$0/bin/backends/herdr.sh\"; $code" "$ROOT" "$@"
  fi
}

# A cygpath that models the real one for the exact shapes these cases use:
# -u folds C:\a\b (either drive case, either separator) to /c/a/b, and -w folds
# a /<drive>/... path back to a backslash-separated Win32 path.
make_cygpath() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/cygpath" <<'SH'
#!/usr/bin/env bash
set -u
mode=$1; path=$2
case "$mode" in
  -u)
    drive=$(printf '%s' "${path%%:*}" | tr '[:upper:]' '[:lower:]')
    rest=${path#*:}
    printf '/%s%s\n' "$drive" "$(printf '%s' "$rest" | tr '\\' '/')"
    ;;
  -w)
    case "$path" in
      /?/*)
        drive=$(printf '%s' "$path" | cut -c2 | tr '[:lower:]' '[:upper:]')
        printf '%s:%s\n' "$drive" "$(printf '%s' "$path" | cut -c3- | tr '/' '\\')"
        ;;
      *) printf 'C:%s\n' "$(printf '%s' "$path" | tr '/' '\\')" ;;
    esac
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fb/cygpath"
  printf '%s\n' "$fb"
}

# --- fm_backend_herdr_canonical_socket_path ---------------------------------

test_canonical_socket_path_posix_is_unchanged() {
  local out
  out=$(adapter "" 'fm_backend_herdr_canonical_socket_path /tmp/no-such-dir-here/herdr.sock')
  [ "$out" = "/tmp/no-such-dir-here/herdr.sock" ] ||
    fail "a POSIX socket path with an unresolvable directory must still be returned literally, got '$out'"
  pass "fm_backend_herdr_canonical_socket_path: a POSIX absolute path is still returned unchanged"
}

test_canonical_socket_path_refuses_relative_and_empty() {
  adapter "" 'fm_backend_herdr_canonical_socket_path herdr.sock' >/dev/null 2>&1 &&
    fail "a relative socket path must still be refused"
  adapter "" 'fm_backend_herdr_canonical_socket_path ""' >/dev/null 2>&1 &&
    fail "an empty socket path must still be refused"
  adapter "" 'fm_backend_herdr_canonical_socket_path CC:/x/herdr.sock' >/dev/null 2>&1 &&
    fail "a path that only looks drive-shaped must be refused"
  pass "fm_backend_herdr_canonical_socket_path: relative, empty, and near-miss drive paths are still refused"
}

test_canonical_socket_path_folds_a_win32_path() {
  local fb out
  fb=$(make_cygpath "$TMP_ROOT/canon-win")
  out=$(adapter "$fb" 'fm_backend_herdr_canonical_socket_path "$1"' 'C:\Users\ebatt\AppData\Roaming\herdr\herdr.sock')
  [ "$out" = "/c/Users/ebatt/AppData/Roaming/herdr/herdr.sock" ] ||
    fail "a Win32 socket path must be folded through cygpath -u, got '$out'"
  out=$(adapter "$fb" 'fm_backend_herdr_canonical_socket_path "$1"' 'd:/no-such-dir-here/herdr.sock')
  [ "$out" = "/d/no-such-dir-here/herdr.sock" ] ||
    fail "a lowercase, forward-slash drive path must fold too, got '$out'"
  pass "fm_backend_herdr_canonical_socket_path: a Windows drive path folds into this shell's own namespace"
}

test_canonical_socket_path_win32_needs_cygpath() {
  adapter "" 'PATH=/nonexistent; fm_backend_herdr_canonical_socket_path "$1"' 'C:\Users\ebatt\herdr.sock' >/dev/null 2>&1 &&
    fail "a shell that cannot read a Win32 path must refuse it, exactly as it did before"
  pass "fm_backend_herdr_canonical_socket_path: a Win32 path with no cygpath is still refused, so no POSIX host changes behavior"
}

# --- fm_backend_herdr_socket_paths_equal ------------------------------------

test_socket_paths_equal_is_byte_exact_without_cygpath() {
  adapter "" 'PATH=/nonexistent; fm_backend_herdr_socket_paths_equal /tmp/a.sock /tmp/a.sock' ||
    fail "identical paths must compare equal"
  adapter "" 'PATH=/nonexistent; fm_backend_herdr_socket_paths_equal /tmp/a.sock /tmp/b.sock' &&
    fail "different paths must not compare equal"
  adapter "" 'PATH=/nonexistent; fm_backend_herdr_socket_paths_equal /tmp/A.sock /tmp/a.sock' &&
    fail "on a case-sensitive filesystem two case spellings are two different sockets"
  pass "fm_backend_herdr_socket_paths_equal: byte-exact, case-sensitive comparison where there is no Windows userland"
}

test_socket_paths_equal_folds_case_on_a_windows_userland() {
  local fb
  fb=$(make_cygpath "$TMP_ROOT/equal-win")
  adapter "$fb" 'fm_backend_herdr_socket_paths_equal /c/Users/Ebatt/herdr.sock /c/users/ebatt/herdr.sock' ||
    fail "on Windows two case spellings of one socket must compare equal"
  adapter "$fb" 'fm_backend_herdr_socket_paths_equal /c/Users/ebatt/herdr.sock /c/Users/ebatt/other.sock' &&
    fail "case folding must not make two different sockets equal"
  pass "fm_backend_herdr_socket_paths_equal: a Windows userland compares case-insensitively, and only that"
}

# --- fm_backend_herdr_win32_cli (the capability probe) ----------------------

test_win32_cli_detects_a_native_binary_next_to_cygpath() {
  local fb
  fb=$(make_cygpath "$TMP_ROOT/probe-native")
  printf 'MZ\220\0\3\0' > "$fb/herdr"
  chmod +x "$fb/herdr"
  adapter "$fb" 'fm_backend_herdr_win32_cli' ||
    fail "a PE-image herdr reached from a cygpath userland is the argument-conversion case"
  pass "fm_backend_herdr_win32_cli: a native herdr next to cygpath selects the conversion branch"
}

test_win32_cli_leaves_a_shell_script_fake_alone() {
  local fb
  fb=$(make_cygpath "$TMP_ROOT/probe-script")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/herdr"
  chmod +x "$fb/herdr"
  adapter "$fb" 'fm_backend_herdr_win32_cli' &&
    fail "a shell-script herdr is run by the MSYS userland itself, which converts nothing"
  pass "fm_backend_herdr_win32_cli: a shell-script herdr (every unit test's fake) keeps the plain branch, on Windows too"
}

test_win32_cli_needs_cygpath() {
  local fb="$TMP_ROOT/probe-nocygpath/fakebin"
  mkdir -p "$fb"
  printf 'MZ\220\0\3\0' > "$fb/herdr"
  chmod +x "$fb/herdr"
  adapter "" 'PATH=$1; fm_backend_herdr_win32_cli' "$fb" &&
    fail "without cygpath there is no conversion to undo and no way to convert --cwd"
  pass "fm_backend_herdr_win32_cli: no cygpath means no conversion branch"
}

test_win32_cli_survives_an_unreadable_herdr() {
  local fb out resolved
  fb=$(make_cygpath "$TMP_ROOT/probe-empty")
  : > "$fb/herdr"
  chmod +x "$fb/herdr"
  # MSYS decides executability from an extension or a magic header, never from
  # the x bit, so an empty file is simply not on PATH there and the case has
  # nothing to probe.
  resolved=$(adapter "$fb" 'command -v herdr')
  case "$resolved" in
    "$fb"/*) ;;
    *)
      pass "skip: this filesystem will not treat an empty file as an executable ($resolved)"
      return 0
      ;;
  esac
  out=$(adapter "$fb" 'fm_backend_herdr_win32_cli; echo "rc=$?"' 2>&1)
  [ "$out" = "rc=1" ] ||
    fail "a herdr whose magic cannot be read must answer no, not crash under set -u, got '$out'"
  pass "fm_backend_herdr_win32_cli: a herdr whose first bytes cannot be read answers no under set -u"
}

test_win32_cli_override_forces_the_answer() {
  adapter "" 'FM_BACKEND_HERDR_WIN32_CLI=1 fm_backend_herdr_win32_cli' ||
    fail "FM_BACKEND_HERDR_WIN32_CLI=1 must force the conversion branch on"
  adapter "" 'FM_BACKEND_HERDR_WIN32_CLI=0 fm_backend_herdr_win32_cli' &&
    fail "FM_BACKEND_HERDR_WIN32_CLI=0 must force the conversion branch off"
  pass "fm_backend_herdr_win32_cli: the test seam forces both answers"
}

# --- fm_backend_herdr_cli under MSYS argument conversion --------------------

# A `herdr` that records MSYS2_ARG_CONV_EXCL and every argument it was handed,
# unit-separated, one line per call.
make_logging_herdr() {  # <fakebin>
  cat > "$1/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'EXCL=%s' "${MSYS2_ARG_CONV_EXCL:-<unset>}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "${FM_HERDR_LOG:?}"
exit 0
SH
  chmod +x "$1/herdr"
}

# No FM_BACKEND_HERDR_WIN32_CLI here on purpose: this is the probe deciding for
# itself, against a shell-script fake and a cygpath that exists. It is the case
# that protects every OTHER herdr test's byte-exact argument assertions on
# Windows, so it must run through the real routing, not the seam.
test_cli_plain_branch_is_untouched() {
  local fb log
  fb=$(make_cygpath "$TMP_ROOT/cli-plain"); log="$TMP_ROOT/cli-plain/log"; : > "$log"
  make_logging_herdr "$fb"
  FM_HERDR_LOG="$log" adapter "$fb" \
    'fm_backend_herdr_cli fmtest tab create --cwd /tmp/proj --label fm-x'
  assert_contains "$(cat "$log")" \
    "EXCL=<unset>${US}tab${US}create${US}--cwd${US}/tmp/proj${US}--label${US}fm-x${US}--session${US}fmtest" \
    "the non-Windows call must reach herdr byte for byte as it always has"
  pass "fm_backend_herdr_cli: a shell-script herdr routes itself to the plain branch, arguments unchanged"
}

test_cli_win32_branch_converts_only_cwd() {
  local fb log
  fb=$(make_cygpath "$TMP_ROOT/cli-win32"); log="$TMP_ROOT/cli-win32/log"; : > "$log"
  make_logging_herdr "$fb"
  FM_HERDR_LOG="$log" adapter "$fb" \
    'FM_BACKEND_HERDR_WIN32_CLI=1 fm_backend_herdr_cli fmtest tab create --cwd /c/Users/ebatt/proj --label fm-x'
  assert_contains "$(cat "$log")" \
    "EXCL=*${US}tab${US}create${US}--cwd${US}C:\\Users\\ebatt\\proj${US}--label${US}fm-x${US}--session${US}fmtest" \
    "the Windows call must disable MSYS conversion for the whole call and convert --cwd itself"
  pass "fm_backend_herdr_cli: the Windows branch disables argument conversion and hands herdr a Win32 --cwd"
}

test_cli_win32_branch_keeps_a_slash_leading_literal() {
  local fb log
  fb=$(make_cygpath "$TMP_ROOT/cli-literal"); log="$TMP_ROOT/cli-literal/log"; : > "$log"
  make_logging_herdr "$fb"
  FM_HERDR_LOG="$log" adapter "$fb" \
    'FM_BACKEND_HERDR_WIN32_CLI=1 fm_backend_herdr_cli fmtest pane send-text w1:p1 /clear'
  assert_contains "$(cat "$log")" \
    "EXCL=*${US}pane${US}send-text${US}w1:p1${US}/clear${US}--session${US}fmtest" \
    "a slash-leading literal steered into a pane must arrive as itself"
  pass "fm_backend_herdr_cli: a /-leading send-text literal is never rewritten into a Windows path"
}

test_cli_win32_branch_keeps_a_match_value() {
  local fb log
  fb=$(make_cygpath "$TMP_ROOT/cli-match"); log="$TMP_ROOT/cli-match/log"; : > "$log"
  make_logging_herdr "$fb"
  FM_HERDR_LOG="$log" adapter "$fb" \
    'FM_BACKEND_HERDR_WIN32_CLI=1 fm_backend_herdr_cli fmtest pane read w1:p1 --match=/x'
  assert_contains "$(cat "$log")" \
    "EXCL=*${US}pane${US}read${US}w1:p1${US}--match=/x${US}--session${US}fmtest" \
    "a --match value must not be rewritten into a drive path"
  pass "fm_backend_herdr_cli: a --match=/x value reaches herdr as itself, not as X:/"
}

test_cli_win32_branch_converts_the_joined_cwd_form() {
  local fb log
  fb=$(make_cygpath "$TMP_ROOT/cli-joined"); log="$TMP_ROOT/cli-joined/log"; : > "$log"
  make_logging_herdr "$fb"
  FM_HERDR_LOG="$log" adapter "$fb" \
    'FM_BACKEND_HERDR_WIN32_CLI=1 fm_backend_herdr_cli fmtest workspace create --cwd=/c/Users/ebatt/proj'
  assert_contains "$(cat "$log")" \
    "EXCL=*${US}workspace${US}create${US}--cwd=C:\\Users\\ebatt\\proj" \
    "the --cwd=<path> spelling must convert too"
  pass "fm_backend_herdr_cli: both --cwd spellings reach herdr as Windows paths"
}

# --- presentation lock namespace validity on a mode-less filesystem ---------

# A `stat` that answers like a filesystem of the caller's choosing: one mode for
# the namespace directory, another for the probe directory the adapter creates
# inside it, and one owner uid for both.
make_stat_fake() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/stat" <<'SH'
#!/usr/bin/env bash
set -u
fmt=$2; path=$3
case "$fmt" in
  *u*) printf '%s\n' "${FM_FAKE_STAT_UID:?}" ;;
  *)
    case "$path" in
      */.fm-mode-probe.*) printf '%s\n' "${FM_FAKE_STAT_PROBE_MODE:?}" ;;
      *) printf '%s\n' "${FM_FAKE_STAT_MODE:?}" ;;
    esac
    ;;
esac
SH
  chmod +x "$fb/stat"
  printf '%s\n' "$fb"
}

test_namespace_valid_accepts_a_real_private_directory() {
  local dir="$TMP_ROOT/ns-real"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null
  adapter "" 'fm_backend_herdr_presentation_lock_namespace_valid "$1"' "$dir" ||
    fail "a directory this user created privately must be accepted"
  pass "fm_backend_herdr_presentation_lock_namespace_valid: the operator's own private namespace is accepted"
}

test_namespace_valid_accepts_755_when_the_filesystem_drops_modes() {
  local fb dir="$TMP_ROOT/ns-modeless/ns"
  fb=$(make_stat_fake "$TMP_ROOT/ns-modeless")
  mkdir -p "$dir"
  FM_FAKE_STAT_UID=$(id -u) FM_FAKE_STAT_MODE=755 FM_FAKE_STAT_PROBE_MODE=755 \
    adapter "$fb" 'fm_backend_herdr_presentation_lock_namespace_valid "$1"' "$dir" ||
    fail "a filesystem that cannot carry a mode must not fail the mode check forever"
  [ -z "$(find "$TMP_ROOT/ns-modeless" -mindepth 1 -name '.fm-mode-probe.*' -print -quit)" ] ||
    fail "the mode probe must not leave a directory behind"
  [ -z "$(find "$dir" -mindepth 1 -print -quit)" ] ||
    fail "the mode probe must never write inside the namespace it is judging"
  pass "fm_backend_herdr_presentation_lock_namespace_valid: a mode-less filesystem falls back to owner identity alone"
}

test_namespace_valid_still_refuses_a_loose_directory() {
  local fb dir="$TMP_ROOT/ns-loose/ns"
  fb=$(make_stat_fake "$TMP_ROOT/ns-loose")
  mkdir -p "$dir"
  FM_FAKE_STAT_UID=$(id -u) FM_FAKE_STAT_MODE=755 FM_FAKE_STAT_PROBE_MODE=700 \
    adapter "$fb" 'fm_backend_herdr_presentation_lock_namespace_valid "$1"' "$dir" &&
    fail "a group-readable namespace on a mode-capable filesystem must still be refused"
  pass "fm_backend_herdr_presentation_lock_namespace_valid: a loose namespace on a mode-capable filesystem is still refused"
}

test_namespace_valid_still_refuses_another_owner() {
  local fb dir="$TMP_ROOT/ns-owner/ns"
  fb=$(make_stat_fake "$TMP_ROOT/ns-owner")
  mkdir -p "$dir"
  FM_FAKE_STAT_UID=$(( $(id -u) + 1 )) FM_FAKE_STAT_MODE=700 FM_FAKE_STAT_PROBE_MODE=755 \
    adapter "$fb" 'fm_backend_herdr_presentation_lock_namespace_valid "$1"' "$dir" &&
    fail "a namespace owned by another user must be refused whatever the filesystem can carry"
  pass "fm_backend_herdr_presentation_lock_namespace_valid: another user's namespace is refused on every filesystem"
}

# --- the workspace mover's own socket path guard ----------------------------

test_mover_accepts_a_windows_socket_path_shape() {
  local out
  if ! command -v python3 >/dev/null 2>&1; then
    pass "skip: python3 not found (the workspace mover's guard is python)"
    return 0
  fi
  out=$(python3 - "$ROOT/bin/backends/herdr-workspace-move.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("mover", sys.argv[1])
mover = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mover)
cases = [
    ("/tmp/herdr.sock", True),
    ("C:\\Users\\ebatt\\AppData\\Roaming\\herdr\\herdr.sock", True),
    ("c:/srv/herdr.sock", True),
    ("herdr.sock", False),
    ("CC:/srv/herdr.sock", False),
    ("", False),
]
problems = [
    "%r want=%s got=%s" % (path, want, mover._is_absolute_socket_path(path))
    for path, want in cases
    if mover._is_absolute_socket_path(path) != want
]

# A Windows CPython has no AF_UNIX at all. Reaching for it must report the
# invalid-transport status 2 the adapter already warns about and continues
# past, never an AttributeError traceback.
if hasattr(mover.socket, "AF_UNIX"):
    del mover.socket.AF_UNIX
status = mover.main(["mover", "/tmp/no-such.sock", "w1", "0"])
if status != 2:
    problems.append("AF_UNIX-absent want=2 got=%s" % status)

print(problems[0] if problems else "ok")
PY
  )
  [ "$out" = ok ] || fail "the mover's socket path guard: $out"
  pass "herdr-workspace-move.py: the socket path guard accepts a Win32 path and still refuses a relative one"
}

# --- fm_backend_herdr_jq_rows: multi-row reads under a text-mode jq ----------

# A `jq` that prints exactly the bytes in FM_FAKE_JQ_OUT (through printf %b, so
# a case scripts \r and \n directly), exits FM_FAKE_JQ_STATUS, and logs its own
# argument list unit-separated. It parses nothing: these cases are about what
# the funnel does to jq's OUTPUT and which arguments reach it, and a scripted
# answer is the only way to model a text-mode stdout from a POSIX host.
make_scripted_jq() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/jq" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_FAKE_JQ_LOG:-}" ]; then
  {
    printf 'jq'
    for a in "$@"; do printf '\x1f%s' "$a"; done
    printf '\n'
  } >> "$FM_FAKE_JQ_LOG"
fi
cat > /dev/null
printf '%b' "${FM_FAKE_JQ_OUT:-}"
exit "${FM_FAKE_JQ_STATUS:-0}"
SH
  chmod +x "$fb/jq"
  printf '%s\n' "$fb"
}

# A `jq` that is the REAL jq with a Windows text-mode stdout: it runs the real
# binary (resolved here, before this fakebin shadows it) and terminates every
# record CR LF, which is what a native jq.exe does. Used by the cases that need
# real filter semantics rather than a scripted answer. The `${line%$'\r'}` keeps
# it honest on Windows, where the real jq already ended the record that way.
#
# The three cases that use it are the only ones in this file that need a real
# tool rather than a fake, so they note and skip where jq is absent - which is
# what tests/fm-backend-herdr.test.sh does with the whole suite for the same
# reason - instead of failing a box that simply has not installed it.
have_real_jq() {  # <what-is-skipped>
  command -v jq >/dev/null 2>&1 && return 0
  echo "note: jq not found; skipping $1" >&2
  return 1
}

make_text_mode_jq() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin" real
  real=$(command -v jq) || fail "the text-mode jq fake needs a real jq to wrap"
  mkdir -p "$fb"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -u\n'
    printf "real='%s'\n" "$real"
    cat <<'SH'
out=$("$real" "$@") || exit $?
[ -n "$out" ] || exit 0
while IFS= read -r line; do printf '%s\r\n' "${line%$'\r'}"; done <<EOF
$out
EOF
exit 0
SH
  } > "$fb/jq"
  chmod +x "$fb/jq"
  printf '%s\n' "$fb"
}

# A `herdr` that answers each read-only listing from a file named for its
# subcommand pair ($FM_FAKE_HERDR_DIR/workspace-list.out and friends), so a
# case can script a whole read path without having to order its calls, and
# logs every invocation unit-separated to FM_HERDR_LOG when one is set.
# `pane get` is answered from its own argument rather than a file, because the
# presence check compares the id it asked for against the id it got back.
make_listing_herdr() {  # <fakebin>
  cat > "$1/herdr" <<'SH'
#!/usr/bin/env bash
set -u
dir=${FM_FAKE_HERDR_DIR:?}
if [ -n "${FM_HERDR_LOG:-}" ]; then
  {
    printf 'herdr'
    for a in "$@"; do printf '\x1f%s' "$a"; done
    printf '\n'
  } >> "$FM_HERDR_LOG"
fi
if [ "${1:-}" = status ]; then
  printf '{"client":{"version":"0.8.2","protocol":20},"server":{"running":true}}\n'
  exit 0
fi
if [ "${1:-}" = pane ] && [ "${2:-}" = get ]; then
  printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}"
  exit 0
fi
file="$dir/${1:-}-${2:-}.out"
[ -f "$file" ] && cat "$file"
exit 0
SH
  chmod +x "$1/herdr"
}

# Every assertion below reads the funnel's stdout with CR and LF made visible
# (`tr '\r\n' 'RN'`), because the bytes ARE the subject here and a terminal
# renders a stray CR as nothing at all - which is exactly how this defect
# survived a passing-looking refusal message for as long as it did.

test_jq_rows_posix_branch_passes_every_byte_through() {
  local fb out
  fb=$(make_scripted_jq "$TMP_ROOT/jq-posix-bytes")
  out=$( FM_FAKE_JQ_OUT='w1\r\nw7\r\n' \
    adapter "$fb" 'OSTYPE=linux-gnu; fm_backend_herdr_jq_rows "{}" ".x[]" | tr "\r\n" "RN"' )
  [ "$out" = "w1RNw7RN" ] ||
    fail "the POSIX branch must hand back jq's bytes untouched, got '$out'"
  pass "fm_backend_herdr_jq_rows: a POSIX host still gets jq's own bytes, CRs included"
}

test_jq_rows_msys_branch_removes_the_record_terminator_cr() {
  local fb out
  fb=$(make_scripted_jq "$TMP_ROOT/jq-msys-strip")
  out=$( FM_FAKE_JQ_OUT='w1\r\nw7\r\n' \
    adapter "$fb" 'OSTYPE=msys; fm_backend_herdr_jq_rows "{}" ".x[]" | tr "\r\n" "RN"' )
  [ "$out" = "w1Nw7N" ] ||
    fail "a text-mode jq's CR must not survive into a multi-row read, got '$out'"
  pass "fm_backend_herdr_jq_rows: a Windows userland gets LF-terminated rows out of a text-mode jq"
}

test_jq_rows_msys_branch_keeps_a_cr_that_is_not_a_terminator() {
  local fb out
  fb=$(make_scripted_jq "$TMP_ROOT/jq-msys-interior")
  out=$( FM_FAKE_JQ_OUT='a\rb\r\nc\r\n' \
    adapter "$fb" 'OSTYPE=msys; fm_backend_herdr_jq_rows "{}" ".x[]" | tr "\r\n" "RN"' )
  [ "$out" = "aRbNcN" ] ||
    fail "only the CR jq added before its own LF may be removed, got '$out'"
  pass "fm_backend_herdr_jq_rows: a CR inside a value survives - the undo is exact, not a blanket strip"
}

test_jq_rows_msys_branch_is_the_exact_inverse_of_text_mode() {
  local fb msys posix
  fb=$(make_scripted_jq "$TMP_ROOT/jq-msys-inverse")
  # A jq answer whose value legitimately ENDS in a CR. Text mode renders it
  # `1 CR CR LF`; a POSIX jq renders the same value `1 CR LF`. The Windows
  # branch must turn the first into the second exactly - a funnel that guessed
  # the trailing CR was half a terminator would answer `1`, and a tab really
  # labelled "1<CR>" would then pass the seeded-default-tab prune gate on
  # Windows and nowhere else.
  msys=$( FM_FAKE_JQ_OUT='1\r\r\n' \
    adapter "$fb" 'OSTYPE=msys; fm_backend_herdr_jq_rows "{}" ".x[]" | tr "\r\n" "RN"' )
  posix=$( FM_FAKE_JQ_OUT='1\r\n' \
    adapter "$fb" 'OSTYPE=linux-gnu; fm_backend_herdr_jq_rows "{}" ".x[]" | tr "\r\n" "RN"' )
  [ "$msys" = "1RN" ] && [ "$posix" = "1RN" ] ||
    fail "the Windows branch must undo the text-mode terminator and nothing else, got msys='$msys' posix='$posix'"
  pass "fm_backend_herdr_jq_rows: a CR that is the last byte of a VALUE survives - the undo is exact, not a guess"
}

test_jq_rows_emits_nothing_and_succeeds_for_an_empty_answer() {
  local fb posix msys posix_status msys_status
  fb=$(make_scripted_jq "$TMP_ROOT/jq-empty")
  posix=$( FM_FAKE_JQ_OUT='' \
    adapter "$fb" 'OSTYPE=linux-gnu; fm_backend_herdr_jq_rows "{}" ".x[]" | wc -c | tr -d " "' )
  msys=$( FM_FAKE_JQ_OUT='' \
    adapter "$fb" 'OSTYPE=msys; fm_backend_herdr_jq_rows "{}" ".x[]" | wc -c | tr -d " "' )
  [ "$posix" = 0 ] && [ "$msys" = 0 ] ||
    fail "an empty answer must stay empty on both branches (a blank line is one loop iteration to every \`while read\` caller), got posix=$posix msys=$msys"
  # And it must SUCCEED. No duplicate tab is the ordinary case, and
  # fm_backend_herdr_create_task refuses the whole spawn on a non-zero status
  # here ("could not parse herdr tab list output"), so an empty answer that
  # reports failure would break every task creation on Windows.
  FM_FAKE_JQ_OUT='' adapter "$fb" 'OSTYPE=linux-gnu; fm_backend_herdr_jq_rows "{}" ".x[]"' >/dev/null 2>&1
  posix_status=$?
  FM_FAKE_JQ_OUT='' adapter "$fb" 'OSTYPE=msys; fm_backend_herdr_jq_rows "{}" ".x[]"' >/dev/null 2>&1
  msys_status=$?
  [ "$posix_status" = 0 ] && [ "$msys_status" = 0 ] ||
    fail "an empty answer is a success, not a failure; got posix=$posix_status msys=$msys_status"
  pass "fm_backend_herdr_jq_rows: an empty answer emits zero bytes and exits 0 on both branches"
}

test_jq_rows_propagates_the_jq_exit_status_on_both_branches() {
  local fb posix msys
  fb=$(make_scripted_jq "$TMP_ROOT/jq-status")
  FM_FAKE_JQ_OUT='w1\r\n' FM_FAKE_JQ_STATUS=5 \
    adapter "$fb" 'OSTYPE=linux-gnu; fm_backend_herdr_jq_rows "{}" ".x[]"' >/dev/null 2>&1
  posix=$?
  FM_FAKE_JQ_OUT='w1\r\n' FM_FAKE_JQ_STATUS=5 \
    adapter "$fb" 'OSTYPE=msys; fm_backend_herdr_jq_rows "{}" ".x[]"' >/dev/null 2>&1
  msys=$?
  [ "$posix" = 5 ] && [ "$msys" = 5 ] ||
    fail "jq's own exit status is what fm_backend_herdr_create_task refuses on; got posix=$posix msys=$msys"
  pass "fm_backend_herdr_jq_rows: jq's exit status reaches the caller on both branches"
}

test_jq_rows_sends_identical_arguments_on_both_branches() {
  local fb posix_log msys_log
  fb=$(make_scripted_jq "$TMP_ROOT/jq-args")
  posix_log="$TMP_ROOT/jq-args/posix.log"; msys_log="$TMP_ROOT/jq-args/msys.log"
  : > "$posix_log"; : > "$msys_log"
  FM_FAKE_JQ_OUT='w1\r\n' FM_FAKE_JQ_LOG="$posix_log" \
    adapter "$fb" 'OSTYPE=linux-gnu; fm_backend_herdr_jq_rows "{}" --arg want firstmate ".a[] | select(.l == \$want)"' >/dev/null
  FM_FAKE_JQ_OUT='w1\r\n' FM_FAKE_JQ_LOG="$msys_log" \
    adapter "$fb" 'OSTYPE=msys; fm_backend_herdr_jq_rows "{}" --arg want firstmate ".a[] | select(.l == \$want)"' >/dev/null
  [ "$(cat "$posix_log")" = "jq${US}-r${US}--arg${US}want${US}firstmate${US}.a[] | select(.l == \$want)" ] ||
    fail "the funnel must invoke jq exactly as the call site always did, got '$(cat "$posix_log")'"
  [ "$(cat "$posix_log")" = "$(cat "$msys_log")" ] ||
    fail "the Windows branch may only change what comes BACK from jq, never what goes in"
  pass "fm_backend_herdr_jq_rows: both branches invoke jq with the same, unchanged argument list"
}

test_workspace_find_all_is_clean_under_a_text_mode_jq() {
  local fb dir out
  have_real_jq "the text-mode workspace_find_all case" || return 0
  dir="$TMP_ROOT/find-all-crlf"; mkdir -p "$dir/resp"
  fb=$(make_text_mode_jq "$dir")
  make_listing_herdr "$fb"
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w7","label":"firstmate"}]}}\n' \
    > "$dir/resp/workspace-list.out"
  out=$( FM_FAKE_HERDR_DIR="$dir/resp" \
    adapter "$fb" 'OSTYPE=msys; fm_backend_herdr_workspace_find_all fmtest | tr "\r\n" "RN"' )
  [ "$out" = "w1Nw7N" ] ||
    fail "every workspace id this find hands out goes back to herdr as an id; got '$out'"
  pass "fm_backend_herdr_workspace_find_all: two matches come back as two clean ids under a text-mode jq"
}

test_ambiguity_refusal_names_clean_workspace_ids_under_a_text_mode_jq() {
  local fb dir out status
  have_real_jq "the text-mode ambiguity refusal case" || return 0
  dir="$TMP_ROOT/ambiguous-crlf"; mkdir -p "$dir/resp"
  fb=$(make_text_mode_jq "$dir")
  make_listing_herdr "$fb"
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w7","label":"firstmate"}]}}\n' \
    > "$dir/resp/workspace-list.out"
  # The exact scenario tests/fm-backend-herdr.test.sh checks with the host's own
  # jq, driven here from any host: this is the refusal that read `w1<CR> w7`.
  out=$( FM_FAKE_HERDR_DIR="$dir/resp" \
    adapter "$fb" 'OSTYPE=msys; fm_backend_herdr_workspace_ensure fmtest /tmp' 2>&1 )
  status=$?
  expect_code 3 "$status" "two same-labeled workspaces with no launcher identity must still refuse"
  case "$out" in
    *$'\r'*) fail "the ambiguity refusal still carries a control character an operator cannot see: '$(printf '%s' "$out" | tr '\r\n' 'RN')'" ;;
  esac
  assert_contains "$out" "(w1 w7)" "the ambiguity refusal must name both candidate workspaces"
  pass "fm_backend_herdr_workspace_ensure: the ambiguity refusal names clean ids under a text-mode jq"
}

test_create_task_closes_real_tab_ids_under_a_text_mode_jq() {
  local fb dir log closed
  have_real_jq "the text-mode create_task case" || return 0
  dir="$TMP_ROOT/create-task-crlf"; mkdir -p "$dir/resp"
  fb=$(make_text_mode_jq "$dir")
  log="$dir/log"; : > "$log"
  make_listing_herdr "$fb"
  # TWO husk tabs already carry this spawn's label, so the duplicate read is a
  # two-row one and its first row is the record a text-mode jq damages. That
  # record is not a message: it becomes the argument of `tab close`, the one
  # destructive herdr call on this path.
  printf '{"result":{"tabs":[{"tab_id":"w1:t8","label":"fm-dup","workspace_id":"w1"},{"tab_id":"w1:t9","label":"fm-dup","workspace_id":"w1"}]}}\n' \
    > "$dir/resp/tab-list.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p8","tab_id":"w1:t8"},{"pane_id":"w1:p9","tab_id":"w1:t9"}]}}\n' \
    > "$dir/resp/pane-list.out"
  printf '{"error":{"code":"agent_not_found"}}\n' > "$dir/resp/agent-get.out"
  printf '{"result":{"tab":{"tab_id":"w1:t10"},"root_pane":{"pane_id":"w1:p10"}}}\n' > "$dir/resp/tab-create.out"
  # It ends in the "failed to remove preexisting tab(s)" refusal, because this
  # fake keeps listing the husks it was asked to close. The closes are what
  # this case is about, not the verdict.
  FM_HERDR_LOG="$log" FM_FAKE_HERDR_DIR="$dir/resp" \
    adapter "$fb" 'OSTYPE=msys; fm_backend_herdr_create_task fmtest:w1 fm-dup /tmp ""' >/dev/null 2>&1 || true
  closed=$(grep -c "${US}tab${US}close${US}w1:t" "$log" || true)
  [ "$closed" = 2 ] ||
    fail "both husks must be closed by an id herdr recognises; got $closed such calls in: $(tr '\r' 'R' < "$log")"
  grep -q "${US}tab${US}close${US}w1:t8${US}" "$log" ||
    fail "the FIRST duplicate - the row a text-mode jq damages - was not closed by its real id: $(tr '\r' 'R' < "$log")"
  pass "fm_backend_herdr_create_task: both duplicate tab ids reach \`tab close\` intact under a text-mode jq"
}

test_list_live_rows_are_clean_under_a_text_mode_jq() {
  local fb dir out
  have_real_jq "the text-mode list_live case" || return 0
  dir="$TMP_ROOT/list-live-crlf"; mkdir -p "$dir/resp"
  fb=$(make_text_mode_jq "$dir")
  make_listing_herdr "$fb"
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}\n' > "$dir/resp/workspace-list.out"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-alpha","workspace_id":"w1"},{"tab_id":"w1:t3","label":"fm-beta","workspace_id":"w1"}]}}\n' \
    > "$dir/resp/tab-list.out"
  printf '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"},{"pane_id":"w1:p3","tab_id":"w1:t3"}]}}\n' \
    > "$dir/resp/pane-list.out"
  out=$( FM_FAKE_HERDR_DIR="$dir/resp" \
    adapter "$fb" 'OSTYPE=msys; fm_backend_herdr_list_live fmtest | tr "\r\n\t" "RNT"' )
  [ "$out" = "fmtest:w1:p2Tfm-alphaNfmtest:w1:p3Tfm-betaN" ] ||
    fail "every recovery row must be a clean target and label under a text-mode jq, got '$out'"
  pass "fm_backend_herdr_list_live: the read loop's tab ids and labels survive a text-mode jq intact"
}

test_canonical_socket_path_posix_is_unchanged
test_canonical_socket_path_refuses_relative_and_empty
test_canonical_socket_path_folds_a_win32_path
test_canonical_socket_path_win32_needs_cygpath
test_socket_paths_equal_is_byte_exact_without_cygpath
test_socket_paths_equal_folds_case_on_a_windows_userland
test_win32_cli_detects_a_native_binary_next_to_cygpath
test_win32_cli_leaves_a_shell_script_fake_alone
test_win32_cli_needs_cygpath
test_win32_cli_survives_an_unreadable_herdr
test_win32_cli_override_forces_the_answer
test_cli_plain_branch_is_untouched
test_cli_win32_branch_converts_only_cwd
test_cli_win32_branch_keeps_a_slash_leading_literal
test_cli_win32_branch_keeps_a_match_value
test_cli_win32_branch_converts_the_joined_cwd_form
test_namespace_valid_accepts_a_real_private_directory
test_namespace_valid_accepts_755_when_the_filesystem_drops_modes
test_namespace_valid_still_refuses_a_loose_directory
test_namespace_valid_still_refuses_another_owner
test_mover_accepts_a_windows_socket_path_shape
test_jq_rows_posix_branch_passes_every_byte_through
test_jq_rows_msys_branch_removes_the_record_terminator_cr
test_jq_rows_msys_branch_keeps_a_cr_that_is_not_a_terminator
test_jq_rows_msys_branch_is_the_exact_inverse_of_text_mode
test_jq_rows_emits_nothing_and_succeeds_for_an_empty_answer
test_jq_rows_propagates_the_jq_exit_status_on_both_branches
test_jq_rows_sends_identical_arguments_on_both_branches
test_workspace_find_all_is_clean_under_a_text_mode_jq
test_ambiguity_refusal_names_clean_workspace_ids_under_a_text_mode_jq
test_create_task_closes_real_tab_ids_under_a_text_mode_jq
test_list_live_rows_are_clean_under_a_text_mode_jq
