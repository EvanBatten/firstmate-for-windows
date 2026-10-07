#!/usr/bin/env bash
# PreToolUse guard against primary-session delegation outside the fleet.
#
# A firstmate primary that delegates through a harness's own delegation,
# scheduling, or background-work tool creates work with no `state/<id>.meta` and
# no `data/<id>/brief.md`. Only `bin/fm-spawn.sh` writes that metadata, and
# untracked project work contributes nothing to the in-flight branch of
# bin/fm-supervision-lib.sh or bin/fm-turnend-guard.sh. So such work is not
# merely unsupervised: absent an independent X-mode need, it makes the whole
# guard stack structurally inert, and it dies with the primary session instead
# of living in its own backend session.
#
# This scoped PreToolUse guard is the shipped mechanism.
# Claude primaries should also use an untracked per-home local
# `permissions.deny` list as hardening for known Claude delegation tools,
# because it removes them from the model's schema entirely.
# That deny list must not be tracked: it is Claude-only rather than
# harness-agnostic, and tracked project settings propagate into linked
# worktrees where they disarm legitimate crewmates.
# The tracked Claude matcher hands every tool name to this script except an
# exact-name list of everyday tools this script always allows and MCP tools,
# which it never classifies, so a hook process starts for none of them. It never
# enumerates delegation stems: that would reintroduce the fail-open-by-
# enumeration problem this guard exists to solve, because any future tool name
# outside the matcher would never reach this script.
# This script is therefore the single owner of classification.
# It classifies a known tool by what that tool does (tool_effect) and any other
# name by its delegation SHAPE rather than a fixed list, so a future tool that
# ships before anyone updates a local deny list is still refused.
#
# The guard is narrow by design. It classifies ONE thing: whether the tool call
# starts work the fleet would not know about. It makes no judgment about whether
# the work should be delegated at all, which is a reasoning boundary no
# tool-shape hook can enforce.
# See docs/subagent-guard.md for the complete contract and validation record.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-subagent-pretool-check.sh
#   bin/fm-subagent-pretool-check.sh --tool '<tool-name>'
#
# Stdin mode extracts .tool_name for Claude and Codex, or .toolName for Grok.
# CLI mode is for adapters that already hold the tool name (OpenCode, Pi).
#
# Exit/output contract (identical shape to bin/fm-cd-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   INERT - not a genuine primary home (a crewmate/scout task worktree or a
#           non-firstmate repo): exit 0 with no output, exactly like ALLOW.
#   ESCAPE - FM_ALLOW_SUBAGENT=1 in the environment allows deliberately.
#   FAIL OPEN - malformed or empty stdin, or missing jq for stdin transport.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
set -u

# Lowercase substrings that mark a tool name as delegation-shaped: it creates
# work, an agent, a schedule, or an isolated workspace that firstmate would not
# know about. This list is the single owner of the shipped classification.
DELEGATION_STEMS='agent subagent task workflow cron schedul worktree delegate spawn dispatch handoff remote sendmessage monitor'

# What a tool does, for the exact lowercase names whose effect is known. A name
# listed here is classified by that effect alone; every other name falls back
# to the stem test above, so a future delegation tool is still refused. Rows are
# exact names, never substrings, so no row can widen by accident.
#
# observe-only: the tool only OBSERVES or STOPS work that already exists.
#   Reading or ending unaccounted work is not creating it, and denying these
#   would strand already-running work with no way to inspect or end it. A local
#   Claude deny list may still remove these from the schema; this shipped guard
#   deliberately stays narrower so it can never be the reason a runaway task
#   cannot be stopped.
# plan-only: the tool writes only the harness's session-local todo list, which
#   has no executor: it spawns no agent, allocates no worktree, registers no
#   schedule, and starts nothing that could outlive the session or escape a
#   firstmate guard. Denying it stops the primary tracking its own plan while
#   granting no delegation power. It is a separate effect from observe-only
#   because these tools WRITE, so folding them in would make that contract untrue.
# skill: the tool runs a skill. An inline skill expands into this conversation,
#   but a skill whose frontmatter sets `context: fork` runs as a subagent of this
#   session, so the call is classified by the skill it names (skill_forks).
tool_effect() {
  case "$1" in
    taskoutput|taskstop|taskget|tasklist|cronlist|bashoutput|killshell) EFFECT=observe-only ;;
    taskcreate|taskupdate) EFFECT=plan-only ;;
    skill) EFFECT=skill ;;
    *) EFFECT=shape ;;
  esac
}

