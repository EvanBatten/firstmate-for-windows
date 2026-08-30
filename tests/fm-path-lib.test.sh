#!/usr/bin/env bash
# tests/fm-path-lib.test.sh - unit tests for bin/fm-path-lib.sh, the one owner
# of "is this path absolute, and do these two paths name the same place".
#
# The library has two branches and BOTH are covered from any host. The POSIX
# branch has to keep BEING the expression its callers wrote before it existed -
# `(cd "$p" 2>/dev/null && pwd -P)`, `[ "$a" = "$b" ]`, `case "$p" in "$d"/*)`
# and `case "$p" in /*)` - because a widening there would quietly change how
# five scripts decide whether a worktree is the primary checkout. The Windows
# branch only ever runs on a machine upstream CI does not have.
#
# The library picks its branch from ONE marker: whether `cygpath` is on PATH.
# That makes both branches reachable from either host with nothing faked but
# PATH itself - a fakebin holding a `cygpath` is a Windows userland and a
# fakebin holding none is not - so these cases are the same cases everywhere,
# not two sets that only ever run on one machine each.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-path-lib)
LIB="$ROOT/bin/fm-path-lib.sh"

# --- fixtures ---------------------------------------------------------------

# A PATH with `tr` (fm_path_fold_case needs it) and no `cygpath`: the POSIX
# userland, whatever host is running the suite.
posix_path() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fakebin_link "$fakebin" tr
  printf '%s\n' "$fakebin"
}

# The same PATH plus a `cygpath`, which is the Windows userland's marker. The
# stub is never CALLED by the library - only `command -v`-ed - so its body only
# has to prove that, by failing loudly if anything ever runs it.
windows_path() {
  local dir=$1 fakebin
  fakebin=$(posix_path "$dir")
  printf '#!/usr/bin/env bash\necho "cygpath must not be executed" >&2\nexit 97\n' > "$fakebin/cygpath"
  chmod +x "$fakebin/cygpath"
  printf '%s\n' "$fakebin"
}

# Run <expression> against the library in a child bash whose PATH is exactly
# <fakebin>, so the userland the library sees is the one the case chose. The
# child is started by ABSOLUTE path: PATH here is the fixture, and putting bash
# itself in it would only prove that the fixture can find bash.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  PATH="$fakebin" "${BASH:-/bin/bash}" -c "
    . \"\$0\"
    $expr
  " "$LIB"
}

case_dir() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# --- fm_path_is_absolute ----------------------------------------------------

test_is_absolute_is_the_slash_test_on_posix() {
  local dir fakebin
  dir=$(case_dir is-abs-posix)
  fakebin=$(posix_path "$dir")
  lib_eval "$fakebin" 'fm_path_is_absolute /var/tmp' \
    || fail "a rooted path must be absolute"
  lib_eval "$fakebin" 'fm_path_is_absolute relative/x' \
    && fail "a relative path must not be absolute"
  lib_eval "$fakebin" 'fm_path_is_absolute ""' \
    && fail "an empty path must not be absolute"
  # This is the whole POSIX contract: without cygpath, `C:/x` is a directory
  # named `C:` in the current directory and must keep being reported relative.
  lib_eval "$fakebin" 'fm_path_is_absolute C:/Users/x' \
    && fail "a drive-rooted path must stay RELATIVE on a host with no cygpath"
  pass "path-lib: fm_path_is_absolute is exactly \`case \$p in /*)\` without cygpath"
}

