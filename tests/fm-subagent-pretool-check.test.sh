#!/usr/bin/env bash
# Behavior tests for the primary-session delegation-shape guard: the tracked
# hook registration, shared settings boundary, and PreToolUse classifier.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-subagent-pretool-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-subagent-pretool-tests)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$PRIMARY/bin" "$STATE"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q

# The guard reads user and plugin skills from the Claude config directory, so
# every case runs against a fixture one rather than the host's real skills.
CLAUDE_CFG="$TMP_ROOT/claude-config"
mkdir -p "$CLAUDE_CFG"
export CLAUDE_CONFIG_DIR="$CLAUDE_CFG"

DISPATCH_ROUTE='first classify the work under the AGENTS.md intake contract, then use bin/fm-brief.sh followed by bin/fm-spawn.sh for dispatched work, passing --scout to both for a scout'

# Every delegation, scheduling, worktree, and task-tracking tool Claude Code
# 2.1.217 offered a primary session in the observed baseline.
# This inventory is shape-classification coverage for the shipped guard and the
# recommended local Claude deny-list hardening list, but tracked settings must
# not ship that Claude-only permissions layer.
DELEGATION_TOOLS='Task Agent Workflow RemoteTrigger Monitor ScheduleWakeup SendMessage EnterWorktree ExitWorktree CronCreate CronDelete CronList TaskCreate TaskGet TaskList TaskUpdate TaskStop TaskOutput'

# Tools that must stay available: denying these would break ordinary work.
PRESERVED_TOOLS='Bash Edit Read Write Skill ToolSearch WebFetch WebSearch NotebookEdit ReportFindings DesignSync PushNotification'

# Session-local todo-list tools. They match a delegation stem but create no
# runnable work, so the guard's plan-only exclusion must allow them.
PLAN_ONLY_TOOLS='TaskCreate TaskUpdate'

# Names the plan-only exclusion must NOT release. Five of them contain a
# plan-only name as a substring and would be let through by a substring rather
# than exact-name match; bare Task is what a shortened entry of "task" would
# release. Together they make the exact-name contract testable instead of
# assumed.
PLAN_ONLY_NEAR_MISSES='TaskCreateAgent TaskCreateWorktree TaskUpdateAgent RemoteTaskCreate Task TaskCreator'

run_tool() {
  local tool=$1 rc=0
  shift
  : > "$OUT"
  : > "$ERR"
  env FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" "$@" \
    "$CHECK" --claude --tool "$tool" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

expect_allow() {
  local label=$1 tool=$2 rc=0
  shift 2
  run_tool "$tool" "$@" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label ($tool) must allow, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$label ($tool) allow wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label ($tool) allow wrote stderr: $(cat "$ERR")"
}

expect_deny() {
  local label=$1 tool=$2 rc=0
  run_tool "$tool" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label ($tool) must deny with exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "$label ($tool) deny wrote stdout: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "$label ($tool) deny omitted Claude's permission decision: $(cat "$ERR")"
  jq -e --arg tool "$tool" '.systemMessage | startswith("[subagent-dispatch]") and contains("blocked tool: " + $tool)' "$ERR" >/dev/null 2>&1 \
    || fail "$label ($tool) deny message lost its code or tool name: $(jq -r '.systemMessage' "$ERR")"
}

# Writes a skill or command file whose frontmatter holds the given lines.
write_skill() {  # <path> <frontmatter-line>...
  local path=$1
  shift
  mkdir -p "${path%/*}"
  { printf -- '---\n'; printf '%s\n' "$@"; printf -- '---\nUse the Bash tool to run: echo probe\n'; } > "$path"
}

run_skill() {  # <skill-as-the-Skill-tool-receives-it> [env-args...]
  local skill=$1 rc=0
  shift
  : > "$OUT"
  : > "$ERR"
  # printf rather than jq --arg: MSYS rewrites a /name argument into a path.
  printf '{"tool_name":"Skill","tool_input":{"skill":"%s"}}' "$skill" \
    | env "$@" FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

# ---------------------------------------------------------------------------
# Delegation-shape PreToolUse guard.
# ---------------------------------------------------------------------------

test_guard_denies_every_currently_known_delegation_tool() {
  local tool
  for tool in $DELEGATION_TOOLS; do
    case "$tool" in
      TaskOutput|TaskStop|TaskGet|TaskList|CronList) continue ;;
      TaskCreate|TaskUpdate) continue ;;
    esac
    expect_deny "known delegation tool" "$tool"
  done
  pass "the guard independently denies every work-creating delegation tool by shape"
}

