# shellcheck shell=bash
# A real firstmate session as the thing under test.
#
# A drive written against lib.sh alone runs bin/ scripts itself, so it plays
# firstmate. A session is the real thing: the code under test is cloned into a
# fresh home, a real primary starts in a Herdr workspace of its own with the
# toolchain a captain has, captain messages are typed into its pane, and every
# claim is read from the home's records, the project's refs and Herdr's own
# tab list. What the agent prints is kept as evidence and is never a claim.
#
# Source lib.sh first, then this file, then call session_require,
# session_start, captain_says and session_wait. Do not call verify_home: a
# session clones the code under test and that clone is the home. verify_done runs the health
# check and the close through the hook this file registers, so no script can
# end without them.
#
# Environment:
#   VERIFY_REAL_SESSION=1    required; a session spends model tokens and opens
#                            tabs in the Herdr session you are looking at
#   VERIFY_SESSION_MODEL     model for the primary (default opus)
#   VERIFY_TOOLS_DIR         the .tools directory to give the clone; default is
#                            the primary checkout's, when it has one
#   VERIFY_PANE_PATH_EXTRA   more PATH entries for the pane, colon separated

SESSION_HOME=
SESSION_WS=
SESSION_PANE=
SESSION_MODEL=${VERIFY_SESSION_MODEL:-opus}
SESSION_BASELINE_WS=
SESSION_PANE_PATH=
SESSION_OBSERVER_PID=
SESSION_CLOSED=0
SESSION_TICKS="$VERIFY_ARTIFACT_RUN/ticks.tsv"
SESSION_TASK_IDS="$VERIFY_ARTIFACT_RUN/task-ids.txt"
SESSION_CAPTAIN_LOG="$VERIFY_ARTIFACT_RUN/captain.log"

# session_scratch: the bare scratch directory a session and its project share.
session_scratch() {
  VERIFY_TMP=${VERIFY_TMP:-$(mktemp -d "${TMPDIR:-/tmp}/fm-verify-$VERIFY_NAME.XXXXXX")}
}

session_require() {
  local tool
  [ "${VERIFY_REAL_SESSION:-}" = 1 ] ||
    verify_skip "a session starts a real firstmate primary and real workers in your Herdr session and spends tokens; set VERIFY_REAL_SESSION=1 to run it"
  [ "${HERDR_ENV:-}" = 1 ] || verify_skip "not inside a Herdr session, so there is no workspace for the session to open in"
  for tool in herdr jq claude git timeout cygpath tar; do
    command -v "$tool" >/dev/null 2>&1 || verify_skip "$tool is not installed"
  done
}

# Every herdr call from here: no MSYS path conversion (a literal /exit must
# arrive as /exit), and bounded.
session_herdr() { MSYS2_ARG_CONV_EXCL='*' timeout 30 herdr "$@"; }

session_pane_path() {
  local p="$SESSION_HOME/.tools/node_modules/.bin" d
  for d in "${LOCALAPPDATA:-}/treehouse" "${LOCALAPPDATA:-}/no-mistakes"; do
    [ -d "$d" ] && p="$p:$(cygpath -u "$d")"
  done
  [ -z "${VERIFY_PANE_PATH_EXTRA:-}" ] || p="$p:$VERIFY_PANE_PATH_EXTRA"
  printf '%s:%s' "$p" "$PATH"
}

session_win_lower() { cygpath -w "$1" 2>/dev/null | tr '[:upper:]' '[:lower:]'; }