test_is_absolute_accepts_a_drive_root_on_a_windows_userland() {
  local dir fakebin
  dir=$(case_dir is-abs-win)
  fakebin=$(windows_path "$dir")
  lib_eval "$fakebin" 'fm_path_is_absolute /var/tmp' \
    || fail "a rooted path must still be absolute on a Windows userland"
  lib_eval "$fakebin" 'fm_path_is_absolute C:/Users/x' \
    || fail "a forward-slash drive root must be absolute on a Windows userland"
  lib_eval "$fakebin" 'fm_path_is_absolute "C:\\Users\\x"' \
    || fail "a backslash drive root must be absolute on a Windows userland"
  lib_eval "$fakebin" 'fm_path_is_absolute z:/lower' \
    || fail "a lower-case drive letter must be absolute on a Windows userland"
  lib_eval "$fakebin" 'fm_path_is_absolute C:relative' \
    && fail "a drive-relative path (no separator) must not be absolute"
  lib_eval "$fakebin" 'fm_path_is_absolute .git/index.lock' \
    && fail "git's relative answer must stay relative on a Windows userland"
  pass "path-lib: fm_path_is_absolute also accepts a drive root when cygpath is present"
}

# --- fm_path_canon_dir ------------------------------------------------------

test_canon_dir_is_cd_then_pwd_p() {
  local dir fakebin real linked out
  dir=$(case_dir canon)
  fakebin=$(posix_path "$dir")
  mkdir -p "$dir/real/inner"
  real=$(cd "$dir/real/inner" && pwd -P)

  out=$(lib_eval "$fakebin" "fm_path_canon_dir '$dir/real/inner'") \
    || fail "fm_path_canon_dir must resolve an existing directory"
  [ "$out" = "$real" ] \
    || fail "fm_path_canon_dir must answer exactly \`cd && pwd -P\`: got '$out' want '$real'"

  # Resolving symlinks is the -P in `pwd -P` and callers depend on it: a
  # symlinked clone dir has to compare equal to its own physical root, which is
  # exactly what bin/fm-fleet-sync.sh's clone-root gate says it relies on. This
  # is the ONE assertion here that cannot run everywhere - a Windows box without
  # Developer Mode cannot make a symlink at all - so it says so out loud rather
  # than passing silently, because silence would make a `pwd -P` -> `pwd`
  # regression invisible on that box.
  if ln -s "$dir/real/inner" "$dir/link" 2>/dev/null && [ -d "$dir/link" ]; then
    linked=$(lib_eval "$fakebin" "fm_path_canon_dir '$dir/link'") \
      || fail "fm_path_canon_dir must resolve a symlinked directory"
    [ "$linked" = "$real" ] \
      || fail "fm_path_canon_dir must resolve symlinks: got '$linked' want '$real'"
  else
    echo "note: this host cannot create a directory symlink; the -P assertion in fm_path_canon_dir was NOT checked" >&2
  fi
  pass "path-lib: fm_path_canon_dir is \`cd && pwd -P\`, symlinks resolved"
}

test_canon_dir_is_silent_when_it_fails() {
  local dir fakebin err
  dir=$(case_dir canon-silent)
  fakebin=$(posix_path "$dir")
  err="$dir/stderr"
  # Every expression this helper replaced discarded `cd`'s complaint, and one of
  # its callers (bin/fm-config-inherit-lib.sh) documents its stderr as concise
  # diagnostics. A lost `2>/dev/null` would put shell noise there.
  lib_eval "$fakebin" "fm_path_canon_dir '$dir/missing' >/dev/null" 2>"$err"
  [ ! -s "$err" ] || fail "a missing directory must produce no stderr, got: $(cat "$err")"
  printf 'x\n' > "$dir/afile"
  lib_eval "$fakebin" "fm_path_canon_dir '$dir/afile' >/dev/null" 2>"$err"
  [ ! -s "$err" ] || fail "a regular file must produce no stderr, got: $(cat "$err")"
  pass "path-lib: fm_path_canon_dir says nothing on stderr when it cannot answer"
}