test_guard_denies_hypothetical_future_tools() {
  # A fixed deny list is fail-open against tools that do not exist yet.
  # None of these names is on any list.
  local tool
  for tool in SubagentCreate SpawnWorker DelegateTask AgentPool WorkflowRun \
              ScheduleJob CronSchedule CreateWorktree DispatchAgent TaskHandoff \
              RemoteExec BackgroundAgent; do
    expect_deny "future delegation tool" "$tool"
  done
  pass "the guard denies delegation-shaped tools that no deny list knows about yet"
}

test_guard_allows_ordinary_and_observe_only_tools() {
  local tool
  for tool in $PRESERVED_TOOLS; do
    expect_allow "ordinary tool" "$tool"
  done
  # Observing or stopping work that already exists is not creating unaccounted
  # work, and blocking it would strand a runaway task with no way to end it.
  for tool in TaskOutput TaskStop TaskGet TaskList CronList BashOutput KillShell; do
    expect_allow "observe-or-stop tool" "$tool"
  done
  pass "the guard leaves ordinary tools and observe-or-stop operations alone"
}

test_guard_allows_session_local_todo_tools() {
  # These write, so they are not observe-or-stop, but what they write is the
  # harness's session-local todo list: no executor, no agent, no worktree, no
  # schedule, nothing that outlives the session. Denying them stops the primary
  # tracking its own plan and grants no delegation power in exchange.
  local tool
  for tool in $PLAN_ONLY_TOOLS; do
    expect_allow "session-local todo tool" "$tool"
  done
  pass "the guard leaves the session-local todo list alone"
}

test_plan_only_exclusion_is_exact_name() {
  # The plan-only exclusion must never widen by substring or by a shorter stem.
  # Every name here would be released by such a widening and must stay denied.
  local tool
  for tool in $PLAN_ONLY_NEAR_MISSES; do
    expect_deny "plan-only near miss" "$tool"
  done
  pass "the plan-only exclusion releases exactly two names and nothing that merely contains them"
}

test_guard_never_classifies_mcp_tools() {
  # An MCP server names its own tools, so a name says nothing reliable about
  # what the tool does. mcp__cc__Agent and mcp__cc__Workflow are the names
  # `claude mcp serve` gives tools that were measured starting agents; they stay
  # allowed on purpose (docs/subagent-guard.md "MCP tools").
  local tool
  for tool in mcp__linear__list_issues mcp__tracker__create_task \
              mcp__acme__spawn_agent mcp__slack__slack_send_message \
              mcp__cc__Agent mcp__cc__Workflow; do
    expect_allow "MCP tool" "$tool"
  done
  pass "MCP tool names are never classified as harness delegation"
}

test_guard_allows_retired_claude_tool_names() {
  # Claude Code 2.1.287 through 2.1.292 keep these names only in their
  # removed-tool set and offer no tool by them, so nothing can call them
  # (docs/subagent-guard.md "Retired Claude tool names").
  local tool
  for tool in TeamCreate TeamDelete SuggestBackgroundPR AutofixPr; do
    expect_allow "retired Claude tool name" "$tool"
  done
  pass "retired Claude tool names stay unclassified because no build offers them"
}

