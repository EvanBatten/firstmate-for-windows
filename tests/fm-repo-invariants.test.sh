#!/usr/bin/env bash
# Repository invariants: spellings that belong to one owner.
#
# Each invariant runs three steps, in this order, and the order is the point:
#  1. the pattern must find known instances - the owner's own lines, and literal
#     lines in every shape the repository really writes - so a pattern that
#     cannot match fails here instead of passing over the whole tree;
#  2. every allowlist entry must still match a line, so an exception cannot
#     outlive its reason;
#  3. only then must nothing else match, and every offender is printed.
# Step 1 exists because an extractor in this repository once used `[^"]*`,
# which cannot cross the embedded quotes of the dominant spelling, so it matched
# nothing and passed for months.
#
# Allowlist entries are "<path> <line content>", content trimmed, matched
# exactly and once per entry: a second copy of an allowed line is an offender.
# Full-line comments are never scanned, since a comment that names a spelling is
# documentation, not a call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "$ROOT" || fail "cannot enter the repository root $ROOT"

# This file spells both patterns' shapes as literals, so the digest scan skips
# it by its own name, which also holds for a scratch copy of it.
SELF=tests/$(basename "${BASH_SOURCE[0]}")

# The `ps -o` field form. MSYS `ps` has no -o, so every such spelling reads
# empty on Windows; bin/fm-proc-lib.sh owns the capability-gated answer.
# Matched on the field keyword rather than on `ps`, because live spellings name
# the binary through a variable (`"$ps_bin" -p "$pid" -o stat=`), and on any
# bundled flag ending in o (`-axo`, `-eo`). The keyword list is what keeps
# `--command=*)` and `grep -Eo 'corr=` out.
PS_FIELDS='comm|args|command|cmd|ucomm|ppid|pgid|tpgid|pid|sess|lstart|etimes?|time|stat|state|user|uid|tty|rss|vsz|nice|%cpu|%mem'
PS_FIELD_FORM="(^|[^-[:alnum:]_])-[A-Za-z]*o[[:space:]]*[\"']?($PS_FIELDS)([=,[:space:]\"']|\$)"

# A digest tool in command position, a `command -v` probe for one, or one
# assigned to a variable. A mention in a message, a stub's file name or an
# argument is not a digest, which is why the bare word is not the pattern.
DIGEST_CALL='(^|[;&|`{]|\$\(|(^|[[:space:]])(if|then|do|else|elif|while|until|exec|time|xargs|!|command[[:space:]]+-v)[[:space:]])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(shasum|sha256sum)([[:space:]]|$|\)|;)|=(shasum|sha256sum)([[:space:]]|$|;)'

# invariant_lines <ere> <file>...: "<path> <trimmed content>" for every
# non-comment line matching <ere>.
invariant_lines() {
  local ere=$1
  shift
  [ "$#" -gt 0 ] || return 0
  grep -nHE -- "$ere" "$@" 2>/dev/null | awk '
    {
      i = index($0, ":"); path = substr($0, 1, i - 1); rest = substr($0, i + 1)
      j = index(rest, ":"); content = substr(rest, j + 1)
      sub(/\r$/, "", content); sub(/^[[:space:]]+/, "", content); sub(/[[:space:]]+$/, "", content)
      if (content ~ /^#/) next
      print path " " content
    }'
}

PROBE=$(fm_test_tmproot fm-repo-invariants)/probe.sh

# has_line <found> <line>: <line> is one whole line of <found>, without a fork.
has_line() {
  case $'\n'"$1"$'\n' in
    *$'\n'"$2"$'\n'*) return 0 ;;
  esac
  return 1
}

# expect_shapes <name> <ere> <must|never> <line>...: the lines, written to one
# probe file and fed through the same extractor the tree scan uses, all match
# (must) or none does (never).
expect_shapes() {
  local name=$1 ere=$2 want=$3 line found
  shift 3
  printf '%s\n' "$@" > "$PROBE"
  found=$(invariant_lines "$ere" "$PROBE")
  for line in "$@"; do
    if has_line "$found" "$PROBE $line"; then
      [ "$want" = must ] || fail "$name pattern matches a line that is not the spelling: $line"
    else
      [ "$want" = never ] || fail "$name pattern cannot match a shape the repository writes: $line"
    fi
  done
}

