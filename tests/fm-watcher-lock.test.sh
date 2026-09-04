#!/usr/bin/env bash
# tests/fm-watcher-lock.test.sh - watcher singleton + lock-primitive races +
# PID identity stability + watch-arm liveness + guard warnings. These are
# safety-critical process invariants (a race bug may not reproduce through an
# e2e), so they stay as focused real-process units.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"

# An arm only reports its typed failure after wait_for_healthy_successor has
# spent the whole confirmation budget, so cases that wait for that failure must
# outlast the largest production default (30s on MSYS, 10s elsewhere - see
# ARM_CONFIRM_DEFAULT in bin/fm-watch-arm.sh). This is a ceiling spent only when
# an arm genuinely fails to exit; a passing case returns as soon as it does.
ARM_FAIL_EXIT_POLLS=400

TMP_ROOT=$(fm_test_tmproot fm-watcher-lock-tests)

drain_and_ack() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

test_singleton_start() {
  local dir state fakebin out1 out2 pid1 pid2 live i
  dir=$(make_case singleton)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out1="$dir/watch-one.out"
  out2="$dir/watch-two.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out1" &
  pid1=$!
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out2" &
  pid2=$!
  i=0
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid1" && live=$((live + 1))
    is_live_non_zombie "$pid2" && live=$((live + 1))
    [ "$live" -eq 1 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "expected exactly one live watcher, got $live"
  i=0
  while [ "$i" -lt 50 ] && ! grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null 2>&1; do
    sleep 0.02
    i=$((i + 1))
  done
  grep -h 'watcher: already running pid ' "$out1" "$out2" >/dev/null || fail "second watcher did not report existing singleton"
  kill "$pid1" "$pid2" 2>/dev/null || true
  wait "$pid1" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true
  pass "simultaneous watcher starts leave exactly one live process"
}

test_stale_watch_lock_reclaimed() {
  local dir state fakebin out dead_pid pid live lock_pid i
  dir=$(make_case stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done
  mkdir "$state/.watch.lock"
  printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  live=0
  lock_pid=
  while [ "$i" -lt 50 ]; do
    live=0
    is_live_non_zombie "$pid" && live=1
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    [ "$live" -eq 1 ] && [ "$lock_pid" != "$dead_pid" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$live" -eq 1 ] || fail "watcher did not reclaim stale lock and stay alive"
  [ "$lock_pid" != "$dead_pid" ] || fail "stale watch lock pid was not replaced"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "killed watcher stale lock is reclaimed"
}

test_live_stale_watch_lock_is_actionable() {
  local dir state fakebin out err status
  dir=$(make_case live-stale-lock)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  err="$dir/watch.err"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  status=0
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2> "$err" || status=$?
  [ "$status" -ne 0 ] || fail "watcher silently no-opped behind a live stale holder"
  grep -F 'heartbeat is stale' "$err" >/dev/null || fail "watcher did not explain the stale live lock"
  pass "live watcher lock with stale heartbeat is actionable"
}

test_guard_warnings() {
  # The guard's two operator-visible states, with resilient substrings instead of
  # four copy-coupled tests:
  #   (1) watcher DOWN + queued wakes: a prominent no-watcher banner leads (alarm
  #       title, in-flight count, beacon age, fix command), the queued-wakes
  #       warning follows it, and the guidance is repair-after-drain (never the
  #       old conflicting "restart NOW first").
  #   (2) a fresh watcher and an empty queue: total silence.
  local dir state err first banner_line queue_line pid identity
  dir=$(make_case guard)
  state="$dir/state"
  err="$dir/guard.err"

  # (1) watcher down (no beacon) + two in-flight tasks + a queued wake.
  # FM_ROOT_OVERRIDE points the worktree-tangle check at a non-git dir so it stays
  # inert here; this case is about the watcher-down banner, not the tangle guard.
  # Pin Claude so the host test runner's harness ancestry cannot change this fixture.
  printf 'project=x\n' > "$state/task.meta"
  printf 'project=y\n' > "$state/task2.meta"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "guard heartbeat append failed"
  CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  first=$(grep -v '^[[:space:]]*$' "$err" | head -1)
  case "$first" in
    '●'*) ;;
    *) fail "no-watcher banner is not the first thing the guard prints (got '$first')" ;;
  esac
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$err" >/dev/null || fail "guard banner missing the alarm title"
  grep -F '2 task(s) in flight' "$err" >/dev/null || fail "guard banner missing the in-flight count"
  grep -F 'last beat: never' "$err" >/dev/null || fail "guard banner missing the beacon age"
  grep -F 'guarded operation WILL still run' "$err" >/dev/null || fail "guard banner missing generic continuation wording"
  ! grep -F 'requested message WILL still be sent' "$err" >/dev/null || fail "shared guard used send-specific continuation wording"
  grep -F 'watcher supervision needs Stop-owned automatic recovery' "$err" >/dev/null || fail "guard banner missing neutral automatic-recovery guidance"
  grep -F 'queued wakes pending - drain them' "$err" >/dev/null || fail "guard did not warn about pending queue"
  grep -F 'After draining queued wakes, watcher supervision needs Stop-owned automatic recovery' "$err" >/dev/null || fail "guard did not order neutral automatic recovery after drain"
  ! grep -F 'Restart it NOW, before anything else' "$err" >/dev/null || fail "guard still gave conflicting restart-first instruction"
  ! grep -F 'as the harness-tracked background task' "$err" >/dev/null || fail "guard still printed the old universal background-task repair text"
  banner_line=$(grep -n 'WATCHER DOWN' "$err" | head -1 | cut -d: -f1)
  queue_line=$(grep -n 'queued wakes pending - drain them' "$err" | head -1 | cut -d: -f1)
  [ "$banner_line" -lt "$queue_line" ] || fail "queued-wakes warning printed before the no-watcher banner"

  dir=$(make_case guard-xmode)
  state="$dir/state"
  err="$dir/guard.err"
  mkdir -p "$dir/config"
  printf 'project=x\n' > "$state/task.meta"
  : > "$dir/config/x-mode.env"
  CLAUDECODE=1 PI_CODING_AGENT='' GROK_AGENT='' FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=1 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  grep -F "source '$dir/config/x-mode.env' first" "$err" >/dev/null || fail "guard repair line did not source the X-mode cadence config"

  # (2) live watcher plus fresh beacon, empty queue -> silence.
  dir=$(make_case guard-fresh)
  state="$dir/state"
  err="$dir/guard.err"
  printf 'project=x\n' > "$state/task.meta"
  sleep 60 &
  pid=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") || fail "could not identify fresh guard watcher"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$pid" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  # Non-git FM_ROOT keeps the worktree-tangle check inert so "fresh watcher ->
  # total silence" stays a pure assertion about watcher state.
  FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$ROOT/bin/fm-guard.sh" 2> "$err" >/dev/null || fail "guard failed"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ ! -s "$err" ] || fail "guard warned with a live watcher and fresh beacon: $(cat "$err")"
  pass "guard banner leads when down with pending wakes (repair-after-drain) and stays silent when live and fresh"
}

test_lock_single_winner_under_concurrency() {
  local dir state lockdir marker settled i pids pid wins
  dir=$(make_case lock-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  settled="$dir/settled"
  : > "$marker"
  : > "$settled"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "$$" >> "$3"
        # Hold until every rival has finished its attempt, so the held lock
        # names a live pid for as long as anyone is still deciding; otherwise a
        # late contender legitimately reclaims a dead-pid lock and there are two
        # winners. A fixed sleep here bets that 40 process spawns and 39
        # liveness probes fit inside it, which is false wherever a spawn is
        # slow: on MSYS the one-second bet this replaces loses, and the suite
        # reads a correct lock as broken.
        waited=0
        while [ "$(wc -l < "$4")" -lt "$5" ] && [ "$waited" -lt 600 ]; do
          sleep 0.1
          waited=$((waited + 1))
        done
      fi
      printf "x\n" >> "$4"
    ' _ "$LIB" "$lockdir" "$marker" "$settled" 39 &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one lock winner under concurrency, got $wins"
  pass "concurrent fm_lock_try_acquire yields exactly one winner"
}

test_lock_steals_dead_pid_lock() {
  local dir state lockdir dead rc newpid
  dir=$(make_case lock-dead-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  rc=0
  newpid=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then cat "$2/pid"; else exit 7; fi
  ' _ "$LIB" "$lockdir") || rc=$?
  [ "$rc" -eq 0 ] || fail "acquirer failed to steal a dead-pid stale lock (rc=$rc)"
  [ "$newpid" != "$dead" ] || fail "stale dead-pid lock was not replaced (still $dead)"
  [ -n "$newpid" ] || fail "reclaimed lock has no pid recorded"
  pass "dead-pid stale lock is reclaimed by a single acquirer"
}

test_lock_stale_steal_single_winner_under_concurrency() {
  local dir state lockdir dead marker i pids pid wins
  dir=$(make_case lock-stale-concurrency)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  marker="$dir/wins"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  : > "$marker"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      if fm_lock_try_acquire "$2"; then
        printf "%s\n" "${BASHPID:-$$}" >> "$3"
        sleep 1
      fi
    ' _ "$LIB" "$lockdir" "$marker" &
    pids="$pids $!"
    i=$((i + 1))
  done
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  wins=$(awk 'NF { c++ } END { print c + 0 }' "$marker")
  [ "$wins" -eq 1 ] || fail "expected exactly one stale-lock stealer, got $wins"
  pass "concurrent stale-lock steal yields exactly one winner"
}

test_lock_live_steal_mutex_is_not_reclaimed() {
  local dir state lockdir dead holder_file done_file holder out i lockpid stealpid
  dir=$(make_case lock-live-stealer)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  holder_file="$dir/holder"
  done_file="$dir/contender-done"
  dead=$(dead_pid)
  mkdir "$lockdir"
  printf '%s\n' "$dead" > "$lockdir/pid"
  # The holder keeps the steal mutex until the contender has recorded its
  # answer (bounded at 60 s) rather than for a fixed two seconds: one stale-lock
  # probe costs about two seconds on Git Bash, so a timed hold turns into a bet
  # on the platform and reads a correct refusal as a changed owner.
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2.steal" || exit 7
    printf "%s\n" "${BASHPID:-$$}" > "$3"
    i=0
    while [ "$i" -lt 600 ] && [ ! -e "$4" ]; do
      sleep 0.1
      i=$((i + 1))
    done
    fm_lock_release "$2.steal"
  ' _ "$LIB" "$lockdir" "$holder_file" "$done_file" &
  holder=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$holder_file" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$holder_file" ] || fail "live steal mutex holder did not start"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s lockpid=%s stealpid=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}" "$(cat "$2/pid" 2>/dev/null || true)" "$(cat "$2.steal/pid" 2>/dev/null || true)"
    : > "$3"
  ' _ "$LIB" "$lockdir" "$done_file")
  wait "$holder" || fail "live steal mutex holder failed"
  case "$out" in
    *"rc=1"*) ;;
    *) fail "stale lock was stolen while a live stealer held the mutex: $out" ;;
  esac
  lockpid=${out#*lockpid=}; lockpid=${lockpid%% *}
  stealpid=${out#*stealpid=}; stealpid=${stealpid%% *}
  [ "$lockpid" = "$dead" ] || fail "primary lock changed while live steal mutex was held: $out"
  [ "$stealpid" = "$(cat "$holder_file")" ] || fail "live steal mutex owner changed: $out"
  pass "live steal mutex is not reclaimed"
}

test_lock_does_not_steal_live_lock() {
  local dir state lockdir live out lockpid
  dir=$(make_case lock-live-noop)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  sleep 300 &
  live=$!
  mkdir "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  out=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$out" in
    *"rc=1"*) ;;
    *) fail "live-held lock was acquired instead of refused: $out" ;;
  esac
  case "$out" in
    *"held=$live"*) ;;
    *) fail "live holder pid not reported via FM_LOCK_HELD_PID: $out" ;;
  esac
  lockpid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$lockpid" = "$live" ] || fail "live holder's lock pid was clobbered (got '$lockpid')"
  pass "live-held lock is not stolen"
}

