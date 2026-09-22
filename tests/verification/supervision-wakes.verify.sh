#!/usr/bin/env bash
# A real firstmate session, judged from records: low-token supervision. The
# captain asks for one change and, as the README promises, expects to be left
# alone: the primary dispatches the worker and ends its turn, the Stop hook
# arms a watcher that spends no tokens, the worker's done line becomes a
# notification, the notification wakes the primary, and the primary lands the
# work and acknowledges the queue. Every claim is read from the home's records
# and the observer's ticks, never from what the agent prints.
#
#   VERIFY_REAL_SESSION=1          run it (it spends tokens and opens tabs)
#   VERIFY_SESSION_MODEL=<m>       the primary's model (default opus)
#   VERIFY_SESSION_WAIT=<secs>     budget for the worker (default 900)
# shellcheck disable=SC2329 # the predicates run through session_wait
# shellcheck source=tests/verification/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/verification/session-lib.sh disable=SC1091
. "$(dirname "$0")/session-lib.sh"

session_require
WAIT=${VERIFY_SESSION_WAIT:-900}

project_seed greeter
session_start "fm-verify-supervision"

captain_says "ahoy! add my project from $PROJECT_ORIGIN as a local-only project called greeter. then ship one change: add greet.sh that prints 'hello from the crew', one commit on its own branch. use the opus model for the worker. once the worker is dispatched, end your turn and let your monitoring wake you when it finishes; do not poll it yourself. when it is done, verify the result by running it and land it on main; you have my approval. tell me when it is landed."

registered() { grep -q '^- greeter ' "$SESSION_HOME/data/projects.md" && [ -d "$SESSION_HOME/projects/greeter/.git" ]; }
session_wait "the project is registered and cloned into the home" 600 registered

dispatched() { [ "$(session_task_ids | wc -l | tr -d ' ')" -ge 1 ]; }
session_wait "a worker is dispatched" 900 dispatched
ID=$(session_task_ids | head -1)
verify_keep "$ID.meta" "$SESSION_HOME/state/$ID.meta"

# Ticks: ts, task records, beacon age, primary status, workers done.
yielded() { awk -F'\t' 'NR>1 && $2>0 && ($4=="idle" || $4=="done") {f=1} END{exit !f}' "$SESSION_TICKS"; }
session_wait "the primary ends its turn while the worker is in flight" 600 yielded

watcher_armed() {
  local pid
  pid=$(cat "$SESSION_HOME/state/.watch.lock/pid" 2>/dev/null)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null && [ "$(( $(date +%s) - $(stat -c %Y "$SESSION_HOME/state/.last-watcher-beat" 2>/dev/null || echo 0) ))" -lt 300 ]
}
session_wait "a watcher with a fresh beacon holds the home while the primary is idle" 300 watcher_armed
ls -la "$SESSION_HOME/state" > "$VERIFY_TMP/state-armed.txt"; verify_keep state-armed.txt "$VERIFY_TMP/state-armed.txt"
# The guard clears its block record on a later clean allow, so the snapshots
# are the evidence, not the file as it is now.
if grep -l "\.turnend-claude-blocks" "$VERIFY_ARTIFACT_RUN"/records/state-*.txt >/dev/null 2>&1 || [ -f "$SESSION_HOME/state/.turnend-claude-blocks" ]; then
  [ ! -f "$SESSION_HOME/state/.turnend-claude-blocks" ] || verify_keep turnend-claude-blocks.txt "$SESSION_HOME/state/.turnend-claude-blocks"
  bad "the turn-end guard blocked a turn end in this fresh home: a records snapshot lists state/.turnend-claude-blocks"
else
  ok "the turn-end guard did not block a turn end in this fresh home"
fi

worker_done() { grep -q '^done:' "$SESSION_HOME/state/$ID.status" 2>/dev/null || [ -z "$(session_task_ids)" ]; }
session_wait "the worker reports its task done" "$WAIT" worker_done
[ ! -f "$SESSION_HOME/state/$ID.status" ] || verify_keep "$ID.status" "$SESSION_HOME/state/$ID.status"

# The wake: a tick where the worker is done and the primary idle, followed by
# a tick where the primary works again, with a signal notification for the
# task seen in the queue meanwhile.
woke() {
  awk -F'\t' 'NR>1 { if ($5>0 && ($4=="idle" || $4=="done")) parked=1; if (parked && $4=="working") woke=1 } END{exit !woke}' "$SESSION_TICKS"
}
session_wait "the done line wakes the idle primary" 600 woke
if grep -l "signal" "$VERIFY_ARTIFACT_RUN"/records/state-*.txt 2>/dev/null | xargs -r grep -l "$ID" >/dev/null 2>&1; then
  ok "a signal notification for the task was queued for the primary"
else
  bad "no records snapshot shows a signal notification naming $ID in the queue"
fi
stale=$(awk -F'\t' 'NR>1 { idle = ($2>0 && ($4=="idle" || $4=="done")); if (idle) run++; else run=0; if (idle && run>=3 && ($3=="none" || $3>=300)) n++ } END{print n+0}' "$SESSION_TICKS")
if [ "$stale" -eq 0 ]; then ok "the beacon was fresh at every tick after the primary had been idle with work in flight for three ticks"; else bad "$stale tick(s) had a primary idle with work in flight for three ticks and a stale or missing beacon"; fi

PROJECT="$SESSION_HOME/projects/greeter"
landed() { [ "$(git -C "$PROJECT" rev-list --count "$PROJECT_BASE..main" 2>/dev/null)" -ge 1 ]; }
session_wait "the change is on the project's main" 900 landed
git -C "$PROJECT" log --oneline "$PROJECT_BASE..main" > "$VERIFY_TMP/log.txt"; verify_keep project-log.txt "$VERIFY_TMP/log.txt"
check=$(mktemp -d "$VERIFY_TMP/check.XXXXXX")
git clone -q "$PROJECT" "$check/greeter" 2>/dev/null
got=$(cd "$check/greeter" && bash greet.sh 2>&1)
if [ "$got" = "hello from the crew" ]; then ok "the change does what was asked, checked by running it from main"; else bad "the landed work is wrong: greet '$got'"; fi

cleaned() { [ -z "$(session_task_ids)" ] && [ -z "$(session_task_tabs)" ]; }
session_wait "the worker is cleaned up: no task record and no tab left" 600 cleaned

verify_done