# expect_owner_lines <name> <ere> <file> <line>...: each exact content line is
# found in <file> by the tree extractor.
expect_owner_lines() {
  local name=$1 ere=$2 file=$3 found line
  shift 3
  found=$(invariant_lines "$ere" "$file")
  [ -n "$found" ] || fail "$name pattern finds nothing in its owner $file; the invariant is broken, not the tree"
  for line in "$@"; do
    has_line "$found" "$file $line" \
      || fail "$name pattern does not find the owner's known line in $file: $line"$'\n'"found:"$'\n'"$found"
  done
}

# stale_entries <allowlist> <found>: allowlist entries with no line left to match.
stale_entries() {
  awk '
    NR == FNR { if ($0 == "" || $0 ~ /^#/) next; want[++n] = $0; next }
    { have[$0]++ }
    END { for (i = 1; i <= n; i++) { k = want[i]; if (have[k] > 0) have[k]--; else print k } }
  ' <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}

# unlisted_lines <allowlist> <found>: found lines no allowlist entry accounts for.
unlisted_lines() {
  awk '
    NR == FNR { if ($0 == "" || $0 ~ /^#/) next; allow[$0]++; next }
    $0 == "" { next }
    { if (allow[$0] > 0) allow[$0]--; else print }
  ' <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}

# tree_lines <ere> <dir> <exclude>...: invariant_lines over every *.sh under
# <dir>, minus the excluded paths.
tree_lines() {
  local ere=$1 dir=$2 path
  local -a files=()
  shift 2
  while IFS= read -r path; do
    files+=("$path")
  done < <(tree_files "$dir" "$@")
  invariant_lines "$ere" "${files[@]}"
}

# tree_files <dir> <exclude>...: every *.sh under <dir>, sorted, minus the
# excluded paths.
tree_files() {
  local dir=$1 path skip excluded
  shift
  while IFS= read -r path; do
    skip=0
    for excluded in "$@"; do
      [ "$path" != "$excluded" ] || skip=1
    done
    [ "$skip" -eq 1 ] || printf '%s\n' "$path"
  done < <(find "$dir" -type f -name '*.sh' | LC_ALL=C sort)
}

PS_OWNER=bin/fm-proc-lib.sh

PS_ALLOWLIST=$(cat <<'EOF'
# The process-identity owner's fallback for a host with no /proc/<pid>/stat;
# MSYS publishes that file, so Windows takes the /proc branch above it.
bin/fm-wake-lib.sh out=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
bin/fm-wake-lib.sh out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
# The cmux ancestor walk; the cmux backend is macOS-only.
bin/fm-backend.sh comm=$(ps -o comm= -p "$pid" 2>/dev/null) || comm=""
bin/fm-backend.sh ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
# A daemon lock that predates the recorded pid identity; an empty answer is no
# match, which is the safe branch.
bin/fm-afk-start.sh command=$(ps -p "$pid" -o command= 2>/dev/null || true)
# argv[0] after /proc/<pid>/cmdline, which MSYS answers first.
bin/fm-cursor-lib.sh fallback=$(LC_ALL=C ps -p "$pid" -o comm= 2>/dev/null || true)
# A system-load probe, not an identity; it fails open to zero.
bin/fm-lint.sh ps -A -o %cpu= 2>/dev/null | awk '{sum += $1} END {printf "%.2f", sum + 0}'
# The remote-host orphan reaper, POSIX by decision (no Windows-hosted remote);
# the scan dies loudly where -o is refused, before the walk is ever reached.
bin/fm-remote-job-reap-orphans.sh walk=$(ps -p "$walk" -o ppid= 2>/dev/null | tr -d '[:space:]') || return 0
bin/fm-remote-job-reap-orphans.sh scan=$(ps -u "$uid" -o pid=,command= 2>/dev/null) ||
# tmux foreground process groups by pane tty; tmux panes only, and a tty or
# process group has no MSYS meaning.
bin/backends/tmux.sh LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
bin/backends/tmux.sh LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \
bin/backends/tmux.sh args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || continue
bin/fm-tmux-lib.sh $(LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null)
bin/fm-tmux-lib.sh $(LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null)
bin/fm-tmux-lib.sh args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || args=
# The leaked process-group reap, which returns before this for any backend but
# tmux.
bin/fm-teardown.sh pgid=$(ps -o pgid= -p "$leader" 2>/dev/null) || pgid=""
bin/fm-teardown.sh own_pgid=$(ps -o pgid= -p "$$" 2>/dev/null) || own_pgid=""
bin/fm-teardown.sh current_pgid=$(ps -o pgid= -p "$leader" 2>/dev/null) || current_pgid=""
bin/fm-teardown.sh && [ "$(ps -o pgid= -p "$leader" 2>/dev/null | tr -d '[:space:]')" = "$pgid" ] \
# NOT legitimate: a known open Windows defect, listed so this invariant can land
# while it stays visible. herdr is the Windows backend, and on MSYS the idle-shell
# proof refuses every pane, so a close never proves a shell idle and takes the
# plain path (docs/windows/measurement.md, "The herdr idle-shell proof is not
# the gate that fails"). The proof also needs a process-table listing and a
# process state, which bin/fm-proc-lib.sh does not own yet. Delete these three
# when the proof is ported; this test then fails until they are removed.
bin/backends/herdr.sh comm=$("$1" -p "$2" -o comm= 2>/dev/null) || return 1
bin/backends/herdr.sh rows=$("$ps_bin" -axo pid=,ppid= 2>/dev/null) || return 1
bin/backends/herdr.sh stat=$("$ps_bin" -p "$shell_pid" -o stat= 2>/dev/null | tr -d '[:space:]') || return 1
EOF
)

DIGEST_OWNER=tests/lib.sh

DIGEST_ALLOWLIST=$(cat <<'EOF'
# The helper's own suite proves each tool's branch with the other masked, so it
# must ask whether each tool exists before claiming that branch is proven.
tests/fm-test-lib.test.sh command -v sha256sum >/dev/null 2>&1 || {
tests/fm-test-lib.test.sh command -v shasum >/dev/null 2>&1 || {
EOF
)

# shellcheck disable=SC2016,SC1003  # the shapes are literal source lines, never expanded
test_process_listing_pattern_bites() {
  expect_owner_lines "process-listing" "$PS_FIELD_FORM" "$PS_OWNER" \
    'if [ "$FM_PROC_OS" = msys ] && LC_ALL=C ps -o comm= -p $$ >/dev/null 2>&1; then' \
    'ps -o comm= -p "$1" 2>/dev/null' \
    'ps -o args= -p "$1" 2>/dev/null' \
    "ps -o ppid= -p \"\$1\" 2>/dev/null | tr -d '[:space:]'" \
    "ps -o pgid= -p \"\$pid\" 2>/dev/null | tr -d '[:space:]'"
  expect_shapes "process-listing" "$PS_FIELD_FORM" must \
    'comm=$("$1" -p "$2" -o comm= 2>/dev/null) || return 1' \
    'out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1' \
    'rows=$("$ps_bin" -axo pid=,ppid= 2>/dev/null) || return 1' \
    'stat=$("$ps_bin" -p "$shell_pid" -o stat= 2>/dev/null)' \
    'LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null \' \
    'ps -A -o %cpu= 2>/dev/null' \
    'ps -o "comm=" -p "$pid"' \
    'ps -eo pid,comm' \
    'ps -o comm -p "$pid"'
  expect_shapes "process-listing" "$PS_FIELD_FORM" never \
    '--command=*)' \
    "done < <(grep -Eo 'corr=[A-Fa-f0-9]{16}' \"\$payload\")" \
    'git log --format=%H HEAD --not --remotes' \
    'echo "exit-command=delivered agent-state=$state"' \
    'sort -o "$out" "$in"'
  pass "the process-listing pattern finds its owner's spellings and every shape bin/ writes"
}

test_process_listing_allowlist_is_live() {
  local found stale
  found=$(tree_lines "$PS_FIELD_FORM" bin "$PS_OWNER")
  stale=$(stale_entries "$PS_ALLOWLIST" "$found")
  [ -z "$stale" ] || fail "process-listing allowlist entries match no line in bin/ any more; remove them:"$'\n'"$stale"
  pass "every process-listing allowlist entry still matches its line"
}

test_no_process_listing_outside_its_owner() {
  local found unlisted
  found=$(tree_lines "$PS_FIELD_FORM" bin "$PS_OWNER")
  unlisted=$(unlisted_lines "$PS_ALLOWLIST" "$found")
  [ -z "$unlisted" ] || fail "bin/ spells the ps -o field form outside $PS_OWNER; MSYS ps has no -o, so use fm_proc_* there:"$'\n'"$unlisted"
  pass "no file under bin/ spells the ps -o field form outside $PS_OWNER and the allowlist"
}

# shellcheck disable=SC2016  # the shapes are literal source lines, never expanded
test_digest_pattern_bites() {
  expect_owner_lines "digest" "$DIGEST_CALL" "$DIGEST_OWNER" \
    'if command -v sha256sum >/dev/null 2>&1; then' \
    "digest=\$(sha256sum | awk '{print \$1}')" \
    "digest=\$(shasum -a 256 | awk '{print \$1}')"
  expect_shapes "digest" "$DIGEST_CALL" must \
    "printf '%s' \"\$real\" | shasum -a 256 | awk '{print substr(\$1,1,8)}'" \
    "before=\$(shasum -a 256 \"\$home/data/backlog.md\" | awk '{print \$1}')" \
    '[ "$(shasum -a 256 "$state/domain.meta")" = "$meta_before" ] || fail "retirement changed metadata"' \
    "shasum -a 256 \"\$file\" | awk '{print \$1}'" \
    'elif command -v sha256sum >/dev/null 2>&1; then' \
    'LC_ALL=C sha256sum "$file"' \
    'hasher=sha256sum'
  expect_shapes "digest" "$DIGEST_CALL" never \
    'fm_install_stub_hasher "$fakebin" shasum' \
    "printf '#!/usr/bin/env bash\\nexit 1\\n' > \"\$fakebin/shasum\"" \
    "assert_grep 'shasum -a 256' \"\$hasher_log\" \"installer did not invoke shasum -a 256\"" \
    'pass "digests with sha256sum alone (shasum proven unreachable)"' \
    'if [ "$self" = shasum ]; then'
  pass "the digest pattern finds the helper's spellings and every call shape tests have used"
}

test_digest_allowlist_is_live() {
  local found stale
  found=$(tree_lines "$DIGEST_CALL" tests "$DIGEST_OWNER" "$SELF")
  stale=$(stale_entries "$DIGEST_ALLOWLIST" "$found")
  [ -z "$stale" ] || fail "digest allowlist entries match no line in tests/ any more; remove them:"$'\n'"$stale"
  pass "every digest allowlist entry still matches its line"
}

test_no_digest_outside_the_helper() {
  local found unlisted
  found=$(tree_lines "$DIGEST_CALL" tests "$DIGEST_OWNER" "$SELF")
  unlisted=$(unlisted_lines "$DIGEST_ALLOWLIST" "$found")
  [ -z "$unlisted" ] || fail "tests/ takes a digest outside $DIGEST_OWNER; use fm_test_sha256 or fm_test_sha256_stdin:"$'\n'"$unlisted"
  pass "no test takes a digest outside fm_test_sha256 and the allowlist"
}

test_process_listing_pattern_bites
test_process_listing_allowlist_is_live
test_no_process_listing_outside_its_owner
test_digest_pattern_bites
test_digest_allowlist_is_live
test_no_digest_outside_the_helper