session_clone() {
  local branch tools primary sha
  SESSION_HOME="$VERIFY_TMP/firstmate"
  sha=$(git -C "$VERIFY_ROOT" rev-parse HEAD)
  branch=$(git -C "$VERIFY_ROOT" rev-parse --abbrev-ref HEAD)
  if [ "$branch" = HEAD ]; then
    git clone -q -c core.symlinks=true "$VERIFY_ROOT" "$SESSION_HOME" && git -C "$SESSION_HOME" checkout -q "$sha"
  else
    git clone -q -c core.symlinks=true --branch "$branch" "$VERIFY_ROOT" "$SESSION_HOME"
  fi || { bad "the code under test could not be cloned into a fresh home"; verify_done; }
  if [ -n "$(git -C "$VERIFY_ROOT" status --porcelain)" ]; then
    if git -C "$VERIFY_ROOT" diff HEAD --binary | git -C "$SESSION_HOME" apply 2>/dev/null; then
      verify_note "uncommitted changes from $VERIFY_ROOT applied to the clone; untracked files are not"
    else
      verify_note "uncommitted changes from $VERIFY_ROOT could not be applied; the clone is $sha exactly"
    fi
  fi
  primary=$(git -C "$VERIFY_ROOT" rev-parse --path-format=absolute --git-common-dir)/..
  tools=${VERIFY_TOOLS_DIR:-$primary/.tools}
  if [ -d "$tools" ]; then
    ln -s "$(cd "$tools" && pwd -P)" "$SESSION_HOME/.tools" 2>/dev/null || cp -r "$tools" "$SESSION_HOME/.tools"
  else
    verify_note "no .tools directory to give the clone, so the axi tools are whatever the pane PATH has"
  fi
  [ -L "$SESSION_HOME/.claude/skills" ] && [ -d "$SESSION_HOME/.claude/skills" ] ||
    bad "the clone's harness skill link does not resolve, so the primary would have no skills"
}

