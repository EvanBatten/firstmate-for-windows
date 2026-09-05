#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. Shared fake-toolchain and spawn-world
# builders live in tests/fixtures.sh; wake-queue mocks in wake-helpers.sh;
# secondmate-lifecycle mocks in secondmate-helpers.sh. Suite-specific fakes
# that encode a single test's terminal or lifecycle assumptions still belong
# with the tests that own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh, fixtures.sh) source this library for ROOT/fail/pass, and the
# test that includes them may also source it directly. Re-sourcing must not wipe
# the registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal
# on EXIT/INT/TERM. A test file that needs extra teardown (e.g. killing a
# daemon) should define its own EXIT trap and call fm_test_cleanup from inside
# it so registered dirs are still removed.
#
# The call site is almost always `TMP_ROOT=$(fm_test_tmproot prefix)`, which
# forks a subshell to capture stdout. Anything that function does to the
# current shell's state - an array append, a trap - dies with that subshell
# and never reaches the real caller, so registration cannot go through
# in-process state. `$$` is the one thing bash keeps stable across that
# boundary (it always resolves to the invoking shell's PID, not the
# subshell's - see `man bash` on `$$`), so fm_test_tmproot records the
# directory in a `$$`-keyed registry file instead, and the trap that reaps
# that file is armed once, here, at source time - which always runs in the
# real caller, never a subshell.

FM_TEST_CLEANUP_DIRS=()
FM_TEST_CLEANUP_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/.fm-test-cleanup.$$.XXXXXX") || return 1

fm_test_pid_identity() {
  local pid=$1
  FM_STATE_OVERRIDE="${TMPDIR:-/tmp}" bash -c \
    '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid"
}

FM_TEST_OWNER_IDENTITY=$(fm_test_pid_identity "$$") || {
  rm -f "$FM_TEST_CLEANUP_REGISTRY"
  return 1
}

fm_test_cleanup() {
  local d
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  if [ -f "$FM_TEST_CLEANUP_REGISTRY" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && rm -rf "$d"
    done < "$FM_TEST_CLEANUP_REGISTRY"
    rm -f "$FM_TEST_CLEANUP_REGISTRY"
  fi
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX") || return 1
  if ! printf '%s\n%s\n' "$$" "$FM_TEST_OWNER_IDENTITY" > "$root/.fm-test-fixture" ||
    ! printf '%s\n' "$root" >> "$FM_TEST_CLEANUP_REGISTRY"; then
    rm -rf "$root"
    return 1
  fi
  printf '%s\n' "$root"
}

trap fm_test_cleanup EXIT
trap 'fm_test_cleanup; exit 130' INT
trap 'fm_test_cleanup; exit 143' TERM

# fm_test_reap_orphans: best-effort sweep for fixture roots left behind by a
# prior run that was killed hard enough to skip the traps above (e.g. a
# SIGKILL timeout). Only removes directories carrying the .fm-test-fixture
# marker fm_test_tmproot writes, so it never touches unrelated fm-* tmp dirs
# from real (non-test) firstmate commands. The marker identifies the owning
# shell across PID reuse, so the same live owner always wins over the age
# fallback for dead or unowned roots.
FM_TEST_ORPHAN_MAX_AGE_SECONDS=${FM_TEST_ORPHAN_MAX_AGE_SECONDS:-3600}

fm_test_reap_orphans() {
  local marker dir mtime now owner_pid owner_identity current_identity
  now=$(date +%s)
  for marker in "${TMPDIR:-/tmp}"/fm-*/.fm-test-fixture; do
    [ -e "$marker" ] || continue
    owner_pid=$(sed -n '1p' "$marker" 2>/dev/null) || owner_pid=
    owner_identity=$(sed -n '2,$p' "$marker" 2>/dev/null) || owner_identity=
    case "$owner_pid" in
      '' | *[!0-9]*) ;;
      *)
        current_identity=$(fm_test_pid_identity "$owner_pid" 2>/dev/null) || current_identity=
        if [ -n "$owner_identity" ] && [ "$current_identity" = "$owner_identity" ]; then
          continue
        fi
        ;;
    esac
    mtime=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null) || continue
    [ $((now - mtime)) -ge "$FM_TEST_ORPHAN_MAX_AGE_SECONDS" ] || continue
    dir=$(dirname "$marker")
    if [ -d "$dir" ] && [ ! -L "$dir" ]; then
      find "$dir" -type d -exec chmod u+rwx {} + 2>/dev/null || true
    fi
    rm -rf "$dir"
  done
}