test_lock_empty_pid_uses_minimum_grace() {
  local dir state lockdir out
  dir=$(make_case lock-empty-grace)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  mkdir "$lockdir"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    if fm_lock_try_acquire "$2"; then rc=0; else rc=1; fi
    printf "rc=%s held=%s\n" "$rc" "${FM_LOCK_HELD_PID:-}"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"rc=1"*) ;;
    *) fail "empty mid-acquire lock was stolen with zero stale threshold: $out" ;;
  esac
  [ -d "$lockdir" ] || fail "empty mid-acquire lock dir was removed during grace"
  [ ! -e "$lockdir/pid" ] || fail "empty mid-acquire lock gained a pid during grace"
  pass "empty mid-acquire lock keeps a minimum grace"
}

test_lock_late_claim_loses_after_recreate() {
  local dir state lockdir out
  dir=$(make_case lock-late-claim)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner1=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner1" "$2" || exit 21
    touch -h -t 200001010000 "$2" 2>/dev/null || sleep 2
    if ! fm_lock_try_acquire "$2"; then exit 22; fi
    before=$(cat "$2/pid" 2>/dev/null || true)
    if fm_lock_claim "$2" "$owner1"; then late=won; else late=lost; fi
    after=$(cat "$2/pid" 2>/dev/null || true)
    current_owner=$(readlink "$2" 2>/dev/null || true)
    printf "late=%s before=%s after=%s owner_changed=%s\n" "$late" "$before" "$after" "$([ "$current_owner" != "$owner1" ] && echo yes || echo no)"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "late original claimant succeeded after lock recreation: $out" ;;
  esac
  case "$out" in
    *"owner_changed=yes"*) ;;
    *) fail "stale owner was not replaced before late claim: $out" ;;
  esac
  before=${out#*before=}; before=${before%% *}
  after=${out#*after=}; after=${after%% *}
  [ -n "$before" ] || fail "recreated lock did not record a pid: $out"
  [ "$before" = "$after" ] || fail "late claim changed the recreated lock pid: $out"
  pass "late original claimant cannot claim a recreated lock"
}

test_lock_paused_mid_acquire_claim_fails_during_steal() {
  local dir state lockdir out pid
  dir=$(make_case lock-paused-claim-steal)
  state="$dir/state"
  lockdir="$state/.contend.lock"
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    owner=$(fm_lock_owner_dir "$2") || exit 20
    ln -s "$owner" "$2" || exit 21
    fm_lock_try_acquire "$2.steal" || exit 22
    steal_owner=${FM_LOCK_OWNER_DIR:-}
    if fm_lock_claim "$2" "$owner"; then late=won; else late=lost; fi
    if fm_lock_try_create "$2" "$steal_owner"; then stealer=won; else stealer=lost; fi
    pid=$(cat "$2/pid" 2>/dev/null || true)
    printf "late=%s stealer=%s pid=%s\n" "$late" "$stealer" "$pid"
  ' _ "$LIB" "$lockdir")
  case "$out" in
    *"late=lost"*) ;;
    *) fail "paused claimant succeeded while steal mutex was held: $out" ;;
  esac
  case "$out" in
    *"stealer=won"*) ;;
    *) fail "stealer could not claim after paused claimant backed off: $out" ;;
  esac
  pid=${out#*pid=}; pid=${pid%% *}
  [ -n "$pid" ] || fail "stealer claim did not record a pid: $out"
  pass "paused mid-acquire claimant backs off to active stealer"
}

test_watch_restart_rejects_reused_pid() {
  local dir state fakebin out live pid i
  dir=$(make_case restart-reused-pid)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  sleep 300 &
  live=$!
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "stale watcher identity" > "$state/.watch.lock/pid-identity"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" --restart > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 80 ] && is_live_non_zombie "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  is_live_non_zombie "$pid" \
    && fail "restart did not surface recovery after replacing a reused-pid lock"
  wait "$pid" 2>/dev/null || true
  grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || fail "restart replaced reused-pid lock without surfacing recovery: $(cat "$out")"
  is_live_non_zombie "$live" || fail "restart killed a reused unrelated pid"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "watch restart preserves recovery without signaling a reused pid"
}

test_watch_restart_attaches_to_healthy_peer() {
  local dir state fakebin out peer_ready peer identity armpid status i
  dir=$(make_case restart-healthy-peer)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/restart.out"
  peer_ready="$dir/peer.ready"
  node -e 'const fs = require("node:fs"); process.on("SIGTERM", () => {}); fs.writeFileSync(process.argv[1], "ready\n"); setTimeout(() => {}, 300000)' "$peer_ready" &
  peer=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$peer_ready" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -s "$peer_ready" ]; then
    kill -KILL "$peer" 2>/dev/null || true
    wait "$peer" 2>/dev/null || true
    fail "TERM-resistant peer did not become ready"
  fi
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" --restart > "$out" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$peer" "$out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$peer" "$out" || fail "restart did not attach to the verified healthy peer: $(cat "$out")"
  is_live_non_zombie "$armpid" || fail "restart arm exited instead of following the healthy peer"
  is_live_non_zombie "$peer" || fail "restart killed a TERM-resistant peer unexpectedly"
  kill -KILL "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "restart arm did not fail after its attached peer ended without a successor (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$out" || fail "restart arm did not surface the attached cycle end"
  pass "watch restart attaches to a verified healthy peer and later surfaces a successor gap"
}

test_watcher_self_evicts_on_lock_takeover() {
  local dir state fakebin out pid i lock_pid
  dir=$(make_case self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] \
      && [ -s "$state/.watch.lock/pid-identity" ] \
      && [ -e "$state/.last-watcher-beat" ] \
      && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] \
    && [ -s "$state/.watch.lock/pid-identity" ] \
    && [ -e "$state/.last-watcher-beat" ] \
    || fail "watcher did not finish publishing its lock ownership"
  # Simulate a second watcher taking over the singleton lock. $$ (the test
  # runner) is a live pid that is not the watcher.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$pid" 60 || fail "watcher did not self-evict after lock takeover"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  [ "$lock_pid" = "$$" ] || fail "self-evicting watcher clobbered the new holder's lock (got '$lock_pid')"
  pass "watcher self-evicts when the lock pid no longer names it"
}

test_arm_self_eviction_is_loud_without_successor() {
  local dir state fakebin armout armpid watcher_pid status i
  dir=$(make_case arm-self-evict)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  # The arm's confirmation budget bounds a REAL child startup (fork, exec, lock
  # acquisition, beacon publication), so this case holds the arm to production's
  # own budget rather than a shrunken fixture one: a one-second budget turned
  # ordinary CPU contention into an honest "FAILED - no live watcher with a fresh
  # beacon" and broke this case's premise under full-suite load (issue #2844).
  # It stays at the production default rather than something roomier because the
  # same budget bounds the successor wait this case deliberately spends below.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$watcher_pid" "$armout" || fail "arm did not start before self-eviction check"

  # A live but identity-mismatched replacement lock makes the owned watcher
  # self-evict normally. With no verified successor, the arm must turn that
  # otherwise clean empty close into the typed nonzero failure.
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  wait_for_exit "$armpid" "$ARM_FAIL_EXIT_POLLS"
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "self-evicted arm did not fail nonzero (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "self-evicted arm omitted the typed cycle-end failure"
  grep -q "reason=unexpected-clean-exit" "$state/.watch-cycle-exits.log" || fail "self-evicted cycle was not classified in the lifecycle ledger"
  pass "arm turns clean self-eviction without a successor into a typed failure"
}

test_arm_attaches_and_waits_for_live_fresh_watcher() {
  local dir state fakebin out armout i wpid armpid status
  dir=$(make_case arm-attach)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  # A genuinely live watcher with a fresh beacon already holds the singleton.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  # Arming must attach to the existing watcher, NOT start a second one, and NOT
  # exit while the seed still holds the healthy lock.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach to the live watcher"
  ! grep -qF 'watcher: started' "$armout" || fail "arm started a second watcher behind a healthy one"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm reported FAILED for a healthy watcher"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "arm disturbed the healthy watcher's lock"
  is_live_non_zombie "$armpid" || fail "arm exited while the seed watcher was still healthy"
  # After the seed dies without a successor, the attached arm must fail loudly.
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "attached arm did not fail after seed died (status $status)"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "attached arm did not emit the typed cycle-end failure"
  pass "arm attaches to a live fresh watcher and fails loudly when that cycle has no successor"
}

test_attached_arm_signal_is_recorded_in_cycle_ledger() {
  local dir state fakebin out armout i wpid armpid status
  dir=$(make_case attached-arm-signal-ledger)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wpid=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$wpid" ] || fail "seed watcher did not take the lock"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$wpid" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$wpid" "$armout" || fail "arm did not report attach before signal"
  kill -TERM "$armpid" 2>/dev/null || fail "could not signal the attached arm"
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 143 ] || fail "attached arm did not exit with TERM status (got $status)"
  grep -q "arm_pid=$armpid.*watcher_pid=$wpid.*origin=attached.*exit_code=143.*signal=TERM.*reason=arm-interrupted" "$state/.watch-cycle-exits.log" \
    || fail "attached arm signal was not recorded in the lifecycle ledger"
  is_live_non_zombie "$wpid" || fail "signaling an attached arm terminated the peer watcher"
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  pass "attached arm signals record a classified lifecycle entry"
}

