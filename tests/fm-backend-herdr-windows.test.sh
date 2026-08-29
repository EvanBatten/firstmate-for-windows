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

# --- Windows crewmate pane: bash bootstrap and cwd tracking ------------------

# A `herdr` that logs every call unit-separated AND answers the queries a task
# pane makes: the `status --json` liveness probe every target_ready goes
# through, `tab create` with a tab/pane id pair, and `pane get` with whatever
# FM_HERDR_PANE_JSON holds. FM_HERDR_STATUS forces a failure.
make_task_herdr() {  # <fakebin>
  cat > "$1/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'EXCL=%s' "${MSYS2_ARG_CONV_EXCL:-<unset>}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "${FM_HERDR_LOG:?}"
[ "${FM_HERDR_STATUS:-0}" = 0 ] || exit "$FM_HERDR_STATUS"
case "${1:-} ${2:-}" in
  "status --json") printf '{"server":{"running":true}}\n' ;;
  "pane get")      printf '%s\n' "${FM_HERDR_PANE_JSON:-}" ;;
  "tab create")
    # Spelled out rather than inlined as a ${VAR:-<json>} default: the braces in
    # the JSON close the parameter expansion early and truncate the response.
    if [ -n "${FM_HERDR_TAB_JSON:-}" ]; then
      printf '%s\n' "$FM_HERDR_TAB_JSON"
    else
      printf '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}\n'
    fi
    ;;
esac
exit 0
SH
  chmod +x "$1/herdr"
}

test_win32_pane_bash_is_absent_on_a_posix_host() {
  local fb out
  fb=$(make_cygpath "$TMP_ROOT/pane-bash-posix")
  make_logging_herdr "$fb"
  # A shell-script herdr next to a working cygpath: the exact shape every other
  # unit test runs in, on Windows included. No bootstrap may be offered there.
  out=$(adapter "$fb" 'fm_backend_herdr_win32_pane_bash')
  [ -z "$out" ] || fail "a shell-script herdr must offer no pane bootstrap at all, got '$out'"
  adapter "$fb" 'fm_backend_herdr_win32_pane_bash' >/dev/null
  # Exactly 1, the function's own refusal - not merely non-zero, which a crashed
  # or unsourceable adapter would also produce.
  expect_code 1 $? "a shell-script herdr must REFUSE the bootstrap, not just print nothing"
  pass "fm_backend_herdr_win32_pane_bash: a non-PE herdr means the pane already runs a POSIX shell"
}

test_win32_pane_bash_names_this_shells_own_interpreter() {
  local fb out
  fb=$(make_cygpath "$TMP_ROOT/pane-bash-win32")
  out=$(adapter "$fb" 'FM_BACKEND_HERDR_WIN32_CLI=1 fm_backend_herdr_win32_pane_bash')
  case "$out" in
    ?:\\*bash*) ;;
    *) fail "the bootstrap path must be the Win32 spelling of this shell's own bash, got '$out'" ;;
  esac
  pass "fm_backend_herdr_win32_pane_bash: names the running Git Bash by Win32 path, not a guessed install location"
}

test_task_tab_create_posix_call_is_unchanged() {
  local fb log out
  fb=$(make_cygpath "$TMP_ROOT/task-posix"); log="$TMP_ROOT/task-posix/log"; : > "$log"
  make_task_herdr "$fb"
  out=$(FM_HERDR_LOG="$log" adapter "$fb" \
    'fm_backend_herdr_task_tab_create fmtest w1 /tmp/proj fm-x')
  expect_code 0 $? "every call site branches on this status; a success that reports failure refuses a spawn that worked"
  assert_contains "$out" '"pane_id":"w1:p2"' "task_tab_create must echo herdr's raw response for its callers to parse"
  assert_contains "$(cat "$log")" \
    "${US}tab${US}create${US}--workspace${US}w1${US}--cwd${US}/tmp/proj${US}--label${US}fm-x${US}--no-focus${US}--session${US}fmtest" \
    "the POSIX task tab create must reach herdr byte for byte as each call site sent it inline before"
  assert_not_contains "$(cat "$log")" "${US}pane${US}run" \
    "no POSIX pane may ever be handed a shell bootstrap command"
  pass "fm_backend_herdr_task_tab_create: the POSIX call is byte-identical and bootstraps nothing"
}

