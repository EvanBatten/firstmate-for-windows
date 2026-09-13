#!/usr/bin/env bash
# Behavioral tests for bin/fm-repo-invariants.sh, driven against fixture trees.
#
# Every case writes a small tree with both owners in place and runs the script
# with --root on it, so each assertion is the script's verdict on bytes this
# file wrote, never on the tracked tree. The shapes below are the spellings the
# repository has really written, so a pattern that stops matching one of them,
# or starts matching a lookalike, fails here.
#
# The digest tool names and the directive prefix are spliced in from @TOKENS@
# rather than spelled on this file's own lines: this file lives under tests/,
# which the digest invariant scans, and a literal spelling or directive here
# would be a finding, or a dead directive, in the real tree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INVARIANTS="$ROOT/bin/fm-repo-invariants.sh"
TMP_ROOT=$(fm_test_tmproot fm-repo-invariants)

SHASUM=sha"sum"
SHA256SUM=sha256"sum"
ALLOW="# fm-invariant: allow"

# fixture <root> <path>: stdin written to <root>/<path>, with @SHA256SUM@,
# @SHASUM@ and @ALLOW@ replaced by the spellings this file must not carry.
fixture() {
  local file="$1/$2" content
  mkdir -p "${file%/*}"
  content=$(cat)
  content=${content//@SHA256SUM@/$SHA256SUM}
  content=${content//@SHASUM@/$SHASUM}
  content=${content//@ALLOW@/$ALLOW}
  printf '%s\n' "$content" > "$file"
}

# new_tree <name>: a fresh tree holding both owners with their real spellings,
# which on its own satisfies every invariant.
# shellcheck disable=SC2016  # fixture lines are literal source, never expanded
new_tree() {
  local tree="$TMP_ROOT/$1"
  fixture "$tree" bin/fm-proc-lib.sh <<'SH'
if [ "$FM_PROC_OS" = msys ] && LC_ALL=C ps -o comm= -p $$ >/dev/null 2>&1; then
  ps -o comm= -p "$1" 2>/dev/null
fi
SH
  fixture "$tree" tests/lib.sh <<'SH'
if command -v @SHA256SUM@ >/dev/null 2>&1; then
  digest=$(@SHA256SUM@ | awk '{print $1}')
fi
SH
  printf '%s\n' "$tree"
}

# run_invariants <tree>: the script's output in OUT and its status in RC.
run_invariants() {
  RC=0
  OUT=$("$INVARIANTS" --root "$1" 2>&1) || RC=$?
}

# expect_every_line_named <path> <line-count>: the last run failed and named
# each of lines 1..<line-count> of <path>, and nothing else.
expect_every_line_named() {
  local path=$1 count=$2 n=1 named
  [ "$RC" -eq 1 ] || fail "expected the invariants to fail on $path, got $RC:"$'\n'"$OUT"
  while [ "$n" -le "$count" ]; do
    case "$OUT" in
      *"  $path:$n: "*) ;;
      *) fail "line $n of $path is a shape the repository writes, but was not named:"$'\n'"$OUT" ;;
    esac
    n=$((n + 1))
  done
  named=$(printf '%s\n' "$OUT" | grep -c '^  ')
  [ "$named" -eq "$count" ] || fail "expected exactly $count findings in $path, got $named:"$'\n'"$OUT"
}

test_a_tree_that_keeps_each_spelling_with_its_owner_holds() {
  local tree
  tree=$(new_tree clean)
  run_invariants "$tree"
  [ "$RC" -eq 0 ] || fail "a tree whose spellings stay in their owners must hold, got $RC:"$'\n'"$OUT"
  assert_contains "$OUT" "hold" "a holding run must say so"
  pass "a tree that keeps each spelling in its owner holds"
}

# shellcheck disable=SC2016  # fixture lines are literal source, never expanded
test_every_process_listing_shape_outside_the_owner_is_named() {
  local tree
  tree=$(new_tree ps-shapes)
  fixture "$tree" bin/backends/shapes.sh <<'SH'
if [ "$FM_PROC_OS" = msys ] && LC_ALL=C ps -o comm= -p $$ >/dev/null 2>&1; then
ps -o comm= -p "$1" 2>/dev/null
ps -o args= -p "$1" 2>/dev/null
ps -o ppid= -p "$1" 2>/dev/null | tr -d '[:space:]'
ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]'
comm=$("$1" -p "$2" -o comm= 2>/dev/null) || return 1
out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
rows=$("$ps_bin" -axo pid=,ppid= 2>/dev/null) || return 1
stat=$("$ps_bin" -p "$shell_pid" -o stat= 2>/dev/null)
LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
ps -A -o %cpu= 2>/dev/null
ps -o "comm=" -p "$pid"
ps -eo pid,comm
ps -o comm -p "$pid"
SH
  run_invariants "$tree"
  expect_every_line_named bin/backends/shapes.sh 14
  assert_contains "$OUT" "ps-o:" "the failing invariant must name itself"
  pass "every ps field form bin/ has written is named outside bin/fm-proc-lib.sh, nested directories included"
}

