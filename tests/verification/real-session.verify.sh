#!/usr/bin/env bash
# Feature: the whole loop the captain relies on, run for real. From a throwaway
# home, firstmate spawns a real model worker into a new Herdr tab the captain can
# watch, the worker builds a small task in its own isolated copy of a throwaway
# project, its result is checked here rather than believed, the work lands on
# the project's main by fast-forward, and cleanup leaves nothing behind.
#
# This is the only script that starts a model, so it is opt-in: it opens a tab
# in the Herdr session you are looking at and it spends tokens. Everything else
# in it is as isolated as the other scripts - its own home, its own project, its
# own origin - and it never touches a home or a tab it did not create.
#
#   VERIFY_REAL_SESSION=1            run it
#   VERIFY_REAL_SESSION_MODEL=<m>    worker model (default: the harness default)
#   VERIFY_REAL_SESSION_WAIT=<secs>  how long the worker gets (default 900)
# shellcheck source=tests/verification/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

[ "${VERIFY_REAL_SESSION:-}" = 1 ] ||
  verify_skip "this starts a real model worker in your visible Herdr session and spends tokens; set VERIFY_REAL_SESSION=1 to run it"
[ "${HERDR_ENV:-}" = 1 ] ||
  verify_skip "not inside a Herdr session, so there is no workspace for the worker's tab to appear in"
for tool in herdr jq treehouse claude tasks-axi timeout; do
  command -v "$tool" >/dev/null 2>&1 || verify_skip "$tool is not installed"
done

verify_home
HOME_DIR="$VERIFY_HOME"
export FM_HOME="$HOME_DIR"
BIN="$VERIFY_ROOT/bin"
ID="vrs$$"
PROJ="$HOME_DIR/projects/demo"
WAIT=${VERIFY_REAL_SESSION_WAIT:-900}
PANE=
SHOTS=0

# quiet <command...>: the scripts print a banner when their code root is a
# development copy on a feature branch. It is noise here, not a finding.
quiet() { "$@" 2>&1 | grep -v -e '^●' -e 'watcher still down'; return "${PIPESTATUS[0]}"; }

tab_pane() {
  local tab
  tab=$(timeout 30 herdr tab list 2>/dev/null |
    jq -r --arg label "fm-$ID" '.result.tabs[]? | select(.label == $label) | .tab_id' 2>/dev/null | head -1)
  [ -n "$tab" ] || return 0
  timeout 30 herdr pane list 2>/dev/null |
    jq -r --arg tab "$tab" '.result.panes[]? | select(.tab_id == $tab) | .pane_id' 2>/dev/null | head -1
}

tab_exists() {
  timeout 30 herdr tab list 2>/dev/null |
    jq -e --arg label "fm-$ID" '.result.tabs[]? | select(.label == $label)' >/dev/null 2>&1
}

pane_text() { [ -n "$PANE" ] && timeout 30 herdr pane read "$PANE" 2>/dev/null; }

snapshot() {  # <label>: keep what the pane shows right now
  SHOTS=$((SHOTS + 1))
  pane_text > "$VERIFY_TMP/pane.txt" 2>/dev/null || return 0
  verify_keep "$(printf 'pane-%02d-%s.txt' "$SHOTS" "$1")" "$VERIFY_TMP/pane.txt"
}

# Anything this run created and did not finish cleaning up is removed here:
# the task through its own teardown first, then the tab if it survived that.
# shellcheck disable=SC2329  # runs from the EXIT trap below
real_session_cleanup() {
  if [ -e "$HOME_DIR/state/$ID.meta" ]; then
    timeout 600 bash "$BIN/fm-teardown.sh" "$ID" --force >/dev/null 2>&1 || true
  fi
  if [ -n "$PANE" ] && tab_exists; then
    timeout 30 herdr pane close "$PANE" >/dev/null 2>&1 || true
  fi
}
trap 'real_session_cleanup; verify_cleanup' EXIT

git init -q --bare -b main "$VERIFY_TMP/origin.git"
git clone -q "$VERIFY_TMP/origin.git" "$PROJ" 2>/dev/null
git -C "$PROJ" config user.email verify@example.invalid
git -C "$PROJ" config user.name verification
git -C "$PROJ" config core.autocrlf false
git -C "$PROJ" checkout -q -b main 2>/dev/null || true
printf '# demo\n\nA throwaway project for a firstmate verification run.\n' > "$PROJ/README.md"
git -C "$PROJ" add -A && git -C "$PROJ" commit -qm "start the demo project" && git -C "$PROJ" push -q -u origin main
BASE=$(git -C "$PROJ" rev-parse HEAD)