# Whether the skill a Skill call names runs in a forked subagent. A built-in
# skill lives inside the Claude Code binary, so the ones that fork are listed by
# name (docs/subagent-guard.md "Skills" says how the list was taken). Claude Code
# loads any other plain name from the project's and the user's skills and
# commands, a <plugin>:<name> from that plugin, and a <dir>:<name> from a nested
# project directory or a commands subdirectory, so every file the name could
# resolve to is read and any one that forks decides.
skill_forks() {
  local name=$1 leaf prefix config=${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude} file shadowed=0
  leaf=${name##*:}
  if [ "$leaf" = "$name" ]; then
    set -- "$FM_ROOT/.claude/skills/$leaf/SKILL.md" "$FM_ROOT/.claude/commands/$leaf.md" \
      "$config/skills/$leaf/SKILL.md" "$config/commands/$leaf.md"
  else
    prefix=${name%:*}
    set -- "$FM_ROOT/$prefix/.claude/skills/$leaf/SKILL.md" \
      "$FM_ROOT/.claude/commands/$prefix/$leaf.md" "$config/commands/$prefix/$leaf.md" \
      "$config"/plugins/cache/*/"$prefix"/*/skills/"$leaf"/SKILL.md \
      "$config"/plugins/cache/*/"$prefix"/*/commands/"$leaf".md
  fi
  for file in "$@"; do
    [ -f "$file" ] || continue
    frontmatter_forks "$file" && return 0
    name_case_matches "${file%/SKILL.md}" && shadowed=1
  done
  # Claude Code's lookup takes a skill whose name matches exactly, case
  # included, before a built-in, so a file skill by that name replaces it.
  [ "$shadowed" -eq 0 ] || return 1
  case "$name" in
    code-review|review|claude-test-execute|claude-test-draft|claude-test:execute|claude-test:draft|\
    cc-plugin-claude-test:claude-test-execute|cc-plugin-claude-test:claude-test-draft) return 0 ;;
  esac
  return 1
}

# Whether a path's last component exists with exactly that case. A test of the
# path alone cannot tell on a case-insensitive filesystem.
name_case_matches() {  # <path>
  local entry
  for entry in "${1%/*}"/*; do
    [ "${entry##*/}" != "${1##*/}" ] || return 0
  done
  return 1
}

# Claude Code 2.1.292 strips one BOM, opens frontmatter on a first line of ---
# and whitespace, ends it at the first --- anywhere, parses it as YAML, and forks
# only when the context value is exactly the string "fork". YAML is not parsed
# here, so a context key forks unless its value is plainly something else.
frontmatter_forks() {  # <skill-or-command-file>
  local line last=0 LC_ALL=C
  {
    IFS= read -r line || return 1
    line=${line#$'\xef\xbb\xbf'}
    case "$line" in
      ---*) line=${line#---} ;;
      *) return 1 ;;
    esac
    case "$line" in
      *[[:graph:]]*) return 1 ;;
    esac
    while [ "$last" -eq 0 ] && { IFS= read -r line || [ -n "$line" ]; }; do
      case "$line" in
        *---*) line=${line%%---*}; last=1 ;;
      esac
      context_line_forks "$line" && return 0
    done
    return 1
  } < "$1"
}