test_guard_denies_skills_that_fork_a_subagent() {
  local name rc
  write_skill "$PRIMARY/.claude/skills/forky/SKILL.md" 'name: forky' 'description: probe' 'context: fork' 'agent: general-purpose'
  write_skill "$PRIMARY/.claude/skills/quoted/SKILL.md" 'context: "fork"  # runs apart'
  mkdir -p "$PRIMARY/.claude/skills/crlf"
  printf -- '---\r\ndescription: probe\r\ncontext: fork\r\n---\r\nbody\r\n' > "$PRIMARY/.claude/skills/crlf/SKILL.md"
  write_skill "$PRIMARY/.claude/commands/forkcmd.md" 'description: probe' 'context: fork'
  write_skill "$PRIMARY/.claude/commands/ops/nsfork.md" 'context: fork'
  write_skill "$PRIMARY/tools/.claude/skills/nested/SKILL.md" 'context: fork'
  write_skill "$CLAUDE_CFG/skills/userfork/SKILL.md" 'context: fork'
  write_skill "$CLAUDE_CFG/plugins/cache/market/plug/1.0.0/skills/pfork/SKILL.md" 'context: fork'
  write_skill "$CLAUDE_CFG/plugins/cache/market/plug/1.0.0/commands/pcmd.md" 'context: fork'
  write_skill "$PRIMARY/.claude/skills/inline/SKILL.md" 'name: inline' 'description: probe'
  write_skill "$PRIMARY/.claude/skills/agentonly/SKILL.md" 'agent: general-purpose'
  write_skill "$PRIMARY/.claude/skills/explicit-inline/SKILL.md" 'context: inline'
  mkdir -p "$PRIMARY/.claude/skills/bodyfork"
  printf -- '---\ndescription: probe\n---\ncontext: fork\n' > "$PRIMARY/.claude/skills/bodyfork/SKILL.md"
  mkdir -p "$PRIMARY/.claude/skills/nofront"
  printf 'context: fork\n' > "$PRIMARY/.claude/skills/nofront/SKILL.md"

  for name in forky /forky quoted crlf forkcmd ops:nsfork tools:nested userfork plug:pfork plug:pcmd; do
    rc=0
    run_skill "$name" || rc=$?
    [ "$rc" -eq 2 ] || fail "skill $name runs in a forked subagent and must deny, got exit $rc"
    [ ! -s "$OUT" ] || fail "skill $name deny wrote stdout: $(cat "$OUT")"
    jq -e --arg tail "(blocked tool: Skill, skill \"${name#/}\" runs in a forked subagent context)" \
      '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | startswith("[subagent-dispatch] ") and contains($tail))' \
      "$ERR" >/dev/null 2>&1 || fail "skill $name deny lost its shape: $(cat "$ERR")"
  done

  # agent: alone runs inline, measured on Claude Code 2.1.292. A name that
  # resolves to no file (a built-in such as update-config) cannot be classified.
  for name in inline agentonly explicit-inline bodyfork nofront update-config plug:missing ''; do
    rc=0
    run_skill "$name" || rc=$?
    [ "$rc" -eq 0 ] || fail "skill '$name' runs inline and must allow, got exit $rc: $(cat "$ERR")"
    [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "skill '$name' allow wrote output: $(cat "$OUT" "$ERR")"
  done

  write_skill "$TMP_ROOT/home/.claude/skills/homefork/SKILL.md" 'context: fork'
  rc=0
  run_skill homefork -u CLAUDE_CONFIG_DIR HOME="$TMP_ROOT/home" || rc=$?
  [ "$rc" -eq 2 ] || fail "without CLAUDE_CONFIG_DIR a forking skill under HOME/.claude must deny, got exit $rc"

  rc=0
  run_skill forky FM_ALLOW_SUBAGENT=1 || rc=$?
  [ "$rc" -eq 0 ] || fail "the escape hatch must release a forking skill too, got exit $rc"
  pass "a skill whose frontmatter forks a subagent is denied wherever Claude Code loads it from, and inline skills stay allowed"
}

expect_skill() {  # <deny|allow> <skill-as-the-Skill-tool-receives-it> <why>
  local want=$1 name=$2 why=$3 rc=0
  run_skill "$name" || rc=$?
  if [ "$want" = deny ]; then
    [ "$rc" -eq 2 ] || fail "skill '$name' $why and must deny, got exit $rc"
  else
    [ "$rc" -eq 0 ] || fail "skill '$name' $why and must allow, got exit $rc: $(cat "$ERR")"
  fi
}

# Claude Code 2.1.292 strips one BOM, opens frontmatter on a first line of ---
# and whitespace, closes it at the first --- anywhere, parses it as YAML, and
# forks only when the parsed context value is exactly the string "fork".
test_guard_reads_skill_frontmatter_the_way_claude_code_parses_it() {
  local dir="$PRIMARY/.claude/skills"
  write_skill "$dir/fm-folded/SKILL.md" 'context: >-' '  fork'
  write_skill "$dir/fm-literal/SKILL.md" 'context: |-' '  fork'
  write_skill "$dir/fm-qkey/SKILL.md" '"context": fork'
  write_skill "$dir/fm-sqkey/SKILL.md" "'context': fork"
  write_skill "$dir/fm-spcolon/SKILL.md" 'context : fork'
  write_skill "$dir/fm-tag/SKILL.md" 'context: !!str fork'
  write_skill "$dir/fm-escaped/SKILL.md" 'context: "f\x6frk"'
  write_skill "$dir/fm-nextline/SKILL.md" 'context:' '  fork'
  write_skill "$dir/fm-twice/SKILL.md" 'context: inline' 'context: fork'
  write_skill "$dir/fm-midclose/SKILL.md" 'context: fork---'
  mkdir -p "$dir/fm-bom" "$dir/fm-openws"
  printf '\xef\xbb\xbf---\ncontext: fork\n---\nbody\n' > "$dir/fm-bom/SKILL.md"
  printf -- '--- \t\ncontext: fork\n---\nbody\n' > "$dir/fm-openws/SKILL.md"
  for name in fm-folded fm-literal fm-qkey fm-sqkey fm-spcolon fm-tag fm-escaped fm-nextline fm-twice fm-midclose fm-bom fm-openws; do
    expect_skill deny "$name" "sets a context Claude Code can parse as fork"
  done

  write_skill "$dir/fm-dq-inline/SKILL.md" 'context: "inline"'
  write_skill "$dir/fm-sq-inline/SKILL.md" "context: 'inline' # stays here"
  write_skill "$dir/fm-plain-other/SKILL.md" 'context: Fork'
  write_skill "$dir/fm-hash/SKILL.md" 'context: fork#not-a-comment'
  write_skill "$dir/fm-earlyclose/SKILL.md" 'description: a --- b' 'context: fork'
  mkdir -p "$dir/fm-leadblank" "$dir/fm-dashes"
  printf '\n---\ncontext: fork\n---\nbody\n' > "$dir/fm-leadblank/SKILL.md"
  printf -- '----\ncontext: fork\n---\nbody\n' > "$dir/fm-dashes/SKILL.md"
  for name in fm-dq-inline fm-sq-inline fm-plain-other fm-hash fm-earlyclose fm-leadblank fm-dashes; do
    expect_skill allow "$name" "has no context Claude Code parses as fork"
  done
  pass "the guard denies every frontmatter form Claude Code parses as fork and allows the plain inline values"
}

test_guard_trims_the_skill_name_like_claude_code() {
  local name
  write_skill "$PRIMARY/.claude/skills/forky/SKILL.md" 'name: forky' 'context: fork'
  for name in ' forky' 'forky ' '  /forky' '\tforky'; do
    expect_skill deny "$name" "trims to the forking skill forky"
    jq -e '.systemMessage | contains("(blocked tool: Skill, skill \"forky\" runs in a forked subagent context)")' "$ERR" >/dev/null 2>&1 \
      || fail "skill '$name' deny must name the trimmed skill: $(cat "$ERR")"
  done
  expect_skill allow '/ forky' "keeps the space after the slash, so it names no skill"
  pass "the guard trims the skill name before stripping one slash, as Claude Code does"
}

test_guard_denies_built_in_skills_that_fork() {
  local name
  for name in code-review review /code-review ' review' claude-test-execute claude-test-draft \
    claude-test:execute claude-test:draft cc-plugin-claude-test:claude-test-execute cc-plugin-claude-test:claude-test-draft; do
    expect_skill deny "$name" "is a Claude Code built-in that forks a subagent"
    [ ! -s "$OUT" ] || fail "built-in skill $name deny wrote stdout: $(cat "$OUT")"
  done
  # Claude Code matches a built-in name or alias in exact case only.
  for name in update-config init simplify plug:review code-reviewer Code-Review Review; do
    expect_skill allow "$name" "is not a forking built-in"
  done
  pass "the built-in skills Claude Code forks are denied by name and other built-ins stay allowed"
}

# Claude Code's lookup takes a skill whose exact-case name matches before a
# built-in, so a file skill named review or code-review replaces the built-in.
test_file_skill_named_like_a_built_in_is_judged_by_its_frontmatter() {
  local skills="$PRIMARY/.claude/skills"
  write_skill "$skills/review/SKILL.md" 'name: review' 'context: inline'
  write_skill "$CLAUDE_CFG/skills/code-review/SKILL.md" 'name: code-review'
  expect_skill allow review "is a project skill that runs inline in place of the built-in"
  expect_skill allow code-review "is a user skill that runs inline in place of the built-in"
  write_skill "$skills/review/SKILL.md" 'name: review' 'context: fork'
  expect_skill deny review "is a project skill that forks"
  rm -rf "$skills/review" "$CLAUDE_CFG/skills/code-review"
  write_skill "$skills/Review/SKILL.md" 'name: Review' 'context: inline'
  expect_skill deny review "names the built-in alias, because the skill Review differs in case"
  rm -rf "$skills/Review"
  expect_skill deny review "has no file skill, so the forking built-in runs"
  pass "a file skill named like a forking built-in is judged by its own frontmatter, matched in exact case"
}

# An inline Skill call must not pay for the primary-scope check, whose two git
# processes dominated the hook's cost; the scope only matters once a call would
# be denied.
test_inline_skill_call_starts_no_git() {
  local fakebin="$TMP_ROOT/gitlog-bin" log="$TMP_ROOT/git.log" real_git rc
  real_git=$(command -v git)
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\necho "$*" >> %q\nexec %q "$@"\n' "$log" "$real_git" > "$fakebin/git"
  chmod +x "$fakebin/git"
  write_skill "$PRIMARY/.claude/skills/inline/SKILL.md" 'name: inline' 'description: probe'
  write_skill "$PRIMARY/.claude/skills/forky/SKILL.md" 'name: forky' 'context: fork'
  : > "$log"
  rc=0
  run_skill inline PATH="$fakebin:$PATH" || rc=$?
  [ "$rc" -eq 0 ] || fail "inline skill must allow, got exit $rc"
  [ ! -s "$log" ] || fail "an inline Skill call must not start git, it ran: $(cat "$log")"
  rc=0
  run_skill forky PATH="$fakebin:$PATH" || rc=$?
  [ "$rc" -eq 2 ] || fail "forking skill must deny, got exit $rc"
  [ -s "$log" ] || fail "a forking Skill call must still confirm the primary scope through git"
  pass "an inline Skill call decides before the primary-scope check and starts no git"
}

test_deny_message_names_the_real_dispatch_paths() {
  local actual
  # Firstmate ships no bin/fm-scout.sh, so a stray file of that name must not
  # turn the deny into a route to it.
  printf '#!/usr/bin/env bash\n' > "$PRIMARY/bin/fm-scout.sh"
  run_tool Agent && fail "Agent must still deny"
  rm -f "$PRIMARY/bin/fm-scout.sh"
  actual=$(jq -r '.systemMessage' "$ERR")
  case "$actual" in
    *"$DISPATCH_ROUTE"*) ;;
    *) fail "deny must route dispatch through brief then spawn, with --scout to both for a scout: $actual" ;;
  esac
  case "$actual" in
    *fm-scout.sh*) fail "deny must not name bin/fm-scout.sh, which firstmate does not ship: $actual" ;;
  esac
  pass "deny defers to intake classification and names the dispatch path ships and scouts really use"
}