test_arm_starts_and_self_heals() {
  # Arming with no confirmable watcher must FORK one and confirm it live + fresh
  # before reporting 'started' - whether the lock is empty (clean start) or held
  # by a dead pid with a fresh-looking leftover beacon (self-heal). It must never
  # report 'healthy' off a dead pid. One row per pre-state, one assertion block.
  local row dir state fakebin armout armpid i lock_pid dead_pid
  for row in clean dead-pid; do
    dir=$(make_case "arm-$row")
    state="$dir/state"
    fakebin="$dir/fakebin"
    armout="$dir/arm.out"
    dead_pid=
    if [ "$row" = dead-pid ]; then
      dead_pid=999999
      while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
      mkdir "$state/.watch.lock"
      printf '%s\n' "$dead_pid" > "$state/.watch.lock/pid"
      printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
      printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
      printf '%s\n' "dead watcher identity" > "$state/.watch.lock/pid-identity"
      touch "$state/.last-watcher-beat"
    fi
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
    armpid=$!
    i=0
    while [ "$i" -lt 80 ]; do
      if [ "$row" = dead-pid ]; then
        is_live_non_zombie "$armpid" || break
      else
        grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
      fi
      sleep 0.1; i=$((i + 1))
    done
    if [ "$row" = dead-pid ]; then
      is_live_non_zombie "$armpid" \
        && fail "arm did not surface recovery after reclaiming a dead-pid lock"
      wait "$armpid" 2>/dev/null || true
      grep -F 'check: rearm-resurface' "$armout" >/dev/null \
        || fail "arm reclaimed dead-pid lock without surfacing recovery: $(cat "$armout")"
      continue
    fi
    grep -qF 'watcher: started pid=' "$armout" || fail "arm ($row) did not report a started watcher"
    ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm ($row) wrongly reported attached/healthy instead of starting a fresh watcher"
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    # The 'started' line prints only after the fresh watcher passed (live pid +
    # fresh beacon), so it doubles as proof the beacon was confirmed fresh.
    grep -F "watcher: started pid=$lock_pid (beacon fresh)" "$armout" >/dev/null \
      || fail "arm ($row) started line did not name the confirmed live watcher (lock '$lock_pid')"
    kill -0 "$lock_pid" 2>/dev/null || fail "arm ($row) confirmed-started watcher is not actually alive"
    kill "$armpid" "$lock_pid" 2>/dev/null || true
    wait "$armpid" 2>/dev/null || true
  done
  pass "arm starts cleanly and resurfaces recovery after a dead-pid lock"
}

test_arm_hup_cleans_child_and_temp_output() {
  local dir state fakebin armout i armpid lock_pid status
  dir=$(make_case arm-hup-cleanup)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF 'watcher: started pid=' "$armout" || fail "arm did not start before HUP cleanup check"
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  kill -HUP "$armpid" 2>/dev/null || fail "could not send HUP to arm"
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -eq 129 ] || fail "arm did not exit with HUP status (got $status)"
  i=0
  while [ "$i" -lt 80 ] && is_live_non_zombie "$lock_pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  ! is_live_non_zombie "$lock_pid" || fail "HUP cleanup left watcher child running"
  ! ls "$state"/.watch-arm-output.* >/dev/null 2>&1 || fail "HUP cleanup left temp output behind"
  pass "arm cleans child watcher and temp output on HUP"
}