test_task_tab_create_bootstraps_git_bash_on_msys() {
  local fb log want emitter
  fb=$(make_cygpath "$TMP_ROOT/task-win32"); log="$TMP_ROOT/task-win32/log"; : > "$log"
  make_task_herdr "$fb"
  want=$(adapter "$fb" 'FM_BACKEND_HERDR_WIN32_CLI=1 fm_backend_herdr_win32_pane_bash')
  [ -n "$want" ] || fail "the bootstrap path probe returned nothing"
  # The WHOLE emitter, not just the key: an empty or truncated PROMPT_COMMAND
  # still contains "PROMPT_COMMAND=", and the pane it produces never moves its
  # .cwd, which is a 60-second spawn timeout naming the wrong cause.
  emitter=$(adapter "$fb" 'fm_backend_herdr_win32_pane_prompt_command')
  [ -n "$emitter" ] || fail "the emitter is empty"
  FM_HERDR_LOG="$log" adapter "$fb" \
    'FM_BACKEND_HERDR_WIN32_CLI=1 fm_backend_herdr_task_tab_create fmtest w1 /c/Users/ebatt/proj fm-x' >/dev/null
  assert_contains "$(cat "$log")" \
    "${US}--label${US}fm-x${US}--env${US}SHELL=${want}${US}--env${US}PROMPT_COMMAND=${emitter}${US}--no-focus" \
    "the Windows task tab create must carry SHELL and the COMPLETE OSC 9;9 emitter into the pane's environment"
  assert_contains "$(cat "$log")" \
    "${US}pane${US}run${US}w1:p2${US}& '${want}' --login" \
    "the Windows pane's FIRST command must launch Git Bash by full path through pwsh's call operator"
  pass "fm_backend_herdr_task_tab_create: an MSYS pane gets SHELL, the OSC 9;9 emitter, and a Git Bash first command"
}

test_task_tab_create_never_bootstraps_a_pane_it_did_not_create() {
  local fb log
  fb=$(make_cygpath "$TMP_ROOT/task-fail"); log="$TMP_ROOT/task-fail/log"; : > "$log"
  make_task_herdr "$fb"
  FM_HERDR_LOG="$log" FM_HERDR_STATUS=1 adapter "$fb" \
    'FM_BACKEND_HERDR_WIN32_CLI=1 fm_backend_herdr_task_tab_create fmtest w1 /c/proj fm-x' >/dev/null &&
    fail "task_tab_create must propagate a failed tab create to its caller"
  assert_not_contains "$(cat "$log")" "${US}pane${US}run" \
    "a failed tab create must never leave a pane run aimed at a pane id that was never returned"
  pass "fm_backend_herdr_task_tab_create: a failed create propagates and bootstraps nothing"
}

test_task_tab_create_never_aims_a_bootstrap_at_a_guessed_pane() {
  local fb log out
  fb=$(make_cygpath "$TMP_ROOT/task-nopane"); log="$TMP_ROOT/task-nopane/log"; : > "$log"
  make_task_herdr "$fb"
  out=$(FM_HERDR_LOG="$log" FM_HERDR_TAB_JSON='{"result":{"tab":{"tab_id":"w1:t2"}}}' \
    adapter "$fb" 'FM_BACKEND_HERDR_WIN32_CLI=1 fm_backend_herdr_task_tab_create fmtest w1 /c/proj fm-x')
  assert_contains "$out" '"tab_id":"w1:t2"' "an unparseable pane id must still hand the caller herdr's own response to judge"
  assert_not_contains "$(cat "$log")" "${US}pane${US}run" \
    "a response with no pane id must never be turned into a pane run against a guessed or stale pane"
  pass "fm_backend_herdr_task_tab_create: no pane id in the response means no bootstrap, never a guess"
}

test_prompt_command_emits_the_osc_sequence_herdr_reads() {
  local fb out
  fb=$(make_cygpath "$TMP_ROOT/prompt-cmd")
  # Evaluate the emitter exactly as an interactive bash would, with PWD set to a
  # path the fake cygpath folds deterministically, and read the bytes back.
  out=$(adapter "$fb" 'pc=$(fm_backend_herdr_win32_pane_prompt_command); PWD=/c/x; eval "$pc" | od -An -c | tr -s " "')
  assert_contains "$out" "033 ] 9 ; 9 ; C : \\ x 033 \\" \
    "the emitter must produce ESC ]9;9;<windows path> ESC backslash - the sequence herdr's cwd tracking reads"
  pass "fm_backend_herdr_win32_pane_prompt_command: emits the OSC 9;9 sequence that keeps pane .cwd live"
}