test_escape_hatch_allows_deliberate_use() {
  local rc value
  expect_allow "escape hatch set" Agent FM_ALLOW_SUBAGENT=1
  expect_deny "escape hatch unset" Agent
  for value in '' 0 yes true 11; do
    rc=0
    run_tool Agent "FM_ALLOW_SUBAGENT=$value" || rc=$?
    [ "$rc" -eq 2 ] || fail "FM_ALLOW_SUBAGENT='$value' must not release the guard, got exit $rc"
  done
  pass "the single documented escape hatch releases the guard only on the exact opt-in value"
}

test_task_worktree_and_non_firstmate_repo_are_inert() {
  local child="$TMP_ROOT/child" plain="$TMP_ROOT/plain" rc=0
  git -C "$PRIMARY" config user.name fixture
  git -C "$PRIMARY" config user.email fixture@example.test
  git -C "$PRIMARY" add AGENTS.md
  git -C "$PRIMARY" commit -qm fixture
  git -C "$PRIMARY" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/bin" "$child/state"
  printf '# fixture\n' > "$child/AGENTS.md"
  : > "$OUT"
  : > "$ERR"
  FM_ROOT_OVERRIDE="$child" FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" \
    "$CHECK" --claude --tool Agent > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a crewmate task worktree must be out of scope, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "task-worktree no-op wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "task-worktree no-op wrote stderr: $(cat "$ERR")"

  mkdir -p "$plain/bin"
  git -C "$plain" init -q
  rc=0
  FM_ROOT_OVERRIDE="$plain" FM_HOME="$plain" FM_STATE_OVERRIDE="$plain/state" \
    "$CHECK" --claude --tool Agent > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "a non-firstmate repo must be out of scope, got exit $rc"
  pass "the guard is inert in a crewmate task worktree and in a non-firstmate repo"
}