test_arm_propagates_immediate_wake_before_confirmation() {
  local dir state fakebin armout drain_out check_file rc
  dir=$(make_case arm-immediate-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/7\n'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register immediate-wake custom check"
  rc=0
  # This case asserts wake propagation, not the confirmation deadline, and its
  # child must also run the registered check before exiting: measured at 1.9-2.3s
  # idle but 9.1-13.1s at 3x CPU oversubscription, against an 11s production
  # budget. An explicit budget takes the deadline out of the assertion and costs
  # nothing on a passing run, because the arm returns as soon as the child
  # settles (issue #2844).
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=0 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=60 "$WATCH_ARM" > "$armout" || rc=$?
  [ "$rc" -eq 0 ] || fail "arm returned non-zero for an immediate wake (status $rc): $(cat "$armout")"
  grep -F "check: $check_file: merged: https://example.test/pr/7" "$armout" >/dev/null || fail "arm did not propagate the immediate check wake"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm printed FAILED after a valid immediate wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after immediate arm wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/7' >/dev/null || fail "immediate check wake was not queued"
  pass "arm propagates an immediate watcher wake before confirmation"
}

test_arm_waits_for_peer_beacon_after_child_stands_down() {
  local dir state fakebin armout peer identity armpid status i
  dir=$(make_case arm-peer-startup-race)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  sleep 300 &
  peer=$!
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$peer") || fail "could not identify peer pid"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$peer" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  # Same budget contract as the self-eviction case: the owned child's real
  # startup and stand-down happen inside the arm's confirmation window, so the
  # window stays production-sized (issue #2844).
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$armout" &
  armpid=$!
  # Synchronize on the owned child declining the live peer lock before making
  # the peer healthy. Sleeping for the same budget the arm spends made this
  # regression fixture race the confirmation deadline under full-suite load,
  # rather than testing the intended successor-handshake boundary.
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: already running pid $peer" "$state"/.watch-arm-output.* 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: already running pid $peer" "$state"/.watch-arm-output.* 2>/dev/null \
    || fail "arm child did not stand down behind the peer watcher"
  touch "$state/.last-watcher-beat"
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$peer" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$peer" "$armout" || fail "arm did not wait for and attach to the peer watcher: $(cat "$armout")"
  ! grep -qF 'watcher: FAILED' "$armout" || fail "arm falsely reported FAILED during peer startup race"
  is_live_non_zombie "$armpid" || fail "arm exited while the peer was still healthy"
  # After the peer dies without a successor, the attached arm must fail loudly.
  kill "$peer" 2>/dev/null || true
  wait "$peer" 2>/dev/null || true
  wait_for_exit "$armpid" "$ARM_FAIL_EXIT_POLLS"
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "attached arm did not fail after peer died (status $status): $(cat "$armout")"
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" || fail "peer-attached arm did not emit the typed cycle-end failure"
  pass "arm attaches to a peer watcher after child stands down and surfaces a missing successor"
}

test_arm_fails_loud_when_no_fresh_watcher_confirmable() {
  local dir state fakebin armout live armpid status
  dir=$(make_case arm-failed-stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  sleep 300 &
  live=$!
  # A live process holds the lock but is NOT a confirmable watcher (no identity),
  # and the beacon is stale. The fresh child cannot steal a LIVE lock, so no
  # watcher can ever be confirmed - the honest answer is FAILED, not healthy.
  mkdir "$state/.watch.lock"
  printf '%s\n' "$live" > "$state/.watch.lock/pid"
  touch -t 200001010000 "$state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=3 "$WATCH_ARM" > "$armout" &
  armpid=$!
  wait_for_exit "$armpid" 120
  status=$?
  [ "$status" -ne 124 ] || fail "arm never returned for an unconfirmable watcher"
  [ "$status" -ne 0 ] || fail "arm exited zero when no fresh watcher could be confirmed"
  grep -F 'watcher: FAILED' "$armout" >/dev/null || fail "arm did not print a typed FAILED line"
  ! grep -qE 'watcher: (healthy|attached)' "$armout" || fail "arm reported attached/healthy off a stale beacon"
  ! grep -qF 'watcher: started' "$armout" || fail "arm falsely reported started"
  is_live_non_zombie "$live" || fail "arm killed the unrelated live lock holder"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "arm reports FAILED and exits non-zero when no fresh watcher can be confirmed"
}

test_cycle_exit_ledger_links_successor_and_stays_bounded() {
  local dir state fakebin armout check_file first_arm successor_arm successor_pid i size iteration
  dir=$(make_case cycle-ledger)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/first-arm.out"
  check_file="$state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'done: synthetic cycle\n'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register cycle-ledger check"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=0 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  first_arm=$!
  wait "$first_arm" || fail "first ledger cycle did not surface its actionable wake"
  grep -q "arm_pid=$first_arm.*reason=actionable-check.*successor=none" "$state/.watch-cycle-exits.log" \
    || fail "first ledger record omitted its actionable classification"
  drain_and_ack "$state" || fail "first ledger wake handling acknowledgement failed"

  rm -f "$check_file" "$state/task.check-trust"
  armout="$dir/successor-arm.out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WATCH_PREDECESSOR_ARM_PID="$first_arm" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  successor_arm=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  successor_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$successor_pid" "$armout" || fail "successor ledger cycle did not start"
  grep -q "arm_pid=$first_arm.*successor=started:$successor_pid" "$state/.watch-cycle-exits.log" \
    || fail "predecessor ledger record was not linked to its verified successor"
  kill -HUP "$successor_arm" 2>/dev/null || true
  wait "$successor_arm" 2>/dev/null || true
  # The forced interruption is a watcher-down interval. Consume the prior
  # delivered wake before beginning independent ledger cycles, just as the
  # recovery handling turn does, so this fixture does not intentionally carry a
  # durable wake into the next arm.
  drain_and_ack "$state" || fail "recovery drain after forced arm interruption failed"

  # Produce enough short cycles to cross a deliberately small cap. The cap is
  # applied by the arm layer itself and keeps only complete ledger records.
  iteration=0
  while [ "$iteration" -lt 6 ]; do
    armout="$dir/bounded-$iteration.out"
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WATCH_CYCLE_LOG_MAX_BYTES=1400 FM_WATCH_CYCLE_LOG_KEEP_LINES=2 FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
    successor_arm=$!
    i=0
    while [ "$i" -lt 80 ]; do
      grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
      sleep 0.1
      i=$((i + 1))
    done
    grep -qF 'watcher: started pid=' "$armout" || fail "bounded ledger cycle $iteration did not start"
    kill -HUP "$successor_arm" 2>/dev/null || true
    wait "$successor_arm" 2>/dev/null || true
    drain_and_ack "$state" \
      || fail "recovery drain after bounded ledger cycle $iteration failed"
    iteration=$((iteration + 1))
  done
  size=$(wc -c < "$state/.watch-cycle-exits.log" | tr -d '[:space:]')
  [ "$size" -le 1400 ] || fail "cycle ledger exceeded its configured cap ($size bytes)"
  ! grep -v '^arm_pid=.*watcher_pid=.*started_at=.*ended_at=.*exit_code=.*signal=.*reason=.*beacon_age=.*lock_before=.*lock_after=.*successor=' "$state/.watch-cycle-exits.log" | grep . >/dev/null \
    || fail "bounded lifecycle ledger contains a partial or malformed record"
  pass "cycle-exit ledger links a verified successor and remains size-capped"
}

test_stopped_watcher_is_live_but_stale_then_exit_is_classified() {
  local dir state fakebin armout armpid watcher_pid i status
  dir=$(make_case stopped-watcher)
  state="$dir/state"
  fakebin="$dir/fakebin"
  armout="$dir/arm.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH_ARM" > "$armout" &
  armpid=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF 'watcher: started pid=' "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  watcher_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  grep -qF "watcher: started pid=$watcher_pid" "$armout" || fail "load counterfactual watcher did not start"

  kill -STOP "$watcher_pid" 2>/dev/null || fail "could not SIGSTOP watcher"
  touch -t 200001010000 "$state/.last-watcher-beat"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_alive "$2"' _ "$LIB" "$watcher_pid" \
    || fail "SIGSTOP watcher was not classified as a live pid"
  if FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_watcher_healthy "$2" "$3" 300 "$4"' _ "$LIB" "$state" "$WATCH" "$dir"; then
    fail "SIGSTOP watcher with a stale beacon was classified healthy"
  fi

  kill -CONT "$watcher_pid" 2>/dev/null || true
  kill -TERM "$watcher_pid" 2>/dev/null || true
  wait_for_exit "$armpid" 80
  status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail "terminated stopped-watcher cycle did not surface nonzero (status $status)"
  grep -Eq 'reason=(nonzero-exit|signal-exit)' "$state/.watch-cycle-exits.log" \
    || fail "terminated watcher exit was not classified in the lifecycle ledger"
  pass "SIGSTOP distinguishes live PID from stale beacon and termination records the exit class"
}

test_pid_identity_is_locale_invariant() {
  # The portable fallback records its process identity under one locale, then
  # arm/guard/turn-end re-read it under the machine's ambient locale. ps's lstart
  # date format follows LC_TIME, so an unpinned read on a non-C locale (e.g. ko_KR)
  # would reject a genuinely live watcher. The fallback pins LC_ALL=C inside
  # fm_pid_identity, so its output must be byte-identical regardless of the caller's
  # exported LC_ALL/LC_TIME. This stays deterministic on CI even where an alternate
  # locale like ko_KR.UTF-8 is not installed (the equality then holds trivially).
  local live no_proc fakebin locale_log baseline via_lc_all via_lc_time
  local real_first real_second observed
  sleep 300 &
  live=$!
  no_proc="$TMP_ROOT/no-proc"
  fakebin="$TMP_ROOT/locale-ps"
  locale_log="$TMP_ROOT/locale-ps.observed"
  mkdir -p "$fakebin"
  : > "$locale_log"
  # The stub renders lstart through date under whatever locale it inherits, so its
  # output really does change when the caller's locale leaks through. Dropping the
  # LC_ALL=C pin in fm_pid_identity therefore breaks the equality assertions below
  # on any host with a second locale installed, and the recorded LC_ALL below keeps
  # the pin asserted even where ko_KR.UTF-8 is missing and date falls back to C.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${LC_ALL-<unset>}" >> "$FAKE_PS_LOCALE_LOG"
stamp=$(date -d @1784094040 '+%a %b %e %H:%M:%S %Y' 2>/dev/null) \
  || stamp=$(date -r 1784094040 '+%a %b %e %H:%M:%S %Y' 2>/dev/null) \
  || stamp='Mon Jul 28 20:00:00 2026'
printf '%s sleep 300\n' "$stamp"
SH
  chmod +x "$fakebin/ps"
  baseline=$(PATH="$fakebin:$PATH" FAKE_PS_LOCALE_LOG="$locale_log" FM_PROC_ROOT_OVERRIDE="$no_proc" LC_ALL=C bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_all=$(PATH="$fakebin:$PATH" FAKE_PS_LOCALE_LOG="$locale_log" FM_PROC_ROOT_OVERRIDE="$no_proc" LC_ALL=ko_KR.UTF-8 bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  via_lc_time=$(PATH="$fakebin:$PATH" FAKE_PS_LOCALE_LOG="$locale_log" FM_PROC_ROOT_OVERRIDE="$no_proc" LC_TIME=ko_KR.UTF-8 bash -c 'unset LC_ALL; . "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  # Keep the real ps fallback exercised wherever it supports the portable -o fields.
  real_first=
  real_second=
  if LC_ALL=C ps -p "$live" -o lstart= -o command= >/dev/null 2>&1; then
    real_first=$(FM_PROC_ROOT_OVERRIDE="$no_proc" LC_ALL=C bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
    real_second=$(FM_PROC_ROOT_OVERRIDE="$no_proc" LC_TIME=ko_KR.UTF-8 bash -c 'unset LC_ALL; . "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  fi
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ -n "$baseline" ] || fail "fm_pid_identity produced no baseline identity under LC_ALL=C"
  [ "$via_lc_all" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_ALL (got '$via_lc_all', want '$baseline')"
  [ "$via_lc_time" = "$baseline" ] || fail "fm_pid_identity varied with exported LC_TIME (got '$via_lc_time', want '$baseline')"
  while read -r observed; do
    [ "$observed" = C ] || fail "fm_pid_identity invoked ps without pinning LC_ALL=C (saw '$observed')"
  done < "$locale_log"
  if [ -n "$real_first" ]; then
    [ "$real_second" = "$real_first" ] \
      || fail "real ps fallback varied with exported LC_TIME (got '$real_second', want '$real_first')"
    pass "fm_pid_identity real ps fallback is locale-invariant"
  else
    pass "real ps fallback locale check skipped where ps -o lstart= is unsupported"
  fi
  pass "fm_pid_identity is locale-invariant across LC_ALL/LC_TIME"
}

FAKE_PROC_CMDLINE_HEX=62617368002f706174682077697468207370616365732f666d2d77617463682e7368002d2d666c616700

write_fake_proc_identity() {
  local proc_root=$1 pid=$2 starttime=$3
  mkdir -p "$proc_root/$pid"
  printf '%s\n' "$pid (watcher ) with spaces) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 $starttime 20 21 22" > "$proc_root/$pid/stat"
  printf 'bash\0/path with spaces/fm-watch.sh\0--flag\0' > "$proc_root/$pid/cmdline"
}

# write_fake_proc_stat <proc_root> <btime>
# The system-wide file. Its btime is written once at boot on Linux and derived
# as `now - uptime` at every read on MSYS (measurement.md row 25). Neither
# dialect may read it for an identity: it is truncated to whole seconds while
# field 22 carries milliseconds, so a btime-anchored sum still moves a second on
# a FRACTIONAL clock step. It is written here so the fake /proc stays a faithful
# model of the machine, and so the fractional case below is the counterexample
# to that arithmetic rather than a fixture that merely omits it.
write_fake_proc_stat() {
  local proc_root=$1 btime=$2
  mkdir -p "$proc_root"
  {
    printf 'cpu 957196696 0 891910304 12956040558\n'
    printf 'cpu0 28768125 0 36727421 859826281\n'
    printf 'btime %s\n' "$btime"
    printf 'processes 0\n'
  } > "$proc_root/stat"
}

# write_fake_proc_uptime <proc_root> <uptime-ms>
# The monotonic clock the MSYS dialect anchors to. Real /proc/uptime publishes
# centiseconds, so the fixture rounds to them too - that quantization is the one
# residual the identity carries and a finer fixture would hide it.
write_fake_proc_uptime() {
  local proc_root=$1 ms=$2
  mkdir -p "$proc_root"
  printf '%s.%02d 1.00\n' "$(( ms / 1000 ))" "$(( ms % 1000 / 10 ))" > "$proc_root/uptime"
}

# fake_uname <fakebin> <answer>
# fm_pid_identity picks its /proc dialect off `uname -s`, which bin/fm-proc-lib.sh
# resolves once at source time, so a PATH stub runs BOTH dialects from any host
# rather than leaving each one assertable on only one machine.
fake_uname() {
  local fakebin=$1 answer=$2
  mkdir -p "$fakebin"
  cat > "$fakebin/uname" <<SH
#!/usr/bin/env bash
printf '%s\n' '$answer'
SH
  chmod +x "$fakebin/uname"
}

# proc_identity <fakebin> <proc_root> <state> <pid> [now-ms]
# The wall clock is a fixture input too, through the seam beside
# FM_PROC_ROOT_OVERRIDE, so a step is a value this suite writes rather than a
# machine state it would have to wait for or provoke.
proc_identity() {
  PATH="$1:$PATH" FM_PROC_ROOT_OVERRIDE="$2" FM_STATE_OVERRIDE="$3" \
    FM_PROC_NOW_OVERRIDE="${5:-}" \
    bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$4"
}

test_linux_proc_pid_identity_ignores_btime_and_detects_pid_reuse() {
  local dir state proc_root fakebin pid before after_time_jump after_pid_reuse
  dir=$(make_case linux-proc-pid-identity)
  state="$dir/state"
  proc_root="$dir/proc"
  fakebin="$dir/uname-linux"
  pid=4242
  fake_uname "$fakebin" Linux
  write_fake_proc_stat "$proc_root" 1784094040
  write_fake_proc_identity "$proc_root" "$pid" 987654

  before=$(proc_identity "$fakebin" "$proc_root" "$state" "$pid") \
    || fail "could not read initial fake Linux process identity"
  write_fake_proc_stat "$proc_root" 1784094016
  after_time_jump=$(proc_identity "$fakebin" "$proc_root" "$state" "$pid") \
    || fail "could not re-read fake Linux process identity after btime change"

  [ "$after_time_jump" = "$before" ] \
    || fail "Linux process identity changed with btime (before '$before', after '$after_time_jump')"
  [ "$before" = "linux-starttime=987654 cmdline-hex=$FAKE_PROC_CMDLINE_HEX" ] \
    || fail "Linux process identity did not combine parsed starttime field 22 with the full cmdline ('$before')"
  pass "Linux process identity is field 22 alone and ignores btime"

  write_fake_proc_identity "$proc_root" "$pid" 987655
  after_pid_reuse=$(proc_identity "$fakebin" "$proc_root" "$state" "$pid") \
    || fail "could not read reused fake Linux pid identity"
  [ "$after_pid_reuse" != "$before" ] || fail "Linux process identity missed changed starttime for reused pid"
  pass "Linux process identity detects pid reuse"
}

# MSYS derives its boot origin as `now - uptime` at every read and anchors field
# 22 to that derived origin, so a step of D raises the origin by D and lowers
# field 22 by exactly D. Uptime itself is monotonic, so the fixture holds it
# still and moves the wall clock, which is what a real step does.
#
# ticks_for <ms> renders a millisecond offset in the host's own clock ticks, so
# both a CLK_TCK of 1000 (this MSYS userland) and of 100 (Linux) are described
# rather than one of them assumed.
MSYS_FIXTURE_UPTIME_MS=1000000
MSYS_FIXTURE_BOOT_MS=1784094040000
MSYS_FIXTURE_START_MS=987054

ticks_for() {  # <ms>
  printf '%s\n' "$(( $1 * MSYS_FIXTURE_CLK_TCK / 1000 ))"
}

# A process whose creation instant sits a few milliseconds short of a whole
# second is the shape issue #17 is about. The origin is `now - uptime`, and
# those two clocks are read a moment apart, so two readers of ONE live process
# legitimately compute creation times a few milliseconds apart - for that
# process's whole life, since the error is fixed by where its true creation
# instant sits rather than redrawn per read. Under the whole-second key the two
# readings landed in different seconds, and every health check of that watcher
# was then a coin toss. The strings still differ here, which is the measured
# jitter and not something the fixture should hide; fm_pid_identity_equal is
# what makes them name one process again.
MSYS_FIXTURE_STRADDLE_START_MS=986993
MSYS_FIXTURE_READ_JITTER_MS=15

# Resolve the host's clock ticks into MSYS_FIXTURE_CLK_TCK. Every MSYS-dialect
# case needs it, and none may assume it: it is 1000 on this MSYS userland and
# 100 on Linux.
msys_fixture_clk_tck() {
  MSYS_FIXTURE_CLK_TCK=$(getconf CLK_TCK 2>/dev/null) || MSYS_FIXTURE_CLK_TCK=
  case "$MSYS_FIXTURE_CLK_TCK" in
    ''|*[!0-9]*|0) fail "getconf CLK_TCK gave no usable value ('$MSYS_FIXTURE_CLK_TCK')" ;;
  esac
}

# createtime_ms_for <boot-ms> <creation-ms>: the milliseconds a reader will
# actually compute for that process at that boot. It is not simply
# <creation-ms>: field 22 is written in the host's own clock ticks, so a host
# with a CLK_TCK of 100 cannot express the fixture's millisecond offset and the
# reader gets back a value up to 10 ms early. The whole-second key hid that
# truncation; a millisecond key states it.
createtime_ms_for() {
  printf '%s\n' "$(( $1 + $(ticks_for "$(( $2 - $1 ))") * 1000 / MSYS_FIXTURE_CLK_TCK ))"
}

# Write the whole fake machine at one wall-clock instant: the monotonic uptime,
# the truncated btime a reader would see, and field 22 as MSYS would render it.
write_fake_msys_machine() {  # <proc_root> <pid> <boot-ms> <creation-ms>
  local proc_root=$1 pid=$2 boot_ms=$3 creation_ms=$4
  write_fake_proc_uptime "$proc_root" "$MSYS_FIXTURE_UPTIME_MS"
  write_fake_proc_stat "$proc_root" "$(( boot_ms / 1000 ))"
  write_fake_proc_identity "$proc_root" "$pid" "$(ticks_for "$(( creation_ms - boot_ms ))")"
}

test_msys_proc_pid_identity_survives_a_clock_step() {
  local dir state proc_root fakebin pid creation_ms now_ms expected
  local before after_step after_fractional_step after_pid_reuse
  dir=$(make_case msys-proc-pid-identity)
  state="$dir/state"
  proc_root="$dir/proc"
  fakebin="$dir/uname-msys"
  pid=4242
  msys_fixture_clk_tck
  creation_ms=$(( MSYS_FIXTURE_BOOT_MS + MSYS_FIXTURE_START_MS ))
  now_ms=$(( MSYS_FIXTURE_BOOT_MS + MSYS_FIXTURE_UPTIME_MS ))
  fake_uname "$fakebin" MINGW64_NT-10.0-26200
  write_fake_msys_machine "$proc_root" "$pid" "$MSYS_FIXTURE_BOOT_MS" "$creation_ms"
  expected="proc-createtime-ms=$(createtime_ms_for "$MSYS_FIXTURE_BOOT_MS" "$creation_ms") cmdline-hex=$FAKE_PROC_CMDLINE_HEX"

  before=$(proc_identity "$fakebin" "$proc_root" "$state" "$pid" "$now_ms") \
    || fail "could not read initial fake MSYS process identity"
  [ "$before" = "$expected" ] \
    || fail "MSYS process identity is not the absolute creation time (got '$before', want '$expected')"

  write_fake_msys_machine "$proc_root" "$pid" "$(( MSYS_FIXTURE_BOOT_MS + 3000 ))" "$creation_ms"
  after_step=$(proc_identity "$fakebin" "$proc_root" "$state" "$pid" "$(( now_ms + 3000 ))") \
    || fail "could not re-read fake MSYS process identity after a clock step"
  [ "$after_step" = "$before" ] \
    || fail "MSYS process identity changed across a 3s clock step (before '$before', after '$after_step')"

  # A real NTP correction is fractional (the measured one was 1.041s, row 25),
  # and this is the phase where a btime-anchored sum breaks: btime rises by one
  # truncated second while field 22 falls by two, so that reading would answer
  # one second early here and evict a live watcher. The full-precision origin
  # has no such seam.
  write_fake_msys_machine "$proc_root" "$pid" "$(( MSYS_FIXTURE_BOOT_MS + 1250 ))" "$creation_ms"
  after_fractional_step=$(proc_identity "$fakebin" "$proc_root" "$state" "$pid" "$(( now_ms + 1250 ))") \
    || fail "could not re-read fake MSYS process identity after a fractional clock step"
  [ "$after_fractional_step" = "$before" ] \
    || fail "MSYS process identity changed across a 1.25s clock step (before '$before', after '$after_fractional_step')"
  pass "MSYS process identity survives a whole-second and a fractional wall-clock step"

  # Second granularity is what that invariance costs, so a reused pid is told
  # apart once it starts in a later second; cmdline-hex covers the rest.
  write_fake_msys_machine "$proc_root" "$pid" "$MSYS_FIXTURE_BOOT_MS" "$(( creation_ms + 1000 ))"
  after_pid_reuse=$(proc_identity "$fakebin" "$proc_root" "$state" "$pid" "$now_ms") \
    || fail "could not read reused fake MSYS pid identity"
  [ "$after_pid_reuse" != "$before" ] \
    || fail "MSYS process identity missed a later creation time for a reused pid"
  pass "MSYS process identity detects pid reuse"
}

# A non-Linux /proc that cannot supply the origin - no readable uptime, no
# CLK_TCK on a curated PATH, no usable clock - must still answer, with the raw
# field 22 under the proc-starttime key this dialect carried before the creation
# time existed. The portable ps fallback cannot be that answer on the only
# platform this branch exists for: Cygwin ps rejects `-o lstart= -o command=`,
# so the stub below fails exactly the way the real one does on this host. Every
# caller compares identities for equality, so no identity at all is not a slow
# path: it is fm_watcher_lock_matches_pid answering "no" for the rest of the
# host's life, fm_watcher_healthy permanently false, and a live watcher re-armed
# every turn.
test_msys_proc_pid_identity_keeps_the_raw_starttime_when_the_origin_is_unreadable() {
  local dir state proc_root fakebin pid identity again
  dir=$(make_case msys-proc-identity-fallback)
  state="$dir/state"
  proc_root="$dir/proc"
  fakebin="$dir/uname-msys-nouptime"
  pid=4242
  fake_uname "$fakebin" MINGW64_NT-10.0-26200
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
printf 'ps: unknown option -- o\n' >&2
exit 1
SH
  chmod +x "$fakebin/ps"
  write_fake_proc_stat "$proc_root" 1784094040
  write_fake_proc_identity "$proc_root" "$pid" 987054

  identity=$(proc_identity "$fakebin" "$proc_root" "$state" "$pid") \
    || fail "a non-Linux /proc with no uptime reported no identity at all"
  [ "$identity" = "proc-starttime=987054 cmdline-hex=$FAKE_PROC_CMDLINE_HEX" ] \
    || fail "a non-Linux /proc with no uptime did not keep the raw field 22 ('$identity')"
  again=$(proc_identity "$fakebin" "$proc_root" "$state" "$pid") \
    || fail "a second read of the same fake process reported no identity"
  [ "$again" = "$identity" ] \
    || fail "two reads of one unreadable-origin process disagreed ('$identity' then '$again')"
  pass "MSYS process identity keeps the raw starttime when the creation origin is unreadable"
}

# The wall clock is read from bash's EPOCHREALTIME, and `date +%s%N` covers a
# bash too old to publish it. A `date` that silently drops %N answers with a
# bare epoch, and taking that as nanoseconds divides the origin by a million:
# the value is stable, so every identity still compares equal and nothing
# reports an error, while the origin has stopped tracking the clock and a step
# once again evicts a live watcher. The identity must refuse such an answer and
# keep the raw field 22 instead, so this stages exactly that `date` with the
# whole rest of the machine readable.
test_msys_proc_pid_identity_rejects_a_nanosecondless_date() {
  local dir state proc_root fakebin pid identity
  dir=$(make_case msys-proc-identity-seconds-only-date)
  state="$dir/state"
  proc_root="$dir/proc"
  fakebin="$dir/uname-msys-secondsdate"
  pid=4242
  fake_uname "$fakebin" MINGW64_NT-10.0-26200
  cat > "$fakebin/date" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 1784095040
SH
  chmod +x "$fakebin/date"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
printf 'ps: unknown option -- o\n' >&2
exit 1
SH
  chmod +x "$fakebin/ps"
  msys_fixture_clk_tck
  write_fake_msys_machine "$proc_root" "$pid" "$MSYS_FIXTURE_BOOT_MS" \
    "$(( MSYS_FIXTURE_BOOT_MS + MSYS_FIXTURE_START_MS ))"

  # EPOCHREALTIME is unset in the reading shell so the `date` branch is the one
  # under test; without the seam the override would answer before either.
  identity=$(PATH="$fakebin:$PATH" FM_PROC_ROOT_OVERRIDE="$proc_root" \
    FM_STATE_OVERRIDE="$state" \
    bash -c 'unset EPOCHREALTIME; . "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") \
    || fail "a seconds-only date reported no identity at all"
  case "$identity" in
    proc-createtime-ms=*) fail "a seconds-only date was accepted as a creation origin ('$identity')" ;;
  esac
  [ "$identity" = "proc-starttime=$(ticks_for "$MSYS_FIXTURE_START_MS") cmdline-hex=$FAKE_PROC_CMDLINE_HEX" ] \
    || fail "a seconds-only date did not keep the raw field 22 ('$identity')"
  pass "MSYS process identity refuses a date that answers without nanoseconds"
}

# A bash too old for EPOCHREALTIME forks `date` for every wall-clock read, and
# a forked pair's spread would measure the fork rather than the scheduler, so
# such a host takes one unbracketed sample at the one-fork cost it always paid
# and keeps the pre-fix read residual. This stages that bash with a `date` that
# answers with nanoseconds and counts how many times it was asked.
test_msys_proc_pid_identity_takes_one_forked_sample_without_epochrealtime() {
  local dir state proc_root fakebin pid creation_ms now_ms expected identity date_log calls
  dir=$(make_case msys-proc-identity-forked-date)
  state="$dir/state"
  proc_root="$dir/proc"
  fakebin="$dir/uname-msys-forkeddate"
  date_log="$dir/date-calls"
  pid=4242
  msys_fixture_clk_tck
  creation_ms=$(( MSYS_FIXTURE_BOOT_MS + MSYS_FIXTURE_START_MS ))
  now_ms=$(( MSYS_FIXTURE_BOOT_MS + MSYS_FIXTURE_UPTIME_MS ))
  fake_uname "$fakebin" MINGW64_NT-10.0-26200
  cat > "$fakebin/date" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$date_log"
printf '%s000000\n' $now_ms
SH
  chmod +x "$fakebin/date"
  write_fake_msys_machine "$proc_root" "$pid" "$MSYS_FIXTURE_BOOT_MS" "$creation_ms"
  expected=$(createtime_ms_for "$MSYS_FIXTURE_BOOT_MS" "$creation_ms")

  identity=$(PATH="$fakebin:$PATH" FM_PROC_ROOT_OVERRIDE="$proc_root" \
    FM_STATE_OVERRIDE="$state" \
    bash -c 'unset EPOCHREALTIME; . "$1"; fm_pid_identity "$2"' _ "$LIB" "$pid") \
    || fail "a forked date reported no identity at all"
  [ "$identity" = "proc-createtime-ms=$expected cmdline-hex=$FAKE_PROC_CMDLINE_HEX" ] \
    || fail "a forked date did not record the creation time (got '$identity', want proc-createtime-ms=$expected)"
  calls=$(wc -l < "$date_log" | tr -d '[:space:]')
  [ "$calls" = 1 ] \
    || fail "a bash without EPOCHREALTIME forked date $calls times for one identity read, not once"
  pass "a bash without EPOCHREALTIME records the creation time from one forked date sample"
}

# identity_equal <state> <current> <recorded>: the comparator every consumer of
# fm_pid_identity now routes through, exercised through the same public
# interface they use.
identity_equal() {
  local state=$1
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity_equal "$2" "$3"' _ "$LIB" "$2" "$3"
}

assert_identity_equal() {  # <state> <label> <current> <recorded>
  identity_equal "$1" "$3" "$4" && return 0
  fail "$2: two strings that name one process were rejected ('$3' against '$4')"
}

assert_identity_differs() {  # <state> <label> <current> <recorded>
  identity_equal "$1" "$3" "$4" || return 0
  fail "$2: two strings that name different processes were accepted ('$3' against '$4')"
}

test_msys_proc_pid_identity_straddling_a_second_is_one_process() {
  local dir state proc_root fakebin pid creation_ms now_ms early late early_ms late_ms
  dir=$(make_case msys-proc-identity-straddle)
  state="$dir/state"
  proc_root="$dir/proc"
  fakebin="$dir/uname-msys-straddle"
  pid=4242
  msys_fixture_clk_tck
  creation_ms=$(( MSYS_FIXTURE_BOOT_MS + MSYS_FIXTURE_STRADDLE_START_MS ))
  now_ms=$(( MSYS_FIXTURE_BOOT_MS + MSYS_FIXTURE_UPTIME_MS ))
  fake_uname "$fakebin" MINGW64_NT-10.0-26200
  write_fake_msys_machine "$proc_root" "$pid" "$MSYS_FIXTURE_BOOT_MS" "$creation_ms"

  early=$(proc_identity "$fakebin" "$proc_root" "$state" "$pid" "$now_ms") \
    || fail "could not read the straddling process from the earlier reader"
  late=$(proc_identity "$fakebin" "$proc_root" "$state" "$pid" \
    "$(( now_ms + MSYS_FIXTURE_READ_JITTER_MS ))") \
    || fail "could not read the straddling process from the later reader"
  [ "$early" != "$late" ] \
    || fail "the fixture no longer reproduces read jitter, so this case proves nothing ('$early')"
  case "$early$late" in
    proc-createtime-ms=*proc-createtime-ms=*) ;;
    *) fail "the straddling reads are not the millisecond creation-time dialect ('$early' and '$late')" ;;
  esac
  early_ms=${early#proc-createtime-ms=}
  early_ms=${early_ms%% *}
  late_ms=${late#proc-createtime-ms=}
  late_ms=${late_ms%% *}
  [ $(( early_ms / 1000 )) -ne $(( late_ms / 1000 )) ] \
    || fail "the two readings did not straddle a whole second ($early_ms and $late_ms), so this case proves nothing"
  pass "two readers of one straddling process record it milliseconds apart across a second boundary"

  identity_equal "$state" "$early" "$late" \
    || fail "the later reader rejected the earlier reader's record of the same live process ('$early' against '$late')"
  identity_equal "$state" "$late" "$early" \
    || fail "the earlier reader rejected the later reader's record of the same live process ('$late' against '$early')"
  pass "a straddling process still compares as one process in both directions"
}

# The reader brackets its one uptime read with a wall-clock read on either side
# and pairs the uptime with their midpoint, and FM_PROC_NOW_OVERRIDE hands those
# reads a sequence of instants in order, so a reader that lost the CPU between
# its reads is a value this suite writes rather than a scheduler state it would
# have to provoke. The fixture's uptime file is static and describes the instant
# now_ms, so a pair centred on now_ms is a clean read of the true machine and a
# pair that ends there after a wide spread is a reader that stalled just before
# its uptime read.
#
# One reader may be off by the 10 ms uptime centisecond, 1 ms of tick
# truncation and half the 10 ms spread budget; that sum is the bound the
# comparator's tolerance is built on, and every clean read must land inside it.
MSYS_FIXTURE_READ_BOUND_MS=16

# msys_createtime_ms <label> <identity>: sets MSYS_CREATETIME_MS to the
# milliseconds an identity records, failing the case when the identity is any
# other dialect - a stalled reader must still answer under this key.
msys_createtime_ms() {
  case "$2" in
    "proc-createtime-ms="*" cmdline-hex=$FAKE_PROC_CMDLINE_HEX") ;;
    *) fail "$1: not a millisecond creation-time identity ('$2')" ;;
  esac
  MSYS_CREATETIME_MS=${2#proc-createtime-ms=}
  MSYS_CREATETIME_MS=${MSYS_CREATETIME_MS%% *}
}

assert_within_read_bound() {  # <label> <recorded-ms> <creation-ms>
  local delta
  delta=$(( $2 - $3 ))
  [ "$delta" -ge 0 ] || delta=$(( -delta ))
  [ "$delta" -le "$MSYS_FIXTURE_READ_BOUND_MS" ] \
    || fail "$1: recorded $2 is $delta ms from the true creation instant $3, past the $MSYS_FIXTURE_READ_BOUND_MS ms bound"
}

test_msys_proc_pid_identity_retries_a_stalled_sample() {
  local dir state proc_root fakebin pid creation_ms now_ms expected identity
  dir=$(make_case msys-proc-identity-stalled-sample)
  state="$dir/state"
  proc_root="$dir/proc"
  fakebin="$dir/uname-msys-stalled"
  pid=4242
  msys_fixture_clk_tck
  creation_ms=$(( MSYS_FIXTURE_BOOT_MS + MSYS_FIXTURE_STRADDLE_START_MS ))
  now_ms=$(( MSYS_FIXTURE_BOOT_MS + MSYS_FIXTURE_UPTIME_MS ))
  fake_uname "$fakebin" MINGW64_NT-10.0-26200
  write_fake_msys_machine "$proc_root" "$pid" "$MSYS_FIXTURE_BOOT_MS" "$creation_ms"
  expected=$(createtime_ms_for "$MSYS_FIXTURE_BOOT_MS" "$creation_ms")

  # The reader read the wall clock, lost the CPU for 90 ms, then read uptime
  # and the wall clock back to back; its second sample has no spread at all.
  identity=$(proc_identity "$fakebin" "$proc_root" "$state" "$pid" \
    "$(( now_ms - 90 )) $now_ms $now_ms $now_ms") \
    || fail "could not read the process through a stalled first sample"
  msys_createtime_ms "stalled then clean" "$identity"
  [ "$MSYS_CREATETIME_MS" = "$expected" ] \
    || fail "a reader stalled 90 ms inside its first sample did not record its clean second sample (got $MSYS_CREATETIME_MS, want $expected)"
  assert_within_read_bound "stalled then clean" "$MSYS_CREATETIME_MS" "$creation_ms"
  pass "a reader stalled inside its first sample records its clean second sample"
}

test_msys_proc_pid_identity_keeps_the_least_stalled_sample() {
  local dir state proc_root fakebin pid creation_ms now_ms expected identity
  dir=$(make_case msys-proc-identity-all-stalled)
  state="$dir/state"
  proc_root="$dir/proc"
  fakebin="$dir/uname-msys-all-stalled"
  pid=4242
  msys_fixture_clk_tck
  creation_ms=$(( MSYS_FIXTURE_BOOT_MS + MSYS_FIXTURE_STRADDLE_START_MS ))
  now_ms=$(( MSYS_FIXTURE_BOOT_MS + MSYS_FIXTURE_UPTIME_MS ))
  fake_uname "$fakebin" MINGW64_NT-10.0-26200
  write_fake_msys_machine "$proc_root" "$pid" "$MSYS_FIXTURE_BOOT_MS" "$creation_ms"
  expected=$(createtime_ms_for "$MSYS_FIXTURE_BOOT_MS" "$creation_ms")

  # Four samples, every one past the 10 ms budget, the narrowest neither first
  # nor last: spreads of 90, 60, 30 and 45 ms, each ending at the uptime
  # instant. The 30 ms sample's midpoint sits 15 ms early. A fifth sample would
  # be clean, which is how this also proves the reader stops at four.
  identity=$(proc_identity "$fakebin" "$proc_root" "$state" "$pid" \
    "$(( now_ms - 90 )) $now_ms $(( now_ms - 60 )) $now_ms $(( now_ms - 30 )) $now_ms $(( now_ms - 45 )) $now_ms") \
    || fail "a reader whose every sample stalled reported no identity at all"
  msys_createtime_ms "every sample stalled" "$identity"
  [ "$MSYS_CREATETIME_MS" = "$(( expected - 15 ))" ] \
    || fail "a reader whose every sample stalled did not record the least-stalled sample's midpoint (got $MSYS_CREATETIME_MS, want $(( expected - 15 )))"
  pass "a reader whose every sample stalled records the least-stalled sample under the millisecond key"
}

test_msys_proc_pid_identity_pairs_uptime_with_the_midpoint_of_its_clock_reads() {
  local dir state proc_root fakebin pid creation_ms now_ms expected identity
  dir=$(make_case msys-proc-identity-midpoint)
  state="$dir/state"
  proc_root="$dir/proc"
  fakebin="$dir/uname-msys-midpoint"
  pid=4242
  msys_fixture_clk_tck
  creation_ms=$(( MSYS_FIXTURE_BOOT_MS + MSYS_FIXTURE_STRADDLE_START_MS ))
  now_ms=$(( MSYS_FIXTURE_BOOT_MS + MSYS_FIXTURE_UPTIME_MS ))
  fake_uname "$fakebin" MINGW64_NT-10.0-26200
  write_fake_msys_machine "$proc_root" "$pid" "$MSYS_FIXTURE_BOOT_MS" "$creation_ms"
  expected=$(createtime_ms_for "$MSYS_FIXTURE_BOOT_MS" "$creation_ms")

  # One clean sample 6 ms wide and centred on the uptime instant: the midpoint
  # is the true machine, the earlier read alone would answer 3 ms early and the
  # later read alone 3 ms late.
  identity=$(proc_identity "$fakebin" "$proc_root" "$state" "$pid" \
    "$(( now_ms - 3 )) $(( now_ms + 3 ))") \
    || fail "could not read the process from a clean sample with a small spread"
  msys_createtime_ms "midpoint" "$identity"
  [ "$MSYS_CREATETIME_MS" = "$expected" ] \
    || fail "a clean sample was not paired at the midpoint of its clock reads (got $MSYS_CREATETIME_MS, want $expected; the later read alone gives $(( expected + 3 )))"
  assert_within_read_bound "midpoint" "$MSYS_CREATETIME_MS" "$creation_ms"
  pass "a clean sample pairs uptime with the midpoint of its two clock reads"
}

# The tolerance exists for exactly one dialect and one field. Everything else -
# a different command line, a reused pid, a step-sensitive raw tick count, the
# retired whole-second key, a malformed string - stays byte-exact, because for
# those a difference is a real difference rather than measured clock jitter.
test_pid_identity_equal_is_tolerant_only_where_the_clock_is() {
  local dir state hex other_hex base
  dir=$(make_case pid-identity-equal)
  state="$dir/state"
  mkdir -p "$state"
  hex=$FAKE_PROC_CMDLINE_HEX
  other_hex="${hex%??}61"
  base=1784095027054

  assert_identity_equal "$state" "identical" \
    "proc-createtime-ms=$base cmdline-hex=$hex" "proc-createtime-ms=$base cmdline-hex=$hex"
  assert_identity_equal "$state" "at the tolerance, late" \
    "proc-createtime-ms=$(( base + 100 )) cmdline-hex=$hex" "proc-createtime-ms=$base cmdline-hex=$hex"
  assert_identity_equal "$state" "at the tolerance, early" \
    "proc-createtime-ms=$(( base - 100 )) cmdline-hex=$hex" "proc-createtime-ms=$base cmdline-hex=$hex"
  assert_identity_differs "$state" "one past the tolerance, late" \
    "proc-createtime-ms=$(( base + 101 )) cmdline-hex=$hex" "proc-createtime-ms=$base cmdline-hex=$hex"
  assert_identity_differs "$state" "one past the tolerance, early" \
    "proc-createtime-ms=$(( base - 101 )) cmdline-hex=$hex" "proc-createtime-ms=$base cmdline-hex=$hex"
  pass "the identity comparator absorbs read jitter up to its stated tolerance and no further"

  assert_identity_differs "$state" "pid reuse a second later" \
    "proc-createtime-ms=$(( base + 1000 )) cmdline-hex=$hex" "proc-createtime-ms=$base cmdline-hex=$hex"
  assert_identity_differs "$state" "same instant, different command line" \
    "proc-createtime-ms=$base cmdline-hex=$other_hex" "proc-createtime-ms=$base cmdline-hex=$hex"
  pass "the identity comparator still tells a reused pid and a different command line apart"

  assert_identity_equal "$state" "identical linux-starttime" \
    "linux-starttime=987654 cmdline-hex=$hex" "linux-starttime=987654 cmdline-hex=$hex"
  assert_identity_differs "$state" "linux-starttime one tick apart" \
    "linux-starttime=987655 cmdline-hex=$hex" "linux-starttime=987654 cmdline-hex=$hex"
  assert_identity_equal "$state" "identical proc-starttime" \
    "proc-starttime=987054 cmdline-hex=$hex" "proc-starttime=987054 cmdline-hex=$hex"
  assert_identity_differs "$state" "proc-starttime one tick apart" \
    "proc-starttime=987055 cmdline-hex=$hex" "proc-starttime=987054 cmdline-hex=$hex"
  assert_identity_equal "$state" "identical ps lstart" \
    "Mon Jan  5 12:00:00 2026 /bin/bash /path/fm-watch.sh" \
    "Mon Jan  5 12:00:00 2026 /bin/bash /path/fm-watch.sh"
  assert_identity_differs "$state" "ps lstart one second apart" \
    "Mon Jan  5 12:00:01 2026 /bin/bash /path/fm-watch.sh" \
    "Mon Jan  5 12:00:00 2026 /bin/bash /path/fm-watch.sh"
  pass "the identity comparator keeps every exact dialect byte-exact"

  # The retired whole-second key has no compatibility shim: a lock written by
  # the previous build mismatches once, at upgrade, and is reclaimed - the same
  # one-time cost the move to proc-createtime already paid.
  assert_identity_differs "$state" "millisecond key against the retired second key" \
    "proc-createtime-ms=$base cmdline-hex=$hex" "proc-createtime=$(( base / 1000 )) cmdline-hex=$hex"
  assert_identity_differs "$state" "mixed keys at the same instant" \
    "proc-createtime-ms=$base cmdline-hex=$hex" "linux-starttime=$base cmdline-hex=$hex"
  pass "the identity comparator never compares two different keys as one process"

  assert_identity_differs "$state" "empty current" "" "proc-createtime-ms=$base cmdline-hex=$hex"
  assert_identity_differs "$state" "empty recorded" "proc-createtime-ms=$base cmdline-hex=$hex" ""
  assert_identity_differs "$state" "both empty" "" ""
  assert_identity_differs "$state" "no command line on the current side" \
    "proc-createtime-ms=$base" "proc-createtime-ms=$base cmdline-hex=$hex"
  assert_identity_differs "$state" "no value on the current side" \
    "proc-createtime-ms= cmdline-hex=$hex" "proc-createtime-ms=$base cmdline-hex=$hex"
  assert_identity_differs "$state" "non-numeric value" \
    "proc-createtime-ms=later cmdline-hex=$hex" "proc-createtime-ms=$base cmdline-hex=$hex"
  assert_identity_differs "$state" "truncated key" \
    "proc-createtime-m=$base cmdline-hex=$hex" "proc-createtime-ms=$base cmdline-hex=$hex"
  pass "the identity comparator rejects an empty or malformed reading rather than guessing"
}

# Stage the one thing the defect costs a running fleet: the watcher recorded its
# own identity into its lock, and the arm, guard and turn-end read the same live
# process a moment later and computed it a hair differently. Below, the recorder
# and the checker are two FM_PROC_NOW_OVERRIDE values 15 ms apart across a
# second boundary, over a genuinely live pid so liveness is real and only the
# identity comparison is under test.
watcher_lock_matches() {  # <fakebin> <proc_root> <state> <home> <pid> <now-ms>
  PATH="$1:$PATH" FM_PROC_ROOT_OVERRIDE="$2" FM_STATE_OVERRIDE="$3" \
    FM_PROC_NOW_OVERRIDE="$6" FM_HOME="$4" \
    bash -c '. "$1"; fm_watcher_lock_matches_pid "$2" "$3" "$4" "$5"' \
    _ "$LIB" "$3" "$WATCH" "$5" "$4"
}

watcher_is_healthy() {  # <fakebin> <proc_root> <state> <home> <now-ms>
  PATH="$1:$PATH" FM_PROC_ROOT_OVERRIDE="$2" FM_STATE_OVERRIDE="$3" \
    FM_PROC_NOW_OVERRIDE="$5" FM_HOME="$4" \
    bash -c '. "$1"; fm_watcher_healthy "$2" "$3" 300 "$4"' \
    _ "$LIB" "$3" "$WATCH" "$4"
}

test_watcher_recorded_by_a_straddling_reader_stays_healthy() {
  local dir state proc_root fakebin lockdir live recorder_now checker_now recorded
  dir=$(make_case watcher-healthy-straddle)
  state="$dir/state"
  proc_root="$dir/proc"
  fakebin="$dir/uname-msys-healthy"
  lockdir="$state/.watch.lock"
  msys_fixture_clk_tck
  fake_uname "$fakebin" MINGW64_NT-10.0-26200
  sleep 300 &
  live=$!
  write_fake_msys_machine "$proc_root" "$live" "$MSYS_FIXTURE_BOOT_MS" \
    "$(( MSYS_FIXTURE_BOOT_MS + MSYS_FIXTURE_STRADDLE_START_MS ))"
  recorder_now=$(( MSYS_FIXTURE_BOOT_MS + MSYS_FIXTURE_UPTIME_MS ))
  checker_now=$(( recorder_now + MSYS_FIXTURE_READ_JITTER_MS ))
  recorded=$(proc_identity "$fakebin" "$proc_root" "$state" "$live" "$recorder_now") \
    || fail "the watcher could not record its own identity"
  mkdir -p "$lockdir"
  printf '%s\n' "$live" > "$lockdir/pid"
  printf '%s\n' "$dir" > "$lockdir/fm-home"
  printf '%s\n' "$WATCH" > "$lockdir/watcher-path"
  printf '%s\n' "$recorded" > "$lockdir/pid-identity"
  : > "$state/.last-watcher-beat"

  watcher_lock_matches "$fakebin" "$proc_root" "$state" "$dir" "$live" "$checker_now" \
    || { kill "$live" 2>/dev/null; wait "$live" 2>/dev/null; \
         fail "a live watcher whose lock was recorded 15 ms earlier did not match its own lock"; }
  watcher_is_healthy "$fakebin" "$proc_root" "$state" "$dir" "$checker_now" \
    || { kill "$live" 2>/dev/null; wait "$live" 2>/dev/null; \
         fail "a live watcher whose lock was recorded 15 ms earlier was reported unhealthy"; }

  # The same gate must still reject a genuinely different process, or the case
  # would pass with the identity check disabled entirely.
  printf '%s\n' "proc-createtime-ms=1 cmdline-hex=$FAKE_PROC_CMDLINE_HEX" > "$lockdir/pid-identity"
  if watcher_is_healthy "$fakebin" "$proc_root" "$state" "$dir" "$checker_now"; then
    kill "$live" 2>/dev/null || true
    wait "$live" 2>/dev/null || true
    fail "a lock recorded for an unrelated creation instant was reported healthy"
  fi
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "a watcher recorded by a straddling reader stays healthy and a foreign one still does not"
}

autoarm_claim_abandoned() {  # <fakebin> <proc_root> <state> <now-ms>
  PATH="$1:$PATH" FM_PROC_ROOT_OVERRIDE="$2" FM_STATE_OVERRIDE="$3" \
    FM_PROC_NOW_OVERRIDE="$4" \
    bash -c '. "$1"; fm_autoarm_claim_abandoned "$2" 300' _ "$LIB" "$3"
}

autoarm_release_abandoned() {  # <fakebin> <proc_root> <state> <now-ms>
  PATH="$1:$PATH" FM_PROC_ROOT_OVERRIDE="$2" FM_STATE_OVERRIDE="$3" \
    FM_PROC_NOW_OVERRIDE="$4" \
    bash -c '. "$1"; fm_autoarm_release_abandoned "$2" 300' _ "$LIB" "$3"
}

# <state> <pid> <identity> <outcome>: the lock-holding legacy claim shape, with
# a ledger entry aged past any freshness window.
write_legacy_autoarm_claim() {
  local state=$1 pid=$2 identity=$3 outcome=$4 lock
  lock="$state/.claude-autoarm.lock"
  mkdir -p "$lock"
  printf '%s\n' "$pid" > "$lock/pid"
  printf '%s\n' autoarm > "$lock/role"
  printf '%s\n' "$identity" > "$lock/pid-identity"
  printf 'epoch=464 owner_pid=%s outcome=%s updated_at=1\n' "$pid" "$outcome" \
    > "$state/.claude-autoarm-epoch"
  touch -t 202001010000 "$state/.claude-autoarm-epoch"
}

# The first consumer the issue names: an identity mismatch is read as positive
# proof of abandonment BEFORE the owner, outcome and grace checks, so a live
# owner born in the straddle window had its claim reclaimed and the home
# re-armed on the first mismatching check.
test_autoarm_does_not_abandon_a_live_owner_recorded_by_a_straddling_reader() {
  local dir state proc_root fakebin live recorder_now checker_now recorded
  dir=$(make_case autoarm-straddle-live)
  state="$dir/state"
  proc_root="$dir/proc"
  fakebin="$dir/uname-msys-autoarm"
  msys_fixture_clk_tck
  fake_uname "$fakebin" MINGW64_NT-10.0-26200
  mkdir -p "$state"
  sleep 300 &
  live=$!
  write_fake_msys_machine "$proc_root" "$live" "$MSYS_FIXTURE_BOOT_MS" \
    "$(( MSYS_FIXTURE_BOOT_MS + MSYS_FIXTURE_STRADDLE_START_MS ))"
  recorder_now=$(( MSYS_FIXTURE_BOOT_MS + MSYS_FIXTURE_UPTIME_MS ))
  checker_now=$(( recorder_now + MSYS_FIXTURE_READ_JITTER_MS ))
  recorded=$(proc_identity "$fakebin" "$proc_root" "$state" "$live" "$recorder_now") \
    || { kill "$live" 2>/dev/null; wait "$live" 2>/dev/null; \
         fail "the claim could not record its owner identity"; }
  # outcome=arming with a fresh beacon is a claim still deciding: nothing here
  # is abandonment except, formerly, the straddled identity read.
  write_legacy_autoarm_claim "$state" "$live" "$recorded" arming
  : > "$state/.last-watcher-beat"

  if autoarm_claim_abandoned "$fakebin" "$proc_root" "$state" "$checker_now"; then
    kill "$live" 2>/dev/null || true
    wait "$live" 2>/dev/null || true
    fail "a live owner whose identity was recorded 15 ms earlier was declared abandoned"
  fi
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  pass "a live auto-arm owner recorded by a straddling reader is not declared abandoned"
}

# The second consumer, and the one with the sharp edge: a proven-abandoned
# legacy owner is signalled ONLY when its recorded identity verifies, so a
# straddled read used to leave a live old-build owner running under a lock that
# had already been reclaimed. A differing command line must still refuse.
test_autoarm_release_verifies_a_straddled_identity_before_signalling() {
  local dir state proc_root fakebin live recorder_now checker_now recorded i survivor
  dir=$(make_case autoarm-straddle-release)
  state="$dir/state"
  proc_root="$dir/proc"
  fakebin="$dir/uname-msys-release"
  msys_fixture_clk_tck
  fake_uname "$fakebin" MINGW64_NT-10.0-26200
  mkdir -p "$state"
  sleep 300 &
  live=$!
  write_fake_msys_machine "$proc_root" "$live" "$MSYS_FIXTURE_BOOT_MS" \
    "$(( MSYS_FIXTURE_BOOT_MS + MSYS_FIXTURE_STRADDLE_START_MS ))"
  recorder_now=$(( MSYS_FIXTURE_BOOT_MS + MSYS_FIXTURE_UPTIME_MS ))
  checker_now=$(( recorder_now + MSYS_FIXTURE_READ_JITTER_MS ))
  recorded=$(proc_identity "$fakebin" "$proc_root" "$state" "$live" "$recorder_now") \
    || { kill "$live" 2>/dev/null; wait "$live" 2>/dev/null; \
         fail "the claim could not record its owner identity"; }
  write_legacy_autoarm_claim "$state" "$live" "$recorded" rewake

  autoarm_release_abandoned "$fakebin" "$proc_root" "$state" "$checker_now" \
    || { kill "$live" 2>/dev/null; wait "$live" 2>/dev/null; \
         fail "the proven-abandoned legacy claim was not reclaimed"; }
  i=0
  while [ "$i" -lt 40 ] && kill -0 "$live" 2>/dev/null; do
    sleep 0.05
    i=$((i + 1))
  done
  if kill -0 "$live" 2>/dev/null; then
    kill "$live" 2>/dev/null || true
    wait "$live" 2>/dev/null || true
    fail "a live legacy owner recorded 15 ms earlier was left running under a reclaimed lock"
  fi
  wait "$live" 2>/dev/null || true
  [ ! -e "$state/.claude-autoarm.lock" ] \
    || fail "the reclaim left the legacy owner lock behind"
  pass "a proven-abandoned live legacy owner recorded by a straddling reader is retired with TERM"

  # Same straddle, different command line: unverifiable, so never signalled.
  sleep 300 &
  survivor=$!
  write_fake_msys_machine "$proc_root" "$survivor" "$MSYS_FIXTURE_BOOT_MS" \
    "$(( MSYS_FIXTURE_BOOT_MS + MSYS_FIXTURE_STRADDLE_START_MS ))"
  recorded=$(proc_identity "$fakebin" "$proc_root" "$state" "$survivor" "$recorder_now") \
    || { kill "$survivor" 2>/dev/null; wait "$survivor" 2>/dev/null; \
         fail "the second claim could not record its owner identity"; }
  write_legacy_autoarm_claim "$state" "$survivor" "${recorded%??}61" rewake

  autoarm_release_abandoned "$fakebin" "$proc_root" "$state" "$checker_now" \
    || { kill "$survivor" 2>/dev/null; wait "$survivor" 2>/dev/null; \
         fail "the claim with an unverifiable identity was not reclaimed"; }
  kill -0 "$survivor" 2>/dev/null \
    || fail "a pid whose recorded command line does not verify was signalled anyway"
  kill "$survivor" 2>/dev/null || true
  wait "$survivor" 2>/dev/null || true
  pass "a reclaim still refuses to signal a pid whose recorded command line does not verify"
}

test_stale_watch_reclaim_publishes_before_clear() {
  local dir state lockdir rc token
  dir=$(make_case stale-watch-publish-before-clear)
  state="$dir/state"
  lockdir="$state/.watch.lock"
  mkdir -p "$lockdir"
  printf '99999999\n' > "$lockdir/pid"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_remove_path() {
      if [ "$1" = "$STATE/.watch.lock" ]; then
        kill -KILL "${BASHPID:-$$}"
      fi
      return 1
    }
    fm_lock_try_acquire "$2"
  ' _ "$LIB" "$lockdir" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "interrupted stale watcher reclaim unexpectedly completed"
  [ -e "$lockdir" ] || [ -L "$lockdir" ] \
    || fail "stale watcher lock cleared before recovery publication boundary"
  token=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_recovery_marker_read "$2" || exit 1
    printf "%s\n" "$FM_RECOVERY_MARKER_TOKEN"
  ' _ "$LIB" "$state/.watcher-down") \
    || fail "stale watcher reclaim interruption left no durable recovery evidence"
  case "$token" in
    pending:downtime:*) ;;
    *) fail "stale watcher reclaim published invalid recovery evidence: $token" ;;
  esac

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2" || exit 1
    fm_lock_release "$2"
  ' _ "$LIB" "$lockdir" \
    || fail "successor could not reclaim watcher lock after interrupted clear"
  pass "stale watcher reclaim publishes durable recovery evidence before clear"
}

test_msys_pid_identity_uses_proc() {
  local live identity
  case "$(uname)" in
    MSYS*|MINGW*|CYGWIN*) ;;
    *)
      pass "MSYS /proc process identity regression skipped on non-Windows host"
      return
      ;;
  esac
  sleep 300 &
  live=$!
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live" 2>/dev/null)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  case "$identity" in
    proc-createtime-ms=*" cmdline-hex="*) ;;
    *) fail "MSYS process identity did not use compatible /proc fields ('$identity')" ;;
  esac
  pass "MSYS process identity uses compatible /proc fields"
}