# shellcheck disable=SC2016  # fixture lines are literal source, never expanded
test_every_digest_shape_outside_the_helper_is_named() {
  local tree
  tree=$(new_tree digest-shapes)
  fixture "$tree" tests/shapes.test.sh <<'SH'
if command -v @SHA256SUM@ >/dev/null 2>&1; then
digest=$(@SHA256SUM@ | awk '{print $1}')
digest=$(@SHASUM@ -a 256 | awk '{print $1}')
printf '%s' "$real" | @SHASUM@ -a 256 | awk '{print substr($1,1,8)}'
before=$(@SHASUM@ -a 256 "$home/data/backlog.md" | awk '{print $1}')
[ "$(@SHASUM@ -a 256 "$state/domain.meta")" = "$meta_before" ] || fail "retirement changed metadata"
@SHASUM@ -a 256 "$file" | awk '{print $1}'
elif command -v @SHA256SUM@ >/dev/null 2>&1; then
LC_ALL=C @SHA256SUM@ "$file"
hasher=@SHA256SUM@
SH
  run_invariants "$tree"
  expect_every_line_named tests/shapes.test.sh 10
  assert_contains "$OUT" "digest:" "the failing invariant must name itself"
  pass "every digest call shape tests have used is named outside tests/lib.sh"
}

# shellcheck disable=SC2016  # fixture lines are literal source, never expanded
test_lookalikes_and_comments_are_not_findings() {
  local tree
  tree=$(new_tree lookalikes)
  fixture "$tree" bin/lookalike.sh <<'SH'
--command=*)
done < <(grep -Eo 'corr=[A-Fa-f0-9]{16}' "$payload")
git log --format=%H HEAD --not --remotes
echo "exit-command=delivered agent-state=$state"
sort -o "$out" "$in"
# A comment naming `ps -o comm= -p "$pid"` is documentation, not a call.
SH
  fixture "$tree" tests/lookalike.test.sh <<'SH'
fm_install_stub_hasher "$fakebin" @SHASUM@
printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/@SHASUM@"
assert_grep '@SHASUM@ -a 256' "$hasher_log" "installer did not invoke @SHASUM@ -a 256"
pass "digests with @SHA256SUM@ alone (@SHASUM@ proven unreachable)"
if [ "$self" = @SHASUM@ ]; then
  # before=$(@SHASUM@ -a 256 "$file") is how this used to read.
SH
  run_invariants "$tree"
  [ "$RC" -eq 0 ] || fail "lookalikes and comments must not be findings, got $RC:"$'\n'"$OUT"
  pass "a mention, a stub name, an argument or a comment is not a spelling"
}

# shellcheck disable=SC2016  # fixture lines are literal source, never expanded
test_a_directive_allows_only_the_line_directly_below_it() {
  local tree
  tree=$(new_tree allowed)
  fixture "$tree" bin/allowed.sh <<'SH'
walk() {
  @ALLOW@ ps-o - the remote-host reaper is POSIX by decision
  walk=$(ps -p "$walk" -o ppid= 2>/dev/null | tr -d '[:space:]') || return 0
  walk=$(ps -p "$walk" -o ppid= 2>/dev/null | tr -d '[:space:]') || return 0
}
SH
  fixture "$tree" tests/allowed.test.sh <<'SH'
  @ALLOW@ digest - proves this tool's branch with the other masked
  command -v @SHASUM@ >/dev/null 2>&1 || return 0
SH
  run_invariants "$tree"
  [ "$RC" -eq 1 ] || fail "the undirected copy of an allowed line must still fail, got $RC:"$'\n'"$OUT"
  case "$OUT" in
    *"  bin/allowed.sh:4: "*) ;;
    *) fail "the second copy, with no directive above it, was not named:"$'\n'"$OUT" ;;
  esac
  case "$OUT" in
    *"bin/allowed.sh:3:"*|*"tests/allowed.test.sh"*) fail "a directed line was named:"$'\n'"$OUT" ;;
  esac
  pass "a directive allows the one line directly below it, and a copy without one is still named"
}