cd "$HOME_DIR" || exit 1
tasks-axi add "$ID" --title "add a greeting script" >/dev/null 2>&1 || { bad "the work item could not be filed"; verify_done; }
quiet bash "$BIN/fm-brief.sh" "$ID" demo --mode local-only >/dev/null || { bad "the worker's instructions could not be scaffolded"; verify_done; }

cat > "$VERIFY_TMP/task.md" <<'TASK'
Add a file named `greet.sh` at the root of this project. When run with `bash greet.sh`, it prints exactly `hello from the crew` and exits 0. When run with one argument, as in `bash greet.sh captain`, it prints `hello captain from the crew`.

Acceptance criteria:
- `bash greet.sh` prints `hello from the crew`.
- `bash greet.sh captain` prints `hello captain from the crew`.
- Add one line to `README.md` that says how to run it.
- One commit on the task branch. Nothing else changes.

This is a small verification task. Do not add tests, tooling, or anything beyond the three points above.
TASK
BRIEF="$HOME_DIR/data/$ID/brief.md"
awk 'FNR==NR { task = task $0 "\n"; next } /\{TASK\}/ { printf "%s", task; next } { print }' \
  "$VERIFY_TMP/task.md" "$BRIEF" > "$VERIFY_TMP/brief.new" && mv "$VERIFY_TMP/brief.new" "$BRIEF"
if grep -q '{TASK}' "$BRIEF"; then bad "the instructions still carry their placeholder"; verify_done; fi
verify_keep brief.md "$BRIEF"
ok "a work item is filed and the worker's instructions are written"

spawn_args=("$ID" "$PROJ" --mode local-only --yolo off --harness claude)
[ -z "${VERIFY_REAL_SESSION_MODEL:-}" ] || spawn_args+=(--model "$VERIFY_REAL_SESSION_MODEL")
timeout 900 bash "$BIN/fm-spawn.sh" "${spawn_args[@]}" > "$VERIFY_TMP/spawn.out" 2> "$VERIFY_TMP/spawn.err"
spawn_rc=$?
verify_keep spawn.out "$VERIFY_TMP/spawn.out"
verify_keep spawn.err "$VERIFY_TMP/spawn.err"
PANE=$(sed -n 's/^herdr_pane_id=//p' "$HOME_DIR/state/$ID.meta" 2>/dev/null)
[ -n "$PANE" ] || PANE=$(tab_pane)

if [ "$spawn_rc" -ne 0 ]; then
  snapshot spawn-failed
  said=$(grep -v '^[[:space:]]*$' "$VERIFY_TMP/pane.txt" 2>/dev/null | grep -v '^\$ *$' | tail -2 | tr '\n' ' ')
  why=$(grep -v -e '^●' -e '^warning:' -e '^NOTICE:' -e '^notice:' "$VERIFY_TMP/spawn.err" | tail -1)
  bad "the spawn failed: ${why:-no reason given}. The worker's pane last showed: ${said:-nothing}"
  verify_done
fi
ok "a spawn starts a worker"

WT=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$ID.meta")
if [ -n "$WT" ] && [ "$WT" != "$PROJ" ] && [ -d "$WT" ] &&
   [ "$(git -C "$WT" rev-parse --git-common-dir 2>/dev/null)" != "$(git -C "$WT" rev-parse --git-dir 2>/dev/null)" ]; then
  ok "the worker has its own isolated copy of the project"
else
  bad "the worker was not given an isolated copy: recorded '$WT'"
fi
if tab_exists; then
  ok "a new tab for the worker is visible in Herdr"
else
  bad "no tab labelled fm-$ID exists in Herdr"
fi