test_secondmate_home_is_in_scope() {
  local second="$TMP_ROOT/second" rc=0
  git -C "$PRIMARY" worktree add -q -b fixture-second "$second"
  mkdir -p "$second/bin" "$second/state"
  printf '# fixture\n' > "$second/AGENTS.md"
  printf 'sm-fixture\n' > "$second/.fm-secondmate-home"
  FM_ROOT_OVERRIDE="$second" FM_HOME="$second" FM_STATE_OVERRIDE="$second/state" \
    "$CHECK" --claude --tool Agent > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "a marked secondmate home operates a fleet and must be guarded, got exit $rc"
  pass "a marked secondmate home is guarded even though it is a linked worktree"
}

test_stdin_transports_and_output_shapes() {
  local rc=0
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"tool_name":"Agent","tool_input":{"prompt":"go"}}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Claude-shaped stdin must deny, got exit $rc"
  [ ! -s "$OUT" ] || fail "Claude deny wrote stdout, which makes Claude ignore the deny: $(cat "$OUT")"

  rc=0
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"toolName":"Agent"}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 2 ] || fail "Grok-shaped stdin must deny, got exit $rc"
  jq -e '.decision == "deny" and (.reason | startswith("[subagent-dispatch]"))' "$OUT" >/dev/null 2>&1 \
    || fail "default deny mode must write a Grok decision object on stdout: $(cat "$OUT")"

  rc=0
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "Bash through stdin must allow, got exit $rc"
  [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "stdin allow wrote output"
  pass "both stdin transports classify correctly and Claude's deny keeps stdout empty"
}