# A parent coordinator can reap once before it starts isolated child sections.
# Those children use their own EXIT cleanup and must not spend their bounded
# execution window repeating the same global stale-fixture scan.
if [ "${FM_TEST_SKIP_ORPHAN_REAP:-0}" != 1 ]; then
  fm_test_reap_orphans
fi

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fakebin_link puts REAL tools in a fakebin, so
# a case can hand a child a curated PATH that has some tools and not others.
# fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir. fm_fake_version_tool drops a stub for a tool
# whose installed version bootstrap gates, so a fixture cannot be reported as an
# unparseable build simply for answering `--version` with nothing.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

# fm_fakebin_link <fakebin> <tool>...
# Places each named tool in <fakebin> so a child that runs with PATH=<fakebin>
# can execute exactly the listed tools and nothing else. A tool the caller
# cannot resolve, or one that resolves to a shell builtin rather than to an
# absolute file, is skipped - the same tolerance the open-coded
# `command -v <tool> || continue` loops this replaces already had.
#
# On macOS and Linux this is that loop's symlink, unchanged. A Windows userland
# needs the indirection instead: Windows resolves an MSYS or MinGW executable's
# DLLs against the directory the image was launched from and then against PATH,
# so a symlinked bash.exe sitting in a fakebin that holds no msys-2.0.dll dies
# with "error while loading shared libraries" and exit 127 before the script
# under test runs a single line. Exec-ing the tool by its absolute path leaves
# the loader looking in the tool's real directory, where its DLLs are.
fm_fakebin_link() {
  local fakebin=$1 tool tool_path quoted
  shift
  for tool in "$@"; do
    tool_path=$(command -v "$tool") || continue
    case "$tool_path" in
      /*) ;;
      *) continue ;;
    esac
    case "${OSTYPE:-}" in
      msys*|mingw*|cygwin*)
        printf -v quoted '%q' "$tool_path"
        {
          printf '#!%s\n' "${BASH:-/bin/bash}"
          printf 'exec %s "$@"\n' "$quoted"
        } > "$fakebin/$tool"
        chmod +x "$fakebin/$tool"
        ;;
      *)
        ln -s "$tool_path" "$fakebin/$tool"
        ;;
    esac
  done
}

# fm_test_base_path
# The system half of a fixture's curated PATH: the directories a test wants a
# fixture child to resolve real tools from, before the fakebin that fakes the
# rest. Every caller spells it `${FM_TEST_BASE_PATH:-$(fm_test_base_path)}`, so
# an operator can still name the list outright.
#
# On macOS and Linux this is the literal four-directory list those callers used
# to hold, byte for byte. Git Bash keeps bash and coreutils in /usr/bin but
# ships git and jq elsewhere, so the same list describes a machine with no git
# at all and every fixture that asserts a quiet bootstrap fails on a MISSING:
# git line before it tests anything. Appending those two tools' real
# directories there restores the list's Linux meaning.
#
# git and jq, and nothing else, because the suite itself says which tools the
# four directories hold: a case that needs git or jq ABSENT has to mask them
# with a BASH_ENV shim (tests/fm-bootstrap.test.sh:501, :670), while a case that
# needs node absent simply deletes it from the fakebin (:897) - which only works
# because node is not in those four directories on a passing host. Appending a
# tool of the second kind would silently defeat the fixture that removed it.
fm_test_base_path() {
  local base=/usr/bin:/bin:/usr/sbin:/sbin tool tool_dir
  case "${OSTYPE:-}" in
    msys*|mingw*|cygwin*) ;;
    *) printf '%s\n' "$base"; return 0 ;;
  esac
  for tool in git jq; do
    tool_dir=$(command -v "$tool" 2>/dev/null) || continue
    case "$tool_dir" in
      /*) ;;
      *) continue ;;
    esac
    tool_dir=${tool_dir%/*}
    case ":$base:" in
      *":$tool_dir:"*) ;;
      *) base="$base:$tool_dir" ;;
    esac
  done
  printf '%s\n' "$base"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# fm_fake_version_tool <fakebin> <tool> <override-env-var> <default-version>
# The stub answers `--version` with <override-env-var> when that variable is set
# and non-empty, and with <default-version> otherwise; every other invocation
# exits 0. A case that needs to drive a version floor exports the variable.
fm_fake_version_tool() {
  local fakebin=$1 tool=$2 override=$3 default=$4
  cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' "\${$override:-$default}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: initialize <repo> with one commit
# and a local bare origin, then add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  fm_git_add_origin "$repo" "$repo.origin.git"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects] [harness]: write the
# standard kind=secondmate meta block used across the secondmate suites. Window
# defaults to firstmate:fm-<id>, projects defaults to alpha, and harness defaults
# to echo to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 id window projects=${4:-alpha} harness=${5:-echo}
  id=$(basename "$file" .meta)
  window=${3:-firstmate:fm-$id}
  fm_write_meta "$file" \
    "window=$window" \
    "endpoint_task_id=$id" \
    "worktree=$home" \
    "project=$home" \
    "harness=$harness" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}

# --- host time scale ----------------------------------------------------------
# A wall-clock or poll-count budget written on Linux is a lie on a host where a
# process spawn costs an order of magnitude more (Git Bash on Windows: about
# 50 ms per exec against 1 to 2 ms on Linux, measured 2026-09-05; ledger finding
# 27). These helpers size such a budget from one measurement of this host
# instead of from a bigger constant, so the happy path still returns the moment
# its condition holds and only the bound moves. FM_TEST_TIME_SCALE=<integer>
# pins the scale (1 reproduces the raw Linux budgets on any host); when it is
# unset the library measures once as it is sourced, then exports the result so
# fake scripts, child shells and one-case copies share it. The measurement and
# the family of budgets it retired are in docs/windows/measurement.md.

FM_TEST_TIME_SCALE_REFERENCE_MS=4   # exec cost a fast Linux box stays under: scale 1 there
FM_TEST_TIME_SCALE_MAX=40           # an overloaded host still gets bounded budgets

# fm_test_clock_init: pick this host's clock once as the library is sourced:
# EPOCHREALTIME without a spawn (bash 5), date +%s%N elsewhere, and whole
# seconds from SECONDS when neither exists (stock macOS bash 3.2 with BSD
# date). FM_TEST_CLOCK_RESOLUTION_MS records how far one reading can trail the
# true time, so a deadline pads for it: 1 with sub-second time, 1000 on the
# whole-second fallback.
fm_test_clock_init() {
  FM_TEST_CLOCK_RESOLUTION_MS=1
  if [ -n "${EPOCHREALTIME:-}" ]; then
    FM_TEST_CLOCK=epochrealtime
    return 0
  fi
  case "$(date +%s%N 2>/dev/null)" in
    ''|*[!0-9]*) FM_TEST_CLOCK=seconds; FM_TEST_CLOCK_RESOLUTION_MS=1000 ;;
    *) FM_TEST_CLOCK=date-ns ;;
  esac
}
fm_test_clock_init

# fm_test_now_ms: milliseconds from the clock fm_test_clock_init picked. Bash
# renders EPOCHREALTIME with the locale's decimal separator, so every non-digit
# is stripped rather than one dot.
fm_test_now_ms() {
  local s
  case "$FM_TEST_CLOCK" in
    epochrealtime)
      s=${EPOCHREALTIME//[!0-9]/}
      printf '%s\n' "${s%???}" ;;
    date-ns)
      s=$(date +%s%N)
      printf '%s\n' "${s%??????}" ;;
    *) printf '%s\n' "$((SECONDS * 1000))" ;;
  esac
}

# fm_test_spawn_cost_ms: measured milliseconds per external command on this
# host, from twenty execs of the external true; never below 1.
fm_test_spawn_cost_ms() {
  local true_bin start end i cost
  true_bin=$(type -P true 2>/dev/null) || true_bin=/bin/true
  start=$(fm_test_now_ms)
  i=0
  while [ "$i" -lt 20 ]; do
    "$true_bin"
    i=$((i + 1))
  done
  end=$(fm_test_now_ms)
  cost=$(( (end - start) / 20 ))
  [ "$cost" -ge 1 ] || cost=1
  printf '%s\n' "$cost"
}

# fm_test_time_scale_init: validate a pinned FM_TEST_TIME_SCALE or measure one,
# then export it. Runs once when this library is sourced. A whole-second clock
# cannot time twenty execs, so it takes the fast-host scale of 1 unmeasured.
fm_test_time_scale_init() {
  local cost scale
  if [ -n "${FM_TEST_TIME_SCALE:-}" ]; then
    case "$FM_TEST_TIME_SCALE" in
      *[!0-9]*|0*) fail "FM_TEST_TIME_SCALE must be a positive integer, got '$FM_TEST_TIME_SCALE'" ;;
    esac
    export FM_TEST_TIME_SCALE
    return 0
  fi
  if [ "$FM_TEST_CLOCK_RESOLUTION_MS" -ne 1 ]; then
    FM_TEST_TIME_SCALE=1
    export FM_TEST_TIME_SCALE
    return 0
  fi
  cost=$(fm_test_spawn_cost_ms)
  scale=$(( (cost + FM_TEST_TIME_SCALE_REFERENCE_MS - 1) / FM_TEST_TIME_SCALE_REFERENCE_MS ))
  [ "$scale" -ge 1 ] || scale=1
  [ "$scale" -le "$FM_TEST_TIME_SCALE_MAX" ] || scale=$FM_TEST_TIME_SCALE_MAX
  FM_TEST_TIME_SCALE=$scale
  export FM_TEST_TIME_SCALE
  # A TAP comment, so a slow host's sizing is visible in the run log.
  [ "$scale" -eq 1 ] || printf '# host time scale %s (about %s ms per exec)\n' "$scale" "$cost"
}
fm_test_time_scale_init

# fm_test_seconds <linux-seconds>: that integer budget sized for this host.
fm_test_seconds() {
  printf '%s\n' "$(( $1 * FM_TEST_TIME_SCALE ))"
}

# fm_test_budget_ms <seconds>: an integer or decimal Linux budget, in
# milliseconds sized for this host.
fm_test_budget_ms() {
  local whole frac
  case "$1" in
    *.*) whole=${1%%.*}; frac=${1#*.} ;;
    *) whole=$1; frac='' ;;
  esac
  frac="${frac}000"
  frac=${frac:0:3}
  printf '%s\n' "$(( (10#${whole:-0} * 1000 + 10#$frac) * FM_TEST_TIME_SCALE ))"
}

# fm_test_tenths <ticks>: a tick count in tenths of a second, as the decimal
# seconds string fm_test_wait_until takes; for helpers that still count ticks.
fm_test_tenths() {
  printf '%s.%s\n' "$(( $1 / 10 ))" "$(( $1 % 10 ))"
}

# fm_test_wait_until <linux-seconds> <command> [args...]: run the command every
# 0.1 s until it succeeds (return 0) or this host's sizing of that budget
# elapses (return 124). The deadline is padded by the clock's resolution, so a
# whole-second clock can only lengthen a wait, never end it early. The command
# is a function or executable with its arguments, never a shell string; wrap a
# compound condition in a function. The probe's stderr is dropped: a file that
# does not exist yet is the normal state while waiting, not an error worth
# logging on every tick.
fm_test_wait_until() {
  local budget=$1 deadline now
  shift
  deadline=$(( $(fm_test_now_ms) + $(fm_test_budget_ms "$budget") + FM_TEST_CLOCK_RESOLUTION_MS ))
  while :; do
    if "$@" 2>/dev/null; then
      return 0
    fi
    now=$(fm_test_now_ms)
    [ "$now" -lt "$deadline" ] || return 124
    sleep 0.1
  done
}