# Whether one frontmatter line sets a context key that YAML could read as
# "fork". Only a same-line plain or quoted scalar can be read here; a block
# scalar, tag, anchor, escape, empty value, or unclosed quote counts as fork.
context_line_forks() {  # <line>
  local key_re='^[[:space:]]*(context|"context"|'\''context'\'')[[:space:]]*:(.*)$' value
  [[ $1 =~ $key_re ]] || return 1
  value=${BASH_REMATCH[2]}
  value=${value#"${value%%[![:space:]]*}"}
  case "$value" in
    \"*\\*) return 0 ;;
    \"*\"*) value=${value#\"}; [ "${value%%\"*}" = fork ]; return ;;
    \'*\'*) value=${value#\'}; [ "${value%%\'*}" = fork ]; return ;;
    ''|[\"\'\#\>\|\!\&\*\[\{\?%\@\`]*) return 0 ;;
  esac
  value=${value%%[[:space:]]#*}
  value=${value%"${value##*[![:space:]]}"}
  [ "$value" = fork ]
}

TOOL=""
SKILL=""
TOOL_SET=0
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-subagent-pretool-check.sh [--tool <tool-name>] [--claude]

With no --tool, reads a PreToolUse-style JSON payload on stdin (Claude/Codex
tool_name, or Grok toolName).
Denies a delegation-SHAPED tool name in a genuine primary home.
Claude primaries may also add an untracked per-home permissions.deny list that
removes known delegation tools from the model schema before this hook is needed.
Do not ship that Claude-only list in tracked project settings, because linked
worktrees inherit it and legitimate crewmates would lose their delegation tools.
This hook remains as the shipped guard for future delegation-shaped names
outside any local fixed list.
Fires only in a genuine firstmate primary home; it is a silent no-op in a
crewmate/scout task worktree or any non-firstmate repo, where a worker using
delegation tools is legitimate.
Exits 0 to allow and 2 to deny, naming the real crewmate dispatch path instead.
Set FM_ALLOW_SUBAGENT=1 in the session environment to allow deliberately.
Malformed transport fails open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tool)
      [ "$#" -gt 1 ] || { echo "error: --tool requires a value" >&2; exit 2; }
      TOOL=$2
      TOOL_SET=1
      shift 2
      ;;
    --tool=*)
      TOOL=${1#--tool=}
      TOOL_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$TOOL_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # Claude Code trims the skill name, then strips one leading slash.
  FIELDS=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.skill? // .toolInput.skill? // "" | tostring | gsub("^[\\s\\x{FEFF}]+|[\\s\\x{FEFF}]+$"; "")) as $skill
    | [(.tool_name // .toolName // "" | tostring), $skill] | @tsv' 2>/dev/null) || exit 0
  FIELDS=${FIELDS%$'\r'}
  TOOL=${FIELDS%%$'\t'*}
  SKILL=${FIELDS#*$'\t'}
  SKILL=${SKILL#/}
fi

[ -n "$TOOL" ] || exit 0

LC_ALL=C NORMALIZED=$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')

# An MCP tool belongs to an external integration, not to the harness's own
# delegation surface, and its name is chosen by that server. Never classify one
# here: an MCP server with a task or agent noun in a tool name is common and
# blocking it would be a false positive with no bearing on fleet dispatch.
case "$TOOL" in
  mcp__*) exit 0 ;;
esac

tool_effect "$NORMALIZED"
case "$EFFECT" in
  observe-only|plan-only) exit 0 ;;
  skill)
    [ -n "$SKILL" ] || exit 0
    WHY="skill \"$SKILL\" runs in a forked subagent context"
    ;;
  shape)
    MATCHED=""
    for stem in $DELEGATION_STEMS; do
      case "$NORMALIZED" in
        *"$stem"*) MATCHED=$stem; break ;;
      esac
    done
    [ -n "$MATCHED" ] || exit 0
    WHY="delegation-shaped on \"$MATCHED\""
    ;;
esac

# The single deliberate escape hatch. It is an environment variable rather than
# a flag or a state file so it must be set when the session is launched, which
# makes a genuinely intended use possible and an accidental one impossible: no
# in-session tool call can set it for the call that follows.
[ "${FM_ALLOW_SUBAGENT:-}" != "1" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

# Deciding the skill first spares an inline Skill call the scope check's git
# processes; only a call that would be denied needs its scope confirmed.
[ "$EFFECT" != skill ] || skill_forks "$SKILL" || exit 0

# Scope to a genuine primary home, exactly as the session-start nudge and the
# turn-end guard do. fm_primary_scope_matches accepts a plain checkout or a
# marked secondmate home - both operate a fleet and must dispatch through it -
# and rejects a linked task worktree, which is the shape bin/fm-spawn.sh always
# hands a crewmate. A crewmate using delegation tools inside its own task
# worktree is legitimate and stays allowed. Any failure to confirm the home is
# inert (exit 0), never a block, so a broken environment never denies a call.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

REASON="[subagent-dispatch] the firstmate primary dispatches through the fleet, not the harness's own delegation tools: work started that way has no durable fleet record, leaves every firstmate guard inert, and dies with this session. Instead, first classify the work under the AGENTS.md intake contract, then use bin/fm-brief.sh followed by bin/fm-spawn.sh for dispatched work, passing --scout to both for a scout (blocked tool: $TOOL, $WHY). Launch the session with FM_ALLOW_SUBAGENT=1 for a deliberate exception."

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

ESCAPED=$(json_escape "$REASON")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