test_malformed_transport_fails_open() {
  local rc payload
  for payload in '{not-json' '' '{}' '{"tool_name":null}'; do
    rc=0
    : > "$OUT"; : > "$ERR"
    printf '%s' "$payload" \
      | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
        "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
    [ "$rc" -eq 0 ] || fail "malformed transport must fail open, payload '$payload' gave exit $rc"
    [ ! -s "$OUT" ] || fail "fail-open path wrote stdout for payload '$payload'"
  done
  pass "malformed, empty, and tool-name-less payloads fail open rather than blocking every tool call"
}

test_missing_jq_stdin_transport_fails_open() {
  local fakebin="$TMP_ROOT/no-jq-bin" bash_bin cat_bin rc=0
  bash_bin=$(command -v bash) || fail "test needs bash to simulate the hook shebang"
  cat_bin=$(command -v cat) || fail "test needs cat to feed stdin without jq"
  mkdir -p "$fakebin"
  ln -sf "$bash_bin" "$fakebin/bash"
  ln -sf "$cat_bin" "$fakebin/cat"
  # Git Bash makes ln -s a copy, and a copied MSYS binary loads its DLLs from its own directory.
  for dll in "${bash_bin%/*}"/msys-*.dll; do
    [ ! -e "$dll" ] || ln -sf "$dll" "$fakebin/"
  done
  : > "$OUT"; : > "$ERR"
  printf '%s' '{"tool_name":"Agent"}' \
    | env PATH="$fakebin" FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      "$CHECK" --claude > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "missing jq transport must fail open, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "missing jq fail-open path wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "missing jq fail-open path wrote stderr: $(cat "$ERR")"
  pass "missing jq for stdin transport fails open rather than denying every tool call"
}