test_singleton_start
test_pid_identity_is_locale_invariant
test_linux_proc_pid_identity_ignores_btime_and_detects_pid_reuse
test_msys_proc_pid_identity_survives_a_clock_step
test_msys_proc_pid_identity_keeps_the_raw_starttime_when_the_origin_is_unreadable
test_msys_proc_pid_identity_rejects_a_nanosecondless_date
test_msys_proc_pid_identity_takes_one_forked_sample_without_epochrealtime
test_msys_proc_pid_identity_straddling_a_second_is_one_process
test_msys_proc_pid_identity_retries_a_stalled_sample
test_msys_proc_pid_identity_keeps_the_least_stalled_sample
test_msys_proc_pid_identity_pairs_uptime_with_the_midpoint_of_its_clock_reads
test_pid_identity_equal_is_tolerant_only_where_the_clock_is
test_watcher_recorded_by_a_straddling_reader_stays_healthy
test_autoarm_does_not_abandon_a_live_owner_recorded_by_a_straddling_reader
test_autoarm_release_verifies_a_straddled_identity_before_signalling
test_msys_pid_identity_uses_proc
test_stale_watch_lock_reclaimed
test_stale_watch_reclaim_publishes_before_clear
test_live_stale_watch_lock_is_actionable
test_guard_warnings
test_lock_single_winner_under_concurrency
test_lock_steals_dead_pid_lock
test_lock_stale_steal_single_winner_under_concurrency
test_lock_live_steal_mutex_is_not_reclaimed
test_lock_does_not_steal_live_lock
test_lock_empty_pid_uses_minimum_grace
test_lock_late_claim_loses_after_recreate
test_lock_paused_mid_acquire_claim_fails_during_steal
test_watch_restart_rejects_reused_pid
test_watch_restart_attaches_to_healthy_peer
test_watcher_self_evicts_on_lock_takeover
test_arm_self_eviction_is_loud_without_successor
test_arm_attaches_and_waits_for_live_fresh_watcher
test_attached_arm_signal_is_recorded_in_cycle_ledger
test_arm_starts_and_self_heals
test_arm_hup_cleans_child_and_temp_output
test_arm_propagates_immediate_wake_before_confirmation
test_arm_waits_for_peer_beacon_after_child_stands_down
test_arm_fails_loud_when_no_fresh_watcher_confirmable
test_cycle_exit_ledger_links_successor_and_stays_bounded
test_stopped_watcher_is_live_but_stale_then_exit_is_classified
