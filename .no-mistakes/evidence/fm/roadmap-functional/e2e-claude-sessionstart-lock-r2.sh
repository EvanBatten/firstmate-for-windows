#!/usr/bin/env bash
# E2E: execute the tracked Claude SessionStart registration from .claude/settings.json
# the way Claude Code on Windows runs a hook (Git Bash `bash -c "<command>"`, JSON
# payload on stdin), from a shell whose real Win32 ancestry contains this session's
# claude.exe. The code root is a plain git checkout of the given commit with its own
# state/, so the run is the real fm-sessionstart-run.sh -> fm-session-start.sh ->
# fm-lock.sh chain with nothing stubbed. Reports what the session would receive as
# context and whether the fleet lock ended up held by the harness.
# Round 2: identical to e2e-claude-sessionstart-lock.sh except the node spawn bound reads E2E_NODE_TIMEOUT_MS (default 280000).
# usage: e2e-claude-sessionstart-lock-r2.sh <repo> <commit> <label>
set -u
repo=$1 commit=$2 label=$3
home=$(mktemp -d "${TMPDIR:-/tmp}/fm-e2e-ss-$label.XXXXXX")
git -C "$repo" archive "$commit" | tar -x -C "$home"
git -C "$home" init -q
mkdir -p "$home/state"
cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$home/.claude/settings.json")

echo "## $label ($commit)"
echo "harness claude.exe pid (CLAUDE_PID): ${CLAUDE_PID:-unset}"
echo "registered SessionStart command:"
printf '  %s\n' "$cmd"
start=$(date +%s)
# The hook shell must have a NATIVE parent, as it does under claude.exe, which
# spawns `C:\Program Files\Git\bin\bash.exe -c <command>` (measurement.md C4b):
# a `bash -c` forked from this MSYS shell would keep a live MSYS parent above an
# exec and could not show the severed ancestry. So node (native, like
# claude.exe) spawns Git for Windows' bash.exe, and node is started DIRECTLY
# from this shell - not through env/timeout/a pipeline, each of which is an
# MSYS exec that would itself sever the Win32 chain up to claude.exe.
unset NO_MISTAKES_GATE GROK_AGENT GROK_HOOK_EVENT
export CLAUDE_PROJECT_DIR E2E_HOOK_CMD="$cmd"
CLAUDE_PROJECT_DIR=$(cygpath -m "$home")
printf '%s' '{"session_id":"e2e","hook_event_name":"SessionStart","source":"startup"}' > "$home.payload"
node -e '
  const r = require("child_process").spawnSync("C:/Program Files/Git/bin/bash.exe",
    ["-c", process.env.E2E_HOOK_CMD], { stdio: "inherit", timeout: Number(process.env.E2E_NODE_TIMEOUT_MS || 280000) });
  process.exit(r.status === null ? 99 : r.status);' < "$home.payload" > "$home.out" 2> "$home.err"
rc=$?
end=$(date +%s)
echo "hook exit code: $rc (elapsed $((end - start))s)"
echo "hook stdout: $(wc -l < "$home.out") line(s) injected as session context"
echo "--- first 12 lines of hook stdout"
sed -n '1,12p' "$home.out" | cut -c1-200
echo "--- lock / read-only lines in hook stdout"
grep -n -i 'lock\|read-only\|READ ONLY' "$home.out" | cut -c1-200 | head -12
echo "--- state/.lock after the hook"
if [ -f "$home/state/.lock" ]; then
  lock=$(cat "$home/state/.lock")
  echo "state/.lock = $lock"
  if [ "$lock" = "${CLAUDE_PID:-}" ]; then
    echo "=> the fleet lock is held by this session's claude.exe ($lock)"
  else
    echo "=> the lock names $lock, not this session's claude.exe"
  fi
else
  echo "state/.lock absent => the hook did not take the fleet lock"
fi
cp "$home.out" "${E2E_EVIDENCE_DIR:-/dev/null}/sessionstart-$label.stdout.txt" 2>/dev/null || true
echo "$home" >> "${TMPDIR:-/tmp}/fm-e2e-ss-homes"