# A plain primary checkout holding the real guard, reached the way Claude Code
# reaches it: through the tracked settings command and CLAUDE_PROJECT_DIR.
TRACKED="$TMP_ROOT/tracked"
mkdir -p "$TRACKED/bin" "$TRACKED/state"
printf '# fixture\n' > "$TRACKED/AGENTS.md"
git -C "$TRACKED" init -q
cp "$ROOT/bin/fm-subagent-pretool-check.sh" "$ROOT/bin/fm-primary-scope-lib.sh" "$TRACKED/bin/"
write_skill "$TRACKED/.claude/skills/forky/SKILL.md" 'name: forky' 'description: probe' 'context: fork'

# Tool names Claude Code offers a primary, plus delegation-shaped and future
# names. The matcher may skip a name only when the classifier allows it.
MATCHER_PROBE_TOOLS="$PRESERVED_TOOLS $DELEGATION_TOOLS Glob Grep LS MultiEdit PowerShell TodoWrite BashOutput KillShell ExitPlanMode AskUserQuestion mcp__linear__list_issues mcp__acme__spawn_agent SubagentCreate SpawnWorker Read_Agent ReadAgent Bash2 XRead"

run_tracked_tool() {  # <tool> <tool-input-json>
  local payload rc=0
  payload=$(fm_claude_pretool_payload "$TRACKED" "$1" "$2")
  fm_run_tracked_pretool "$TRACKED" fm-subagent-pretool-check.sh "$payload" "$OUT" "$ERR" || rc=$?
  return "$rc"
}

test_tracked_matcher_skips_only_always_allowed_names() {
  local tool skipped="" excluded matcher
  for tool in $MATCHER_PROBE_TOOLS; do
    fm_tracked_pretool_matches fm-subagent-pretool-check.sh "$tool" && continue
    skipped="$skipped $tool"
    expect_allow "matcher-skipped tool" "$tool"
  done
  for tool in Agent Task SendMessage EnterWorktree CronCreate Workflow Monitor Skill SubagentCreate SpawnWorker ReadAgent Read_Agent XRead Bash2; do
    fm_tracked_pretool_matches fm-subagent-pretool-check.sh "$tool" \
      || fail "the tracked matcher must hand $tool to the classifier"
  done
  matcher=$(jq -r '.hooks.PreToolUse[] | select(any(.hooks[].command; contains("/bin/fm-subagent-pretool-check.sh "))) | .matcher' "$ROOT/.claude/settings.json")
  excluded=$(printf '%s' "$matcher" | sed -n 's/^\^(?!(?:\([A-Za-z|]*\))\$|mcp__)\.\*$/\1/p')
  [ -n "$excluded" ] || fail "the tracked matcher must be the exact-name exclusion form: $matcher"
  # An excluded name must be allowed whatever its input says, so each one is
  # sent with the input of a skill that forks.
  for tool in ${excluded//|/ }; do
    ! fm_tracked_pretool_matches fm-subagent-pretool-check.sh "$tool" || fail "the matcher lists $tool but still matches it"
    run_tracked_tool "$tool" '{"skill":"forky"}' \
      || fail "the matcher skips $tool, but the classifier denies it: $(cat "$ERR")"
  done
  case " $skipped " in
    *" Read "*) ;;
    *) fail "the tracked matcher must skip Read, the commonest tool call: skipped [$skipped]" ;;
  esac
  pass "the tracked matcher skips only names the classifier allows and hands every other name to it"
}

