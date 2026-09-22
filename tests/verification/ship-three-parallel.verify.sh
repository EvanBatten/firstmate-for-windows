#!/usr/bin/env bash
# A real firstmate session, judged from records. The captain registers a
# project and asks for three independent changes in one message. Firstmate
# must dispatch three workers into their own tabs and isolated copies, check
# each result, land all three on the project's main with the captain's
# standing approval, and clean up. Every claim below is read from the home's
# records, Herdr's tab list and the project's refs. The agent's words are
# evidence in the pane snapshots and nothing more.
#
#   VERIFY_REAL_SESSION=1          run it (it spends tokens and opens tabs)
#   VERIFY_SESSION_MODEL=<m>       the primary's model (default opus)
#   VERIFY_SESSION_WAIT=<secs>     budget for the workers (default 1500)
# shellcheck disable=SC2329 # the predicates run through session_wait
# shellcheck source=tests/verification/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/verification/session-lib.sh disable=SC1091
. "$(dirname "$0")/session-lib.sh"

session_require
verify_home
WAIT=${VERIFY_SESSION_WAIT:-1500}

project_seed greeter
session_start "fm-verify-three-ships"

captain_says "ahoy! add my project from $PROJECT_ORIGIN as a local-only project called greeter. then ship three separate changes to it in parallel, one worker each: 1) add greet.sh that prints 'hello from the crew'; 2) add farewell.sh that prints 'goodbye from the crew'; 3) add a VERSION file containing 0.1.0. each change is one commit on its own branch. verify each worker's result by running it. you have my approval to land all three on main once each is verified. tell me when all three are landed."

registered() { grep -q '^- greeter ' "$SESSION_HOME/data/projects.md" && [ -d "$SESSION_HOME/projects/greeter/.git" ]; }
session_wait "the project is registered and cloned into the home" 600 registered

three_dispatched() { [ "$(session_task_ids | wc -l | tr -d ' ')" -ge 3 ]; }
session_wait "three workers are dispatched" "$WAIT" three_dispatched
verify_keep projects.md "$SESSION_HOME/data/projects.md"
verify_keep backlog-after-dispatch.md "$SESSION_HOME/data/backlog.md"

isolated=0 visible=0 ids=$(session_task_ids | tr '\n' ' ')
for id in $ids; do
  wt=$(session_meta "$id" worktree)
  if [ -n "$wt" ] && [ -d "$wt" ] && [ "$(session_win_lower "$wt")" != "$(session_win_lower "$SESSION_HOME/projects/greeter")" ] &&
     [ "$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null)" != "$(git -C "$wt" rev-parse --git-dir 2>/dev/null)" ]; then
    isolated=$((isolated + 1))
  fi
  pane=$(session_meta "$id" herdr_pane_id)
  [ -n "$pane" ] && session_herdr pane get "$pane" >/dev/null 2>&1 && visible=$((visible + 1))
  verify_keep "$id.meta" "$SESSION_HOME/state/$id.meta"
done
if [ "$isolated" -ge 3 ]; then ok "each worker has its own isolated copy of the project"; else bad "only $isolated of the workers has an isolated copy: $ids"; fi
if [ "$visible" -ge 3 ]; then ok "each worker has a pane of its own in Herdr"; else bad "only $visible of the workers has a pane in Herdr: $ids"; fi

all_done() {
  local id
  for id in $(session_task_ids); do grep -Eq '^done:' "$SESSION_HOME/state/$id.status" 2>/dev/null || return 1; done
  [ -n "$(session_task_ids)" ]
}
session_wait "every worker reports its task done" "$WAIT" all_done
for id in $ids; do verify_keep "$id.status" "$SESSION_HOME/state/$id.status"; done

# A local-only project lands on the clone in the home, never on a remote.
PROJECT="$SESSION_HOME/projects/greeter"
landed() { [ "$(git -C "$PROJECT" rev-list --count "$PROJECT_BASE..main" 2>/dev/null)" -ge 3 ]; }
session_wait "all three changes are on the project's main" 900 landed
git -C "$PROJECT" for-each-ref > "$VERIFY_TMP/refs.txt"; verify_keep project-refs.txt "$VERIFY_TMP/refs.txt"
git -C "$PROJECT" log --oneline "$PROJECT_BASE..main" > "$VERIFY_TMP/log.txt"; verify_keep project-log.txt "$VERIFY_TMP/log.txt"

# The landing is the agent's claim. This runs the work.
check=$(mktemp -d "$VERIFY_TMP/check.XXXXXX")
git clone -q "$PROJECT" "$check/greeter" 2>/dev/null
got_greet=$(cd "$check/greeter" && bash greet.sh 2>&1)
got_bye=$(cd "$check/greeter" && bash farewell.sh 2>&1)
got_ver=$(tr -d '[:space:]' < "$check/greeter/VERSION" 2>/dev/null)
if [ "$got_greet" = "hello from the crew" ] && [ "$got_bye" = "goodbye from the crew" ] && [ "$got_ver" = "0.1.0" ]; then
  ok "the three changes do what was asked, checked by running them from main"
else
  bad "the landed work is wrong: greet '$got_greet', farewell '$got_bye', VERSION '$got_ver'"
fi
if [ "$(git -C "$PROJECT" rev-list --count "$PROJECT_BASE..main")" -eq 3 ]; then
  ok "main is exactly three commits ahead of where it started, one per change"
else
  bad "main is $(git -C "$PROJECT" rev-list --count "$PROJECT_BASE..main") commits ahead, not three"
fi

cleaned() { [ -z "$(session_task_ids)" ] && [ -z "$(session_task_tabs)" ]; }
session_wait "every worker is cleaned up: no task record and no tab left" 600 cleaned
verify_keep backlog-final.md "$SESSION_HOME/data/backlog.md"

verify_done