# The mount table is the one thing a fakebin cannot model: it needs a real MSYS
# `cd`, a real `cygpath`, and a real overlapping mount. On this machine
# `C:/Users/<u>/AppData/Local/Temp` is mounted at `/tmp` AND reachable under
# `/c`, so one directory has two `pwd -P` answers depending on which spelling
# `cd` was given - and collapsing those is what fm_path_canon_dir's Windows
# branch is for. Where there is no cygpath there is no second spelling, so the
# case says what it skipped instead of passing silently.
test_canon_dir_collapses_two_mount_spellings_of_one_directory() {
  local dir fakebin target win alt canon_native canon_alt
  dir=$(case_dir canon-mount)
  if ! command -v cygpath >/dev/null 2>&1; then
    echo "note: no cygpath on this host; the mount-spelling collapse in fm_path_canon_dir was NOT checked" >&2
    pass "path-lib: fm_path_canon_dir collapses two mount spellings (skipped: no cygpath)"
    return 0
  fi
  fakebin=$(fm_fakebin "$dir")
  fm_fakebin_link "$fakebin" tr cygpath
  target="$dir/target"
  mkdir -p "$target"
  win=$(cygpath -m "$target") || fail "cygpath -m must answer for a real directory"
  # The drive-rooted spelling reduced by hand into the ALWAYS-present /<drive>
  # mount, which is the spelling a more specific mount shadows.
  alt="/$(printf '%s' "${win%%:*}" | tr '[:upper:]' '[:lower:]')${win#*:}"
  [ -d "$alt" ] || fail "the /<drive> spelling '$alt' must name the same directory"
  canon_native=$(lib_eval "$fakebin" "fm_path_canon_dir '$target'") \
    || fail "fm_path_canon_dir must answer for the native spelling"
  canon_alt=$(lib_eval "$fakebin" "fm_path_canon_dir '$alt'") \
    || fail "fm_path_canon_dir must answer for the /<drive> spelling"
  [ "$canon_native" = "$canon_alt" ] \
    || fail "one directory must canonicalize to one spelling: '$canon_native' vs '$canon_alt'"
  lib_eval "$fakebin" "fm_path_dirs_equal '$canon_native' '$canon_alt'" \
    || fail "the two canonical answers must compare equal"
  pass "path-lib: fm_path_canon_dir collapses two mount spellings of one directory"
}

test_canon_dir_refuses_what_cannot_be_entered() {
  local dir fakebin
  dir=$(case_dir canon-refuse)
  fakebin=$(posix_path "$dir")
  lib_eval "$fakebin" "fm_path_canon_dir '$dir/missing' >/dev/null" \
    && fail "a missing directory must fail"
  printf 'x\n' > "$dir/afile"
  lib_eval "$fakebin" "fm_path_canon_dir '$dir/afile' >/dev/null" \
    && fail "a regular file must fail"
  # The empty-string guard is load-bearing, not decoration: bash's `cd ""`
  # SUCCEEDS and leaves the shell where it was, so the expression this helper
  # replaces answered an empty argument with the CALLER'S current directory -
  # a plausible path that names the wrong place.
  lib_eval "$fakebin" 'fm_path_canon_dir "" >/dev/null' \
    && fail "an empty argument must fail rather than answer the current directory"
  pass "path-lib: fm_path_canon_dir fails on a missing dir, a file, and an empty argument"
}

test_canon_dir_needs_no_branch_for_a_drive_root() {
  local dir fakebin out real
  dir=$(case_dir canon-drive)
  fakebin=$(windows_path "$dir")
  mkdir -p "$dir/target"
  real=$(cd "$dir/target" && pwd -P)
  out=$(lib_eval "$fakebin" "fm_path_canon_dir '$dir/target'") \
    || fail "fm_path_canon_dir must work on a Windows userland too"
  [ "$out" = "$real" ] \
    || fail "fm_path_canon_dir must not vary with the userland: got '$out' want '$real'"
  pass "path-lib: fm_path_canon_dir answers identically on both userlands"
}

# --- fm_path_dirs_equal -----------------------------------------------------