test_tracked_command_real_payloads() {
  local tool input expect why rc
  while IFS='|' read -r tool expect why input; do
    [ -n "$tool" ] || continue
    rc=0
    run_tracked_tool "$tool" "$input" || rc=$?
    if [ "$expect" = allow ]; then
      [ "$rc" -eq 0 ] || fail "tracked hook must allow $tool, got exit $rc: $(cat "$ERR")"
      [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "tracked hook allow for $tool wrote output: $(cat "$OUT" "$ERR")"
      continue
    fi
    [ "$rc" -eq 2 ] || fail "tracked hook must deny $tool with exit 2, got $rc"
    [ ! -s "$OUT" ] || fail "tracked hook deny for $tool wrote stdout: $(cat "$OUT")"
    jq -e --arg tail "(blocked tool: $tool, $why)" \
      '.hookSpecificOutput == {hookEventName: "PreToolUse", permissionDecision: "deny"}
       and (.systemMessage | startswith("[subagent-dispatch] ") and contains($tail))' "$ERR" >/dev/null \
      || fail "tracked hook deny for $tool lost its shape: $(cat "$ERR")"
  done <<'ROWS'
Read|allow||{"file_path":"/c/fm/AGENTS.md"}
Grep|allow||{"pattern":"fm_spawn","path":"bin","output_mode":"content"}
Glob|allow||{"pattern":"**/*.sh"}
Bash|allow||{"command":"ls projects data 2>&1","description":"List projects"}
Skill|allow||{"skill":"project-management"}
Skill|deny|skill "forky" runs in a forked subagent context|{"skill":"forky"}
ToolSearch|allow||{"query":"select:Agent","tool_name":"Agent"}
TaskCreate|allow||{"subject":"spawn the greeter task","description":"x"}
mcp__claude_ai_Gmail__send_message|allow||{"to":"a@example.test"}
Agent|deny|delegation-shaped on "agent"|{"description":"look","prompt":"investigate","subagent_type":"general-purpose"}
Task|deny|delegation-shaped on "task"|{"description":"look","prompt":"investigate"}
SendMessage|deny|delegation-shaped on "sendmessage"|{"to":"worker","message":"go"}
EnterWorktree|deny|delegation-shaped on "worktree"|{"name":"x"}
CronCreate|deny|delegation-shaped on "cron"|{"cron":"*/5 * * * *","prompt":"check"}
Monitor|deny|delegation-shaped on "monitor"|{"command":"tail -f log"}
ROWS
  pass "the tracked registration classifies real Claude Code payloads exactly as the guard contract says"
}

test_guard_denies_every_currently_known_delegation_tool
test_guard_denies_hypothetical_future_tools
test_guard_allows_ordinary_and_observe_only_tools
test_guard_allows_session_local_todo_tools
test_plan_only_exclusion_is_exact_name
test_guard_never_classifies_mcp_tools
test_guard_allows_retired_claude_tool_names
test_guard_denies_skills_that_fork_a_subagent
test_guard_reads_skill_frontmatter_the_way_claude_code_parses_it
test_guard_trims_the_skill_name_like_claude_code
test_guard_denies_built_in_skills_that_fork
test_file_skill_named_like_a_built_in_is_judged_by_its_frontmatter
test_inline_skill_call_starts_no_git
test_deny_message_names_the_real_dispatch_paths
test_escape_hatch_allows_deliberate_use
test_task_worktree_and_non_firstmate_repo_are_inert
test_secondmate_home_is_in_scope
test_stdin_transports_and_output_shapes
test_malformed_transport_fails_open
test_missing_jq_stdin_transport_fails_open
test_tracked_matcher_skips_only_always_allowed_names
test_tracked_command_real_payloads