# The trust prompt's default has changed between harness versions, so read
# which option the cursor is on instead of assuming Enter accepts.
deadline=$(( $(date +%s) + 120 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  text=$(pane_text)
  case "$text" in
    *'trust this folder'*)
      snapshot trust-prompt
      if printf '%s\n' "$text" | grep -q '❯ *No'; then
        FM_HOME="$HOME_DIR" quiet bash "$BIN/fm-send.sh" "$ID" --key Down >/dev/null
      fi
      # Enter confirms whatever the cursor is on, so wait until the pane shows
      # it on the accept option. A key sent before the prompt has redrawn is
      # how a worker gets closed by its own supervisor.
      moved=$(( $(date +%s) + 20 ))
      until pane_text | grep -q '❯ *Yes'; do
        [ "$(date +%s)" -lt "$moved" ] || break
        sleep 1
      done
      if pane_text | grep -q '❯ *Yes'; then
        FM_HOME="$HOME_DIR" quiet bash "$BIN/fm-send.sh" "$ID" --key Enter >/dev/null
      else
        snapshot trust-prompt-stuck
        bad "the trust prompt's cursor never moved to the accept option, so nothing was confirmed"
        verify_done
      fi
      break ;;
    *'bypass permissions'*) break ;;
  esac
  sleep 3
done

STATUS="$HOME_DIR/state/$ID.status"
deadline=$(( $(date +%s) + WAIT ))
next_shot=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  grep -Eq '^(done|failed|blocked):' "$STATUS" 2>/dev/null && break
  # A worker that has exited leaves its pane at a shell prompt. Waiting out
  # the whole budget for it would only hide what happened.
  if pane_text | grep -v '^[[:space:]]*$' | tail -1 | grep -q '^\$ *$'; then break; fi
  if [ "$(date +%s)" -ge "$next_shot" ]; then
    snapshot working
    next_shot=$(( $(date +%s) + 30 ))
  fi
  sleep 5
done
snapshot finished
[ ! -e "$STATUS" ] || verify_keep status.txt "$STATUS"
if grep -q '^done:' "$STATUS" 2>/dev/null; then
  ok "the worker reports its task done"
else
  said=$(grep '[[:alpha:]]' "$VERIFY_TMP/pane.txt" 2>/dev/null | tail -8 | tr -s ' ' | tr '\n' ' ' | cut -c1-500)
  bad "the worker stopped or ran out of time (${WAIT}s) without reporting done. Its pane shows: ${said:-nothing}"
  verify_done
fi

# The status line is the worker's claim. This is the check.
TIP=$(git -C "$WT" rev-parse "fm/$ID" 2>/dev/null)
got_plain=$(cd "$WT" && bash greet.sh 2>&1)
got_named=$(cd "$WT" && bash greet.sh captain 2>&1)
if [ "$got_plain" = "hello from the crew" ] && [ "$got_named" = "hello captain from the crew" ]; then
  ok "the work does what was asked, checked by running it"
else
  bad "the work is wrong: got '$got_plain' and '$got_named'"
fi
if [ -z "$(git -C "$PROJ" status --porcelain)" ] && [ "$(git -C "$PROJ" rev-parse HEAD)" = "$BASE" ]; then
  ok "the project's own checkout was never touched while the worker worked"
else
  bad "the project's own checkout changed before anything was landed"
fi

if quiet bash "$BIN/fm-merge-local.sh" "$ID" > "$VERIFY_TMP/merge.txt"; then
  verify_keep merge.txt "$VERIFY_TMP/merge.txt"
  if [ "$(git -C "$PROJ" rev-parse main)" = "$TIP" ] && [ "$(git -C "$PROJ" rev-list --count "$BASE..main")" -eq 1 ]; then
    ok "approved work lands on main by fast-forward"
  else
    bad "the landing reported success but main is not at the worker's commit"
  fi
else
  verify_keep merge.txt "$VERIFY_TMP/merge.txt"
  bad "the landing was refused: $(tail -1 "$VERIFY_TMP/merge.txt")"
fi

if quiet bash "$BIN/fm-teardown.sh" "$ID" > "$VERIFY_TMP/teardown.txt"; then
  ok "cleanup succeeds once the work has landed"
else
  bad "cleanup was refused: $(tail -1 "$VERIFY_TMP/teardown.txt")"
fi
verify_keep teardown.txt "$VERIFY_TMP/teardown.txt"

if tab_exists; then bad "the worker's tab is still open after cleanup"; else ok "the worker's tab is gone"; fi
leftovers=$(find "$HOME_DIR/state" -maxdepth 1 -name "$ID.*" 2>/dev/null | wc -l | tr -d ' ')
if [ "$leftovers" -eq 0 ]; then ok "no task records are left in the home"; else bad "$leftovers task record(s) are left in the home"; fi
if tasks-axi show "$ID" 2>/dev/null | grep -Eq '^  state: done'; then
  ok "the work item is closed"
else
  bad "the work item is not closed"
fi

verify_done
