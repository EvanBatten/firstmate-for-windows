#!/usr/bin/env bash
# A real firstmate session, judged from records: a restart is a non-event. The
# captain asks for one change and leaves; with the worker in flight the
# captain's window closes and opens again, so a new primary starts in the same
# home. The new session must take the lock, find the worker from the durable
# records, land its work when it is done, and clean up, with the worker
# never noticing. Every claim is read from the home's records, the worker's
# pane and the project's refs.
#
#   VERIFY_REAL_SESSION=1          run it (it spends tokens and opens tabs)
#   VERIFY_SESSION_MODEL=<m>       the primary's model (default opus)
#   VERIFY_SESSION_WAIT=<secs>     budget for the worker (default 1200)
# shellcheck disable=SC2329 # the predicates run through session_wait
# shellcheck source=tests/verification/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/verification/session-lib.sh disable=SC1091
. "$(dirname "$0")/session-lib.sh"

session_require
WAIT=${VERIFY_SESSION_WAIT:-1200}

project_seed greeter
session_start "fm-verify-restart"

captain_says "ahoy! add my project from $PROJECT_ORIGIN as a local-only project called greeter. then ship one change: add greet.sh with three subcommands, hello, bye and version, each printing one line, plus a README section that documents them. one commit on its own branch. use the opus model for the worker. once the worker is dispatched, end your turn and let your monitoring wake you. when it is done, verify the result by running it and land it on main; you have my approval. tell me when it is landed."

registered() { grep -q '^- greeter ' "$SESSION_HOME/data/projects.md" && [ -d "$SESSION_HOME/projects/greeter/.git" ]; }
session_wait "the project is registered and cloned into the home" 600 registered
dispatched() { [ "$(session_task_ids | wc -l | tr -d ' ')" -ge 1 ]; }
session_wait "a worker is dispatched" 900 dispatched
ID=$(session_task_ids | head -1)
PANE=$(session_meta "$ID" herdr_pane_id)
verify_keep "$ID.meta" "$SESSION_HOME/state/$ID.meta"

yielded() { awk -F'\t' 'NR>1 && $2>0 && ($4=="idle" || $4=="done") {f=1} END{exit !f}' "$SESSION_TICKS"; }
session_wait "the primary ends its turn while the worker is in flight" 600 yielded
OLD_LOCK=$(cat "$SESSION_HOME/state/.lock" 2>/dev/null)
verify_note "session lock before the restart: $OLD_LOCK"

# The restart. A worker that is still building has a status record with no
# done line and a pane that answers.
session_relaunch || verify_done
if [ -f "$SESSION_HOME/state/$ID.meta" ] && session_herdr pane get "$PANE" >/dev/null 2>&1; then
  ok "the worker and its record survived the restart untouched"
else
  bad "the restart disturbed the worker: record $([ -f "$SESSION_HOME/state/$ID.meta" ] && echo kept || echo gone), pane $(session_herdr pane get "$PANE" >/dev/null 2>&1 && echo alive || echo gone)"
fi

captain_says "ahoy, I'm back. carry on where we left off: when the greeter worker is done, verify its result and land it on main, you have my approval, then clean up and tell me."

relocked() { [ -f "$SESSION_HOME/state/.lock" ] && [ "$(cat "$SESSION_HOME/state/.lock" 2>/dev/null)" != "$OLD_LOCK" ]; }
session_wait "the new session takes the home's lock under its own identity" 600 relocked
verify_keep lock-after-restart.txt "$SESSION_HOME/state/.lock"

PROJECT="$SESSION_HOME/projects/greeter"
landed() { [ "$(git -C "$PROJECT" rev-list --count "$PROJECT_BASE..main" 2>/dev/null)" -ge 1 ]; }
session_wait "the new session lands the worker's change on main" "$WAIT" landed
git -C "$PROJECT" log --oneline "$PROJECT_BASE..main" > "$VERIFY_TMP/log.txt"; verify_keep project-log.txt "$VERIFY_TMP/log.txt"
check=$(mktemp -d "$VERIFY_TMP/check.XXXXXX")
git clone -q "$PROJECT" "$check/greeter" 2>/dev/null
got=$(cd "$check/greeter" && bash greet.sh hello 2>&1 | head -1)
if [ -n "$got" ] && [ -f "$check/greeter/README.md" ] && grep -q -i "version" "$check/greeter/README.md"; then
  ok "the landed work does what was asked, checked by running it from main: greet.sh hello printed '$got'"
else
  bad "the landed work is wrong: greet.sh hello printed '$got', README $([ -f "$check/greeter/README.md" ] && echo present || echo missing)"
fi
cleaned() { [ -z "$(session_task_ids)" ] && [ -z "$(session_task_tabs)" ]; }
session_wait "the worker is cleaned up: no task record and no tab left" 600 cleaned

verify_done