test_dirs_equal_is_string_equality_on_posix() {
  local dir fakebin
  dir=$(case_dir equal-posix)
  fakebin=$(posix_path "$dir")
  lib_eval "$fakebin" 'fm_path_dirs_equal /a/b /a/b' \
    || fail "identical paths must compare equal"
  lib_eval "$fakebin" 'fm_path_dirs_equal /a/b /a/c' \
    && fail "different paths must not compare equal"
  # The whole POSIX contract: a filesystem that DOES distinguish case must keep
  # seeing two directories here, because it has two.
  lib_eval "$fakebin" 'fm_path_dirs_equal /a/B /a/b' \
    && fail "case must still separate two paths on a host with no cygpath"
  pass "path-lib: fm_path_dirs_equal is exactly \`=\` without cygpath"
}

test_dirs_equal_folds_case_only_on_a_windows_userland() {
  local dir fakebin
  dir=$(case_dir equal-win)
  fakebin=$(windows_path "$dir")
  lib_eval "$fakebin" 'fm_path_dirs_equal /c/Users/x /c/Users/x' \
    || fail "identical paths must compare equal on a Windows userland"
  lib_eval "$fakebin" 'fm_path_dirs_equal /c/Users/x /c/users/X' \
    || fail "two spellings of one case-insensitive path must compare equal"
  lib_eval "$fakebin" 'fm_path_dirs_equal /c/Users/x /c/Users/y' \
    && fail "genuinely different paths must not compare equal under the fold"
  pass "path-lib: fm_path_dirs_equal folds case only when cygpath is present"
}

test_dirs_equal_does_not_canonicalize_for_its_caller() {
  local dir fakebin
  dir=$(case_dir equal-nocanon)
  fakebin=$(windows_path "$dir")
  # Two namespaces for one directory are NOT reconciled here. The caller has to
  # reduce both sides through fm_path_canon_dir first; if this helper papered
  # over that, a caller that forgot would get a plausible answer instead of a
  # visible bug.
  lib_eval "$fakebin" 'fm_path_dirs_equal C:/Users/x /c/Users/x' \
    && fail "fm_path_dirs_equal must not translate namespaces for its caller"
  pass "path-lib: fm_path_dirs_equal compares, and never canonicalizes"
}

# --- fm_path_strip_dir_prefix -----------------------------------------------

test_strip_prefix_is_the_case_expression_on_posix() {
  local dir fakebin out
  dir=$(case_dir strip-posix)
  fakebin=$(posix_path "$dir")
  out=$(lib_eval "$fakebin" 'fm_path_strip_dir_prefix /top /top/a/b') \
    || fail "a path under the directory must strip"
  [ "$out" = "a/b" ] || fail "expected 'a/b', got '$out'"

  lib_eval "$fakebin" 'fm_path_strip_dir_prefix /top /top >/dev/null' \
    && fail "the directory itself is not strictly under itself and must fail"
  lib_eval "$fakebin" 'fm_path_strip_dir_prefix /top /topping/a >/dev/null' \
    && fail "a sibling sharing a textual prefix must fail"
  lib_eval "$fakebin" 'fm_path_strip_dir_prefix /top /other/a >/dev/null' \
    && fail "an unrelated path must fail"
  lib_eval "$fakebin" 'fm_path_strip_dir_prefix "" /top/a >/dev/null' \
    && fail "an empty directory must fail"
  lib_eval "$fakebin" 'fm_path_strip_dir_prefix /top "" >/dev/null' \
    && fail "an empty path must fail"
  lib_eval "$fakebin" 'fm_path_strip_dir_prefix /TOP /top/a >/dev/null' \
    && fail "case must still separate the prefix on a host with no cygpath"
  pass "path-lib: fm_path_strip_dir_prefix is exactly \`case \$p in \$d/*)\` without cygpath"
}