test_current_path_posix_never_falls_back_to_the_frozen_cwd() {
  local fb log out
  fb=$(make_cygpath "$TMP_ROOT/cwd-posix"); log="$TMP_ROOT/cwd-posix/log"; : > "$log"
  make_task_herdr "$fb"
  out=$(FM_HERDR_LOG="$log" \
    FM_HERDR_PANE_JSON='{"result":{"pane":{"cwd":"/tmp/pane-creation-dir","foreground_cwd":null}}}' \
    adapter "$fb" 'fm_backend_herdr_current_path fmtest:w1:p2')
  [ -z "$out" ] ||
    fail "on a POSIX host a null foreground_cwd means UNKNOWN; the frozen creation-time cwd must never be substituted, got '$out'"
  # Without this, a POSIX branch that crashed before reading anything would look
  # exactly like a POSIX branch that correctly declined to substitute.
  assert_contains "$(cat "$log")" "${US}pane${US}get${US}w1:p2" \
    "current_path must actually have read the pane before reporting it does not know where it is"
  pass "fm_backend_herdr_current_path: a POSIX host still refuses the frozen creation-time cwd"
}

test_current_path_msys_falls_back_to_the_live_cwd() {
  local fb log out
  fb=$(make_cygpath "$TMP_ROOT/cwd-msys"); log="$TMP_ROOT/cwd-msys/log"; : > "$log"
  make_task_herdr "$fb"
  out=$(FM_HERDR_LOG="$log" \
    FM_HERDR_PANE_JSON='{"result":{"pane":{"cwd":"C:\\Users\\ebatt\\wt\\a1","foreground_cwd":null}}}' \
    adapter "$fb" 'FM_BACKEND_HERDR_WIN32_CLI=1 fm_backend_herdr_current_path fmtest:w1:p2')
  [ "$out" = /c/Users/ebatt/wt/a1 ] ||
    fail "a Windows pane's always-null foreground_cwd must fall back to the OSC-fed .cwd, folded to a POSIX path, got '$out'"
  pass "fm_backend_herdr_current_path: a Windows pane reports its live .cwd as a POSIX path"
}

test_current_path_msys_still_prefers_foreground_cwd() {
  local fb log out
  fb=$(make_cygpath "$TMP_ROOT/cwd-msys-fg"); log="$TMP_ROOT/cwd-msys-fg/log"; : > "$log"
  make_task_herdr "$fb"
  out=$(FM_HERDR_LOG="$log" \
    FM_HERDR_PANE_JSON='{"result":{"pane":{"cwd":"C:\\Users\\ebatt\\proj","foreground_cwd":"/c/Users/ebatt/wt/a1"}}}' \
    adapter "$fb" 'FM_BACKEND_HERDR_WIN32_CLI=1 fm_backend_herdr_current_path fmtest:w1:p2')
  [ "$out" = /c/Users/ebatt/wt/a1 ] ||
    fail "the fallback must stay a fallback: a herdr build that DOES report foreground_cwd still wins, got '$out'"
  pass "fm_backend_herdr_current_path: the .cwd fallback never overrides a foreground_cwd that is actually present"
}

test_current_path_reads_the_pane_once() {
  local fb log calls
  fb=$(make_cygpath "$TMP_ROOT/cwd-one-read"); log="$TMP_ROOT/cwd-one-read/log"; : > "$log"
  make_task_herdr "$fb"
  FM_HERDR_LOG="$log" \
    FM_HERDR_PANE_JSON='{"result":{"pane":{"cwd":"C:\\Users\\ebatt\\wt\\a1","foreground_cwd":null}}}' \
    adapter "$fb" 'FM_BACKEND_HERDR_WIN32_CLI=1 fm_backend_herdr_current_path fmtest:w1:p2' >/dev/null
  calls=$(grep -c "${US}pane${US}get" "$log")
  [ "$calls" = 1 ] ||
    fail "both cwd fields must come from ONE pane get - two reads race a pane that is moving, got $calls calls"
  pass "fm_backend_herdr_current_path: both cwd fields come from a single pane get, so the fallback cannot race the poll"
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
test_win32_pane_bash_is_absent_on_a_posix_host
test_win32_pane_bash_names_this_shells_own_interpreter
test_task_tab_create_posix_call_is_unchanged
test_task_tab_create_bootstraps_git_bash_on_msys
test_task_tab_create_never_bootstraps_a_pane_it_did_not_create
test_task_tab_create_never_aims_a_bootstrap_at_a_guessed_pane
test_prompt_command_emits_the_osc_sequence_herdr_reads
test_current_path_posix_never_falls_back_to_the_frozen_cwd
test_current_path_msys_falls_back_to_the_live_cwd
test_current_path_msys_still_prefers_foreground_cwd
test_current_path_reads_the_pane_once
