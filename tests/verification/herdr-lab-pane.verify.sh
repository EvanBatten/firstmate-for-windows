#!/usr/bin/env bash
# Feature: a pane firstmate is about to drive runs a shell firstmate can drive.
#
# Issues #63 and #64. Two end-to-end suites fail on Windows the moment they type
# a POSIX command into a pane they made with a plain `workspace create`. The
# production path does not do that: fm_backend_herdr_task_tab_create sends a
# Git Bash launch line first, because a fresh pane here opens a Windows shell.
# If that is the whole story, the same command fails in one pane and works in
# the other, and one fixture change buys both suites back.
#
# Every herdr call is bounded. An earlier hand probe of this question hung for
# hours; a check that cannot answer must say so and stop, not wait forever.
. "$(dirname "$0")/lib.sh"

command -v herdr >/dev/null 2>&1 || verify_skip "herdr is not installed"
command -v jq >/dev/null 2>&1 || verify_skip "jq is not installed"

verify_home
HOME_DIR="$VERIFY_HOME"
export FM_HOME="$HOME_DIR"
BIN="$VERIFY_ROOT/bin"
BACKEND="$VERIFY_ROOT/bin/backends/herdr.sh"
CALL_BUDGET=45
MARKER_BUDGET=60

SESSION=$(timeout 30 bash "$BIN/fm-herdr-lab.sh" name paneshell 2>/dev/null) || SESSION=
[ -n "$SESSION" ] || verify_skip "the herdr lab helper could not name a session within 30s"

lab_teardown() { timeout 90 bash "$BIN/fm-herdr-lab.sh" teardown "$SESSION" >/dev/null 2>&1 || true; }
trap 'lab_teardown; verify_cleanup' EXIT

# herdr_call <args...>: one bounded backend call. Times out rather than hanging.
herdr_call() {
  timeout "$CALL_BUDGET" bash -c '
    . "$1"; shift; session="$1"; shift
    fm_backend_herdr_cli "$session" "$@"
  ' _ "$BACKEND" "$SESSION" "$@" 2>/dev/null
}

if ! timeout 120 bash "$BIN/fm-herdr-lab.sh" prepare "$SESSION" >/dev/null 2>&1; then
  bad "the lab session could not be prepared within 120s, so this machine cannot answer the question"
  verify_done
fi
if ! timeout "$CALL_BUDGET" bash -c '. "$1"; fm_backend_herdr_server_ensure "$2"' _ "$BACKEND" "$SESSION" >/dev/null 2>&1; then
  bad "the lab session's server did not start within ${CALL_BUDGET}s"
  verify_done
fi
ok "an isolated lab session is available"

# pane_settled <pane>: wait until the pane's shell has stopped changing. A task
# pane is handed a Git Bash launch line at creation, and that shell takes time
# to come up; poking before it has would measure the race, not the shell.
pane_settled() {
  local pane=$1 deadline samples=0 info
  deadline=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    info=$(herdr_call pane process-info --pane "$pane")
    if printf '%s' "$info" | jq -e '
      .result.process_info as $p
      | ($p.foreground_processes | length == 1)
        and ($p.foreground_processes[0].pid == $p.shell_pid)
    ' >/dev/null 2>&1; then
      samples=$(( samples + 1 ))
      [ "$samples" -ge 5 ] && return 0
    else
      samples=0
    fi
    sleep 0.5
  done
  return 1
}

# poke <pane> <marker>: type a POSIX one-liner into the pane and see whether it
# ever runs. A pane running a Windows shell simply will not.
poke() {
  local pane=$1 marker=$2 deadline
  rm -f "$marker"
  pane_settled "$pane" || return 1
  herdr_call pane run "$pane" "sh -c 'printf ran > $marker'" >/dev/null
  deadline=$(( $(date +%s) + MARKER_BUDGET ))
  while [ ! -s "$marker" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 1; done
  [ -s "$marker" ]
}

# 1. The shape both failing suites build: a plain workspace, no bootstrap.
RAW_CWD="$VERIFY_TMP/raw"; mkdir -p "$RAW_CWD"
RAW=$(herdr_call workspace create --cwd "$RAW_CWD" --label raw --no-focus)
RAW_PANE=$(printf '%s' "$RAW" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
[ -n "$RAW_PANE" ] && ok "a plain workspace pane can be created" \
  || { bad "a plain workspace pane could not be created within ${CALL_BUDGET}s"; verify_done; }

if poke "$RAW_PANE" "$VERIFY_TMP/raw.marker"; then
  RAW_RUNS=yes
else
  RAW_RUNS=no
fi

# 2. The shape the production path builds, bootstrap included.
TASK_CWD="$VERIFY_TMP/task"; mkdir -p "$TASK_CWD"
WSID=$(printf '%s' "$RAW" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
TAB=$(timeout "$CALL_BUDGET" bash -c '
  . "$1"; fm_backend_herdr_task_tab_create "$2" "$3" "$4" "$5"
' _ "$BACKEND" "$SESSION" "$WSID" "$TASK_CWD" fmverify 2>/dev/null)
TASK_PANE=$(printf '%s' "$TAB" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
[ -n "$TASK_PANE" ] && ok "a task pane can be created the way firstmate creates one" \
  || { bad "a task pane could not be created within ${CALL_BUDGET}s"; verify_done; }

if poke "$TASK_PANE" "$VERIFY_TMP/task.marker"; then
  TASK_RUNS=yes
else
  TASK_RUNS=no
fi

# The verdict. A task pane MUST run what firstmate types into it - that is the
# product guarantee, and everything else here is diagnosis.
[ "$TASK_RUNS" = yes ] \
  && ok "a task pane runs what firstmate types into it" \
  || bad "a task pane did NOT run what firstmate typed into it within ${MARKER_BUDGET}s of its shell settling - this is a product failure, not a fixture one"

if [ "$RAW_RUNS" = no ] && [ "$TASK_RUNS" = yes ]; then
  ok "a plain pane does not, which is why #63 and #64 fail: those fixtures skip the bootstrap"
elif [ "$RAW_RUNS" = yes ] && [ "$TASK_RUNS" = yes ]; then
  bad "both pane kinds run POSIX commands, so the shell is NOT what #63 and #64 trip over - look elsewhere"
elif [ "$RAW_RUNS" = no ] && [ "$TASK_RUNS" = no ]; then
  bad "neither pane kind runs a POSIX command, so the bootstrap is not the difference either"
else
  bad "a plain pane runs POSIX commands but a task pane does not, which is backwards"
fi

verify_done