test_strip_prefix_folds_case_but_keeps_the_answers_case() {
  local dir fakebin out
  dir=$(case_dir strip-win)
  fakebin=$(windows_path "$dir")
  out=$(lib_eval "$fakebin" 'fm_path_strip_dir_prefix /c/Users/Top /c/users/top/Config/Keep.md') \
    || fail "a case-different prefix must strip on a Windows userland"
  # The answer goes to `git check-ignore`, so it has to be the REAL relative
  # path, not the folded one the test used.
  [ "$out" = "Config/Keep.md" ] \
    || fail "the stripped answer must keep its own case: expected 'Config/Keep.md', got '$out'"
  lib_eval "$fakebin" 'fm_path_strip_dir_prefix /c/Users/Top /c/users/topping/x >/dev/null' \
    && fail "a folded sibling prefix must still fail"
  lib_eval "$fakebin" 'fm_path_strip_dir_prefix /c/Users/Top /c/users/top >/dev/null' \
    && fail "the folded directory itself must still fail"
  pass "path-lib: fm_path_strip_dir_prefix folds only the TEST, never the answer"
}

# --- the callers' shapes ----------------------------------------------------

test_the_two_namespaces_reconcile_the_way_the_callers_use_them() {
  local dir fakebin out
  dir=$(case_dir caller-shape)
  fakebin=$(windows_path "$dir")
  mkdir -p "$dir/clone"
  # The exact shape bin/fm-fleet-sync.sh and bin/fm-config-inherit-lib.sh now
  # use: reduce BOTH sides with fm_path_canon_dir, then compare. Faked here with
  # two spellings that differ only in case, which is the part of the Windows
  # difference reproducible on any filesystem.
  out=$(lib_eval "$fakebin" "
    a=\$(fm_path_canon_dir '$dir/clone') || exit 1
    b=\$(fm_path_canon_dir '$dir/clone') || exit 1
    b=\$(printf '%s' \"\$b\" | tr '[:lower:]' '[:upper:]')
    fm_path_dirs_equal \"\$a\" \"\$b\" && echo same || echo different
  ") || fail "the caller shape must run"
  [ "$out" = "same" ] \
    || fail "canon-then-compare must reconcile two spellings of one directory, got '$out'"
  pass "path-lib: canon-then-compare is what reconciles two spellings of one directory"
}

test_is_absolute_matches_gits_two_answer_shapes() {
  local dir fakebin
  dir=$(case_dir git-shapes)
  fakebin=$(windows_path "$dir")
  # `git rev-parse --git-path index.lock` answers relatively in a plain clone
  # and absolutely in a linked worktree; bin/fm-teardown.sh and
  # bin/fm-fleet-sync.sh join the first onto a directory and must not join the
  # second. On Windows the absolute answer is drive-rooted.
  lib_eval "$fakebin" 'fm_path_is_absolute .git/index.lock' \
    && fail "git's plain-clone answer must be treated as relative"
  lib_eval "$fakebin" 'fm_path_is_absolute C:/repo/.git/worktrees/w/index.lock' \
    || fail "git's linked-worktree answer on Windows must be treated as absolute"
  lib_eval "$fakebin" 'fm_path_is_absolute /repo/.git/worktrees/w/index.lock' \
    || fail "git's linked-worktree answer on POSIX must be treated as absolute"
  pass "path-lib: fm_path_is_absolute classifies both of git's --git-path answer shapes"
}

test_is_absolute_is_the_slash_test_on_posix
test_is_absolute_accepts_a_drive_root_on_a_windows_userland
test_canon_dir_is_cd_then_pwd_p
test_canon_dir_refuses_what_cannot_be_entered
test_canon_dir_is_silent_when_it_fails
test_canon_dir_collapses_two_mount_spellings_of_one_directory
test_canon_dir_needs_no_branch_for_a_drive_root
test_dirs_equal_is_string_equality_on_posix
test_dirs_equal_folds_case_only_on_a_windows_userland
test_dirs_equal_does_not_canonicalize_for_its_caller
test_strip_prefix_is_the_case_expression_on_posix
test_strip_prefix_folds_case_but_keeps_the_answers_case
test_the_two_namespaces_reconcile_the_way_the_callers_use_them
test_is_absolute_matches_gits_two_answer_shapes
