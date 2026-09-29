#!/usr/bin/env bash
# A real firstmate session, judged from records: an investigation leaves a
# report, and implementing it promotes the same worker instead of starting a
# second one. The captain asks a question about the project; a scout answers
# it in data/<id>/report.md without touching the project. Then the captain
# authorizes the change; the same task is promoted to a ship task, builds it,
# lands it on the captain's word, and cleanup keeps the report. Every claim is
# read from the home's records and the project's refs.
#
#   VERIFY_REAL_SESSION=1          run it (it spends tokens and opens tabs)
#   VERIFY_SESSION_MODEL=<m>       the primary's model (default opus)
#   VERIFY_SESSION_WAIT=<secs>     budget for each worker phase (default 1200)
# shellcheck disable=SC2329 # the predicates run through session_wait
# shellcheck source=tests/verification/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/verification/session-lib.sh disable=SC1091
. "$(dirname "$0")/session-lib.sh"

session_require
WAIT=${VERIFY_SESSION_WAIT:-1200}

project_seed greeter
session_start "fm-verify-scout"

captain_says "ahoy! add my project from $PROJECT_ORIGIN as a local-only project called greeter. then investigate, without changing anything in the project: which subcommands a friendly greeter CLI called greet.sh should have, and what each should print. I want a short written report I can read, not a change. use the opus model. once the investigation is dispatched, end your turn and let your monitoring wake you; when the report is in, tell me its findings and wait."

registered() { grep -q '^- greeter ' "$SESSION_HOME/data/projects.md" && [ -d "$SESSION_HOME/projects/greeter/.git" ]; }
session_wait "the project is registered and cloned into the home" 600 registered
dispatched() { [ "$(session_task_ids | wc -l | tr -d ' ')" -ge 1 ]; }
session_wait "a scout is dispatched" 900 dispatched
ID=$(session_task_ids | head -1)
verify_keep "$ID.meta" "$SESSION_HOME/state/$ID.meta"
if [ "$(session_meta "$ID" kind)" = scout ]; then ok "the task record says the worker is a scout"; else bad "the task record's kind is '$(session_meta "$ID" kind)', not scout"; fi

REPORT="$SESSION_HOME/data/$ID/report.md"
reported() { [ -s "$REPORT" ] && grep -q -i "greet" "$REPORT"; }
session_wait "the scout leaves a report under data/<id>/report.md" "$WAIT" reported
verify_keep report.md "$REPORT"
PROJECT="$SESSION_HOME/projects/greeter"
if [ "$(git -C "$PROJECT" rev-parse main)" = "$PROJECT_BASE" ] && [ -z "$(git -C "$PROJECT" status --porcelain)" ]; then
  ok "the investigation changed nothing in the project"
else
  bad "the investigation touched the project: main $(git -C "$PROJECT" rev-parse --short main), dirty $(git -C "$PROJECT" status --porcelain | wc -l)"
fi
session_wait "the primary relays the findings and waits for the captain" 600 session_idle

captain_says "good. now implement the first two subcommands your report recommends, one commit on its own branch, verify it by running it, and land it on main; you have my approval. use the same worker rather than starting a second one. tell me when it is landed."

promoted() { [ "$(session_meta "$ID" kind)" = ship ] || [ -s "$SESSION_HOME/data/$ID/ship-instructions.md" ]; }
session_wait "the same task is promoted to a ship task instead of a second one being started" 900 promoted
if [ "$(session_task_ids | wc -l | tr -d ' ')" -eq 1 ]; then ok "still exactly one task record: no duplicate worker"; else bad "task records now: $(session_task_ids | tr '\n' ' ')"; fi
[ ! -s "$SESSION_HOME/data/$ID/ship-instructions.md" ] || verify_keep ship-instructions.md "$SESSION_HOME/data/$ID/ship-instructions.md"

landed() { [ "$(git -C "$PROJECT" rev-list --count "$PROJECT_BASE..main" 2>/dev/null)" -ge 1 ]; }
session_wait "the promoted worker's change lands on main" "$WAIT" landed
git -C "$PROJECT" log --oneline "$PROJECT_BASE..main" > "$VERIFY_TMP/log.txt"; verify_keep project-log.txt "$VERIFY_TMP/log.txt"
check=$(mktemp -d "$VERIFY_TMP/check.XXXXXX")
git clone -q "$PROJECT" "$check/greeter" 2>/dev/null
if [ -f "$check/greeter/greet.sh" ] && out=$(cd "$check/greeter" && bash greet.sh 2>&1 | head -3) && [ -n "$out" ]; then
  ok "the landed greet.sh runs from a fresh clone of main and prints: $(printf '%s' "$out" | head -1 | cut -c1-80)"
else
  bad "the landed work does not run from main: greet.sh $([ -f "$check/greeter/greet.sh" ] && echo present || echo missing)"
fi

cleaned() { [ -z "$(session_task_ids)" ] && [ -z "$(session_task_tabs)" ]; }
session_wait "the worker is cleaned up: no task record and no tab left" 600 cleaned
if [ -s "$REPORT" ]; then ok "the report survives cleanup under data/<id>/report.md"; else bad "cleanup removed the report"; fi

verify_done