# shellcheck disable=SC2016  # fixture lines are literal source, never expanded
test_a_dead_directive_fails() {
  local tree
  tree=$(new_tree dead)
  fixture "$tree" bin/dead.sh <<'SH'
@ALLOW@ ps-o - the line this excused was ported
pid=$(fm_proc_ppid "$pid")
@ALLOW@ ps-o - a blank line breaks the adjacency

comm=$(ps -o comm= -p "$pid" 2>/dev/null)
SH
  run_invariants "$tree"
  [ "$RC" -eq 1 ] || fail "a directive with no spelling below it must fail, got $RC:"$'\n'"$OUT"
  case "$OUT" in
    *"  bin/dead.sh:1: dead directive"*) ;;
    *) fail "the directive above a ported line was not reported dead:"$'\n'"$OUT" ;;
  esac
  case "$OUT" in
    *"  bin/dead.sh:3: dead directive"*) ;;
    *) fail "a directive separated from its line was not reported dead:"$'\n'"$OUT" ;;
  esac
  case "$OUT" in
    *"  bin/dead.sh:5: comm="*) ;;
    *) fail "a spelling whose directive is not directly above it was not named:"$'\n'"$OUT" ;;
  esac
  pass "a directive whose next line is not a spelling fails, so an exception cannot outlive its reason"
}

# shellcheck disable=SC2016  # fixture lines are literal source, never expanded
test_a_malformed_or_misnamed_directive_fails() {
  local tree
  tree=$(new_tree malformed)
  fixture "$tree" bin/malformed.sh <<'SH'
@ALLOW@ ps-o
comm=$(ps -o comm= -p "$pid" 2>/dev/null)
@ALLOW@ digest - names the wrong invariant for bin/
args=$(ps -o args= -p "$pid" 2>/dev/null)
SH
  run_invariants "$tree"
  [ "$RC" -eq 1 ] || fail "malformed and misnamed directives must fail, got $RC:"$'\n'"$OUT"
  case "$OUT" in
    *"  bin/malformed.sh:1: malformed directive"*) ;;
    *) fail "a directive with no reason was not reported malformed:"$'\n'"$OUT" ;;
  esac
  case "$OUT" in
    *"  bin/malformed.sh:3: directive names \"digest\""*) ;;
    *) fail "a directive naming another directory's invariant was not reported:"$'\n'"$OUT" ;;
  esac
  case "$OUT" in
    *"  bin/malformed.sh:2: "*"  bin/malformed.sh:4: "*) ;;
    *) fail "lines under directives that allow nothing must still be named:"$'\n'"$OUT" ;;
  esac
  pass "a directive with no reason, or naming the wrong invariant, fails and allows nothing"
}

test_an_owner_the_pattern_cannot_match_fails() {
  local tree
  tree=$(new_tree blind-owner)
  # shellcheck disable=SC2016  # a literal source line, never expanded
  printf '%s\n' 'pgid=$(fm_proc_pgid "$pid")' > "$tree/bin/fm-proc-lib.sh"
  run_invariants "$tree"
  [ "$RC" -eq 1 ] || fail "an owner with no match must fail the invariant, got $RC:"$'\n'"$OUT"
  assert_contains "$OUT" "ps-o: the pattern finds nothing in its owner bin/fm-proc-lib.sh" \
    "a blind pattern must be reported as a broken invariant"
  tree=$(new_tree missing-owner)
  rm -f "$tree/tests/lib.sh"
  run_invariants "$tree"
  [ "$RC" -eq 1 ] || fail "a missing owner must fail the invariant, got $RC:"$'\n'"$OUT"
  assert_contains "$OUT" "digest: its owner tests/lib.sh does not exist" "a missing owner must be named"
  pass "an owner the pattern cannot match, or no owner at all, fails instead of passing over the tree"
}

test_a_tree_that_keeps_each_spelling_with_its_owner_holds
test_every_process_listing_shape_outside_the_owner_is_named
test_every_digest_shape_outside_the_helper_is_named
test_lookalikes_and_comments_are_not_findings
test_a_directive_allows_only_the_line_directly_below_it
test_a_dead_directive_fails
test_a_malformed_or_misnamed_directive_fails
test_an_owner_the_pattern_cannot_match_fails