session_open() {  # <workspace label>
  local label=$1 out bash_win emitter quoted
  SESSION_BASELINE_WS=$(session_herdr workspace list 2>/dev/null | jq -r '.result.workspaces[].workspace_id')
  bash_win=$(cygpath -w "$BASH")
  SESSION_PANE_PATH=$(session_pane_path)
  # The pane's own bash evaluates this at each of its prompts; nothing may
  # expand here.
  # shellcheck disable=SC2016
  emitter='printf "\033]9;9;%s\033\\" "$(cygpath -w "$PWD")"'
  out=$(session_herdr workspace create --cwd "$(cygpath -w "$SESSION_HOME")" --label "$label" --no-focus \
    --env "SHELL=$bash_win" --env "PROMPT_COMMAND=$emitter" \
    --env "FM_PANE_PATH=$(cygpath -w -p "$SESSION_PANE_PATH")" 2>&1) ||
    { bad "Herdr refused to create a workspace for the session: $out"; verify_done; }
  printf '%s\n' "$out" > "$VERIFY_ARTIFACT_RUN/workspace.json"
  SESSION_WS=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty')
  SESSION_PANE=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$SESSION_WS" ] && [ -n "$SESSION_PANE" ] || { bad "Herdr created a workspace but reported no pane for it"; verify_done; }
  quoted=${bash_win//\'/\'\'}
  # pwsh expands these in the pane, not this shell.
  # Git Bash --login keeps an inherited ORIGINAL_PATH and ignores the PATH just
  # assigned, so the toolchain injection never arrives. A Cursor worker also
  # leaks CURSOR_AGENT into this pane, and harness detection trusts that marker
  # ahead of the claude process this session starts.
  # shellcheck disable=SC2016
  session_herdr pane run "$SESSION_PANE" 'if ($env:FM_PANE_PATH) { $env:Path = $env:FM_PANE_PATH }; Remove-Item Env:ORIGINAL_PATH,Env:CURSOR_AGENT,Env:CURSOR_INVOKED_AS -ErrorAction SilentlyContinue; '"& '$quoted' --login" >/dev/null 2>&1
  # wait-output's regex runs on the whole buffer and session_herdr kills it
  # at 30s, so a visible `$` still failed this claim. Read the last lines.
  prompted=0
  deadline=$(( $(date +%s) + 90 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if session_at_shell_prompt; then prompted=1; break; fi
    sleep 2
  done
  if [ "$prompted" -eq 1 ]; then
    ok "the session's pane runs Git Bash with the captain's toolchain on PATH"
  else
    session_snapshot no-bash-prompt
    bad "the session's pane never reached a Git Bash prompt"
    verify_done
  fi
  {
    printf 'workspace %s\npane %s\nmodel %s\npane PATH %s\n' "$SESSION_WS" "$SESSION_PANE" "$SESSION_MODEL" "$SESSION_PANE_PATH"
  } > "$VERIFY_ARTIFACT_RUN/session.txt"
}

session_pane_text() {  # [pane] [lines]
  session_herdr pane read "${1:-$SESSION_PANE}" --source recent-unwrapped --lines "${2:-120}" 2>/dev/null
}

session_snapshot() {  # <label>: keep the firstmate pane as it is now
  session_pane_text > "$VERIFY_TMP/pane.txt" 2>/dev/null || return 0
  verify_keep "pane-$(date -u +%H%M%S)-$1.txt" "$VERIFY_TMP/pane.txt"
}

session_agent_status() {  # [pane]
  session_herdr pane get "${1:-$SESSION_PANE}" 2>/dev/null | jq -r '.result.pane.agent_status // "unknown"'
}

session_at_shell_prompt() {
  session_pane_text "$SESSION_PANE" 6 | grep -q '^\$ *$'
}

session_launch() {
  local deadline text
  session_herdr pane run "$SESSION_PANE" "cd $SESSION_HOME && claude --dangerously-skip-permissions --model $SESSION_MODEL" >/dev/null 2>&1
  deadline=$(( $(date +%s) + 180 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    text=$(session_pane_text "$SESSION_PANE" 60)
    case "$text" in
      *'Yes, I trust this folder'*)
        session_snapshot trust-prompt
        printf '%s\n' "$text" | grep -q '❯ *No' && session_herdr pane send-keys "$SESSION_PANE" Down >/dev/null 2>&1
        # Enter confirms whatever the cursor is on, so wait until the pane
        # shows it on the accept option.
        if session_herdr pane wait-output --regex '❯ *Yes' --timeout 20000 "$SESSION_PANE" >/dev/null 2>&1; then
          session_herdr pane send-keys "$SESSION_PANE" Enter >/dev/null 2>&1
        else
          session_snapshot trust-prompt-stuck
          bad "the trust prompt's cursor never moved to the accept option, so nothing was confirmed"
          verify_done
        fi ;;
      *'bypass permissions on'*)
        ok "a real firstmate primary is running in its own Herdr tab, past its trust prompt"
        session_snapshot ready
        return 0 ;;
    esac
    if session_at_shell_prompt && printf '%s' "$text" | grep -q 'claude --dangerously'; then
      session_snapshot exited
      bad "the primary exited before it was ready. Its pane shows: $(session_last_lines)"
      verify_done
    fi
    sleep 3
  done
  session_snapshot not-ready
  bad "the primary did not become ready within 180s. Its pane shows: $(session_last_lines)"
  verify_done
}

session_last_lines() {
  session_pane_text "$SESSION_PANE" 40 | grep '[[:alpha:]]' | tail -6 | tr -s ' ' | tr '\n' ' ' | cut -c1-600
}

# One line per tick: when, how many task records the home holds, how old the
# watcher beacon is, what the primary is doing, and how many workers have
# reported done. session_health and the scenarios read it.
session_observe_tick() {
  local metas beat age status p dones
  metas=$(session_task_ids | wc -l | tr -d " ")
  dones=$(grep -l "^done:" "$SESSION_HOME"/state/*.status 2>/dev/null | wc -l | tr -d " ")
  beat="$SESSION_HOME/state/.last-watcher-beat"
  if [ -f "$beat" ]; then age=$(( $(date +%s) - $(stat -c %Y "$beat") )); else age=none; fi
  status=$(session_agent_status)
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$metas" "$age" "$status" "$dones" >> "$SESSION_TICKS"
  session_task_ids >> "$SESSION_TASK_IDS"
  for p in $SESSION_PANE $(sed -n 's/^herdr_pane_id=//p' "$SESSION_HOME"/state/*.meta 2>/dev/null); do
    session_pane_text "$p" 300 > "$VERIFY_TMP/observe.tmp" 2>/dev/null || continue
    session_keep_if_changed "pane-${p//:/_}" "$VERIFY_TMP/observe.tmp" "$VERIFY_ARTIFACT_RUN/panes/${p//:/_}"
  done
  {
    ls -la "$SESSION_HOME/state" 2>/dev/null
    for p in "$SESSION_HOME"/state/*.status "$SESSION_HOME"/state/*.meta "$SESSION_HOME"/state/.wake-queue; do
      [ -f "$p" ] || continue
      printf '\n--- %s\n' "${p#"$SESSION_HOME"/}"; cat "$p"
    done
    printf '\n--- data/backlog.md\n'; cat "$SESSION_HOME/data/backlog.md" 2>/dev/null
    printf '\n--- data/projects.md\n'; cat "$SESSION_HOME/data/projects.md" 2>/dev/null
  } > "$VERIFY_TMP/records.tmp" 2>/dev/null
  session_keep_if_changed records "$VERIFY_TMP/records.tmp" "$VERIFY_ARTIFACT_RUN/records/state"
}

session_keep_if_changed() {  # <key> <file> <dest prefix>
  local sum
  sum=$(cksum < "$2" | cut -d' ' -f1)
  [ "$sum" = "$(cat "$VERIFY_TMP/.last-$1" 2>/dev/null)" ] && return 0
  cp "$2" "$3-$(date -u +%Y%m%dT%H%M%SZ).txt"
  printf '%s' "$sum" > "$VERIFY_TMP/.last-$1"
}

session_observer() {
  while :; do
    session_observe_tick
    sleep 10
  done
}

session_start() {  # <workspace label>
  # A session gets a bare scratch directory, never verify_home's empty
  # firstmate-shaped home: a primary that finds one beside its clone may
  # adopt it as FM_HOME, and every record then lands where no claim looks.
  session_scratch
  [ ! -d "$VERIFY_TMP/home" ] || { bad "the scratch directory holds a home/ directory; a session must not be started after verify_home"; verify_done; }
  mkdir -p "$VERIFY_ARTIFACT_RUN/panes" "$VERIFY_ARTIFACT_RUN/records"
  printf 'ts\tmetas\tbeacon_age\tprimary\tdones\n' > "$SESSION_TICKS"
  : > "$SESSION_TASK_IDS"
  : > "$SESSION_CAPTAIN_LOG"
  verify_at_done session_finish
  verify_at_cleanup session_close
  session_clone
  session_open "$1"
  session_launch
  session_observer &
  SESSION_OBSERVER_PID=$!
}

captain_says() {  # <text>
  printf '%s\t%s\n' "$(date -u +%FT%TZ)" "$*" >> "$SESSION_CAPTAIN_LOG"
  verify_note "captain: $*"
  # A primary parked on a question takes a menu choice, not text; a captain
  # who wants to say something else dismisses the question first.
  if [ "$(session_agent_status)" = blocked ]; then
    session_snapshot dismissed-question
    session_herdr pane send-keys "$SESSION_PANE" esc >/dev/null 2>&1
    sleep 2
  fi
  session_herdr workspace focus "$SESSION_WS" >/dev/null 2>&1 || true
  session_herdr pane run "$SESSION_PANE" "$*" >/dev/null 2>&1 || { bad "the captain's message could not be typed into the pane"; return 1; }
  sleep 2
}

# session_wait <claim> <seconds> <command...>: poll the command until it
# succeeds. A primary that exits while we wait fails the claim at once.
session_wait() {
  local claim=$1 secs=$2 deadline
  shift 2
  deadline=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if "$@" >/dev/null 2>&1; then ok "$claim"; return 0; fi
    if session_at_shell_prompt; then
      session_snapshot exited
      bad "$claim: the primary exited first. Its pane last showed: $(session_last_lines)"
      return 1
    fi
    if [ "$(session_agent_status)" = blocked ]; then
      session_snapshot blocked
      bad "$claim: the primary stopped to ask the captain a question. Its pane shows: $(session_last_lines)"
      return 1
    fi
    sleep 5
  done
  session_snapshot timeout
  bad "$claim: not within ${secs}s. The primary's pane shows: $(session_last_lines)"
  return 1
}

# Herdr reports a finished turn as done, a fresh pane as idle, and a turn
# parked on a question as blocked; the first two mean the primary is waiting
# for input, the third means it is waiting for an answer.
session_idle() { case "$(session_agent_status)" in idle|done) return 0 ;; esac; return 1; }

session_task_ids() { find "$SESSION_HOME/state" -maxdepth 1 -name "*.meta" 2>/dev/null | sed "s|.*/||; s|.meta$||"; }
session_meta() { sed -n "s/^$2=//p" "$SESSION_HOME/state/$1.meta" 2>/dev/null | head -1; }
# session_task_tabs: every open tab labelled for a task this home ever
# recorded, as "<tab id>\t<label>\t<workspace id>" lines. Nothing else in
# Herdr is this session's to count or to close.
session_task_tabs() {
  local ids
  ids=$(LC_ALL=C sort -u "$SESSION_TASK_IDS" 2>/dev/null | tr '\n' ' ')
  [ -n "$ids" ] || return 0
  session_herdr tab list 2>/dev/null | jq -r '.result.tabs[] | "\(.tab_id)\t\(.label)\t\(.workspace_id)"' |
    awk -F'\t' -v ids="$ids" 'BEGIN{n=split(ids,a," "); for(i=1;i<=n;i++) want["fm-" a[i]]=1} want[$2]'
}

# session_lock_debris: owner directories no live lock points to, owner
# directories whose recorded pid is dead, and dangling lock links. A held
# lock's owner directory is not debris while its watcher lives.
session_lock_debris() {
  local state="$SESSION_HOME/state" d lock pid
  for d in "$state"/*.lock.owner.* "$state"/.*.lock.owner.*; do
    [ -d "$d" ] || continue
    lock=${d%.owner.*}
    pid=$(cat "$d/pid" 2>/dev/null)
    if [ -L "$lock" ] && [ "$lock" -ef "$d" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then continue; fi
    basename "$d"
  done
  find "$state" -maxdepth 1 -name '*.lock' -xtype l 2>/dev/null | sed 's|.*/||'
}

session_health() {
  local state="$SESSION_HOME/state" n list rows metas stale tabs debris
  n=$(find "$state" -maxdepth 1 -name '*.steal*' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -eq 0 ]; then ok "the home has no lock takeover chain"; else
    list=$(find "$state" -maxdepth 1 -name '*.steal*' | sed 's|.*/||' | head -3 | tr '\n' ' ')
    bad "the home holds $n lock takeover entries: $list"
  fi
  debris=$(session_lock_debris | tr '\n' ' ')
  if [ -z "$debris" ]; then ok "no lock owner is left behind"; else
    bad "lock owners left behind: $debris"
  fi
  rows=$(grep -c . "$state/.wake-queue" 2>/dev/null || true); rows=${rows:-0}
  if [ "$rows" -eq 0 ]; then ok "the notification queue is empty and acknowledged"; else
    bad "$rows notification(s) are still queued: $(head -2 "$state/.wake-queue" | cut -c1-160 | tr '\n' ' ')"
  fi
  n=$(PATH="$SESSION_PANE_PATH" FM_HOME="$SESSION_HOME" bash "$SESSION_HOME/bin/fm-inbox.sh" status 2>/dev/null | sed -n 's/^inbox *\([0-9]*\) note.*/\1/p')
  if [ "${n:-0}" -eq 0 ]; then ok "no captain note is waiting unacknowledged"; else bad "$n captain note(s) still wait for firstmate"; fi
  metas=$(session_task_ids | tr '\n' ' ')
  if [ -z "$metas" ]; then ok "no task record is left in the home"; else bad "task records are left in the home: $metas"; fi
  stale=$(awk -F'\t' 'NR>1 { idle = ($2>0 && ($4=="idle" || $4=="done")); if (idle) run++; else run=0; if (idle && run>=3 && ($3=="none" || $3>=300)) print $1" (beacon "$3")" }' "$SESSION_TICKS" | head -3 | tr '\n' ' ')
  if [ -z "$stale" ]; then ok "the watcher beacon was fresh whenever the primary had been idle with work in flight for three ticks"; else
    bad "the watcher beacon was stale while work was in flight and the primary idle: $stale"
  fi
  tabs=$(session_task_tabs | cut -f2 | tr '\n' ' ')
  if [ -z "$tabs" ]; then ok "no tab labelled for a task of this session is still open"; else bad "tabs labelled for tasks of this session are still open: $tabs"; fi
}

session_stop_watcher() {
  local pid
  pid=$(cat "$SESSION_HOME/state/.watch.lock/pid" 2>/dev/null)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  kill "$pid" 2>/dev/null || true
}

session_destroy_pools() {
  local pool wt common home_win
  home_win=$(session_win_lower "$SESSION_HOME")
  for pool in "$HOME"/.treehouse/*/; do
    [ -d "$pool" ] || continue
    for wt in "$pool"[0-9]*/*/; do
      [ -d "$wt" ] || continue
      common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || continue
      case "$(session_win_lower "$common")" in
        "$home_win"\\*)
          PATH="$SESSION_PANE_PATH" treehouse destroy "$pool" --all --include-unlanded --include-in-use --yes >/dev/null 2>&1 || true
          rm -rf "$pool"
          verify_note "removed the treehouse pool $(basename "$pool") this session created"
          break ;;
      esac
    done
  done
}

# /exit while a shell is still running raises Claude's "Background work is
# running" dialog. Option 1 is "Exit and stop tasks", and Enter accepts it.
session_exit_to_prompt() {
  local deadline text confirmed=0
  session_herdr pane run "$SESSION_PANE" '/exit' >/dev/null 2>&1
  deadline=$(( $(date +%s) + 90 ))
  until session_at_shell_prompt; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    text=$(session_pane_text "$SESSION_PANE" 40)
    if [ "$confirmed" -eq 0 ] && printf '%s' "$text" | grep -q 'Background work is running'; then
      session_snapshot exit-dialog
      session_herdr pane send-keys "$SESSION_PANE" Enter >/dev/null 2>&1
      confirmed=1
    fi
    sleep 3
  done
  return 0
}

session_close() {
  local tab label ws
  [ "$SESSION_CLOSED" = 0 ] && [ -n "$SESSION_PANE" ] || return 0
  SESSION_CLOSED=1
  [ -z "$SESSION_OBSERVER_PID" ] || kill "$SESSION_OBSERVER_PID" 2>/dev/null || true
  session_snapshot final
  if ! session_at_shell_prompt; then
    session_exit_to_prompt || verify_note "the primary did not exit on /exit within 90s"
  fi
  session_stop_watcher
  # Only tabs labelled for this home's tasks, and only a workspace that did
  # not exist before the session and holds one of them.
  session_task_tabs | while IFS=$'\t' read -r tab label ws; do
    session_herdr tab close "$tab" >/dev/null 2>&1 || true
    printf '%s\n' "$SESSION_BASELINE_WS" | grep -qx "$ws" || session_herdr workspace close "$ws" >/dev/null 2>&1 || true
  done
  [ -z "$SESSION_WS" ] || session_herdr workspace close "$SESSION_WS" >/dev/null 2>&1 || true
  session_destroy_pools
  # --force-local: an evidence path spelled C:\... would otherwise be read as
  # a remote host.
  if tar --force-local -cf "$VERIFY_ARTIFACT_RUN/home-records.tar" -C "$SESSION_HOME" state data 2>/dev/null &&
     [ "$(tar --force-local -tf "$VERIFY_ARTIFACT_RUN/home-records.tar" 2>/dev/null | wc -l)" -gt 2 ]; then
    printf 'kept home-records.tar\n' >> "$VERIFY_TRANSCRIPT"
  else
    verify_note "the home's state/ and data/ could not be archived; the records/ snapshots are what remains"
  fi
}

session_finish() {
  [ "$SESSION_CLOSED" = 0 ] && [ -n "$SESSION_PANE" ] || return 0
  local deadline=$(( $(date +%s) + 300 ))
  until session_idle; do
    [ "$(date +%s)" -lt "$deadline" ] || { verify_note "the primary was still working 300 s after the last claim; the health check runs anyway"; break; }
    sleep 5
  done
  session_health
  session_close
}

# project_seed <name>: a throwaway project with its own local bare origin and
# one commit on main. Sets PROJECT_ORIGIN and PROJECT_BASE.
PROJECT_ORIGIN=
PROJECT_BASE=
project_seed() {
  session_scratch
  local name=$1 seed="$VERIFY_TMP/$1-seed"
  PROJECT_ORIGIN="$VERIFY_TMP/$name.git"
  git init -q --bare -b main "$PROJECT_ORIGIN"
  git clone -q "$PROJECT_ORIGIN" "$seed" 2>/dev/null
  git -C "$seed" config user.email verify@example.invalid
  git -C "$seed" config user.name verification
  git -C "$seed" config core.autocrlf false
  git -C "$seed" checkout -q -b main 2>/dev/null || true
  printf '# %s\n\nA throwaway project for a firstmate verification session.\n' "$name" > "$seed/README.md"
  git -C "$seed" add -A && git -C "$seed" commit -qm "start the $name project" && git -C "$seed" push -q -u origin main
  # shellcheck disable=SC2034 # read by the scenario that called project_seed
  PROJECT_BASE=$(git -C "$PROJECT_ORIGIN" rev-parse main)
  rm -rf "$seed"
}

# session_relaunch: what a captain does when the window was closed and opened
# again. Exits the primary, starts claude again in the same pane, and waits
# for it to be ready; the home, its records and any worker are untouched.
session_relaunch() {
  session_snapshot before-relaunch
  session_exit_to_prompt || { bad "the primary did not exit on /exit within 90 s, so no restart could happen"; return 1; }
  ok "the primary exited on the captain's /exit"
  session_launch
}
