#!/usr/bin/env bash
# Feature: a task whose endpoint has disappeared can still be recovered.
#
# Issue #58. The endpoint is gone - the window was closed, or its session died.
# The local copy and its commits are fine and the operator wants the worker
# back. Today every route refuses and points at one of the others: relaunch
# stops the old agent first, and stopping dies because there is nothing to
# stop, while the launch path demands a dead endpoint rather than an absent one.
#
# Nothing here launches a real agent. The harness is shadowed by a stub that
# refuses to run, so a recovery that gets moving fails at the launch, for an
# obviously different reason, while everything else on the path still works.
# The question asked is only whether the operator is given a way forward.
# shellcheck source=tests/verification/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

verify_home
HOME_DIR="$VERIFY_HOME"
export FM_HOME="$HOME_DIR"
BIN="$VERIFY_ROOT/bin"
PROJ="$HOME_DIR/projects/demo"
WT="$VERIFY_TMP/demo-work"
ID=vanished

mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
git -C "$PROJ" config user.email verify@example.invalid
git -C "$PROJ" config user.name verification
printf 'one\n' > "$PROJ/a.txt"
git -C "$PROJ" add -A && git -C "$PROJ" commit -qm "base"
git -C "$PROJ" worktree add -q -b "fm/$ID" "$WT"
printf 'work in progress\n' > "$WT/wip.txt"
git -C "$WT" add -A && git -C "$WT" commit -qm "unlanded work"
WIP=$(git -C "$WT" rev-parse HEAD)

mkdir -p "$HOME_DIR/data/$ID"
printf 'Finish the thing.\n' > "$HOME_DIR/data/$ID/brief.md"
cat > "$HOME_DIR/state/$ID.meta" <<META
window=gone-session:w99:p99
endpoint_task_id=$ID
worktree=$WT
project=$PROJ
harness=claude
kind=ship
mode=direct-PR
yolo=off
model=sonnet
effort=low
backend=herdr
herdr_session=gone-session
herdr_workspace_id=w99
herdr_tab_id=w99:t99
herdr_pane_id=w99:p99
spawn_gen=s1.1.1
META

state=$(timeout 90 "$BIN/fm-crew-state.sh" "$ID" 2>&1 | head -1)
if printf '%s' "$state" | grep -Eqi 'gone|missing|unknown'; then
  ok "the vanished endpoint is recognised as gone"
else
  bad "the endpoint does not read as gone, so this is not the situation under test: $state"
fi

SHIM="$VERIFY_TMP/shim"
mkdir -p "$SHIM"
{
  printf '#!/bin/sh\n'
  printf 'echo "verification: the harness is deliberately unavailable" >&2\n'
  printf 'exit 127\n'
} > "$SHIM/claude"
chmod +x "$SHIM/claude"

out=$(PATH="$SHIM:$PATH" timeout 180 "$BIN/fm-control.sh" "$ID" relaunch   --note 'the window was closed; pick the work back up' 2>&1)
[ -n "${VERIFY_DEBUG:-}" ] && printf 'relaunch said >>>\n%s\n<<<\n' "$out"

# The claim: recovery must not refuse on the grounds that there is nothing to
# stop. Reaching the launch and failing there is a pass, because the operator
# was given a route.
if printf '%s' "$out" | grep -Fq 'there is no agent to stop'; then
  bad "recovery refuses because there is no agent to stop, leaving no way forward"
elif printf '%s' "$out" | grep -Fq 'reconcile the task before any further control action'; then
  bad "recovery sends the operator away to reconcile, which is what they were trying to do"
elif printf '%s' "$out" | grep -Eq 'deliberately unavailable|could not be launched|did not come up'; then
  ok "recovery reaches the launch, so a vanished endpoint has a route"
else
  bad "recovery neither refused for the known reason nor reached the launch: $out"
fi

# Stopping is still the right answer for stopping: there genuinely is nothing
# to stop, and that refusal should stay exactly as it is.
if timeout 90 "$BIN/fm-control.sh" "$ID" exit >/dev/null 2>&1; then
  bad "stopping a worker that is not there reported success"
else
  ok "stopping still refuses, which is correct - there is nothing to stop"
fi

# Whatever happened above, the work is untouched. This is what makes a failed
# recovery survivable rather than a loss.
if [ -d "$WT" ]; then
  ok "the local copy survives"
else
  bad "the local copy was removed"
fi
if [ "$(git -C "$WT" rev-parse HEAD 2>/dev/null)" = "$WIP" ]; then
  ok "the unlanded commit survives"
else
  bad "the unlanded commit was lost"
fi
if [ -f "$HOME_DIR/state/$ID.meta" ]; then
  ok "the task's record survives"
else
  bad "the task's record was removed"
fi

verify_done
