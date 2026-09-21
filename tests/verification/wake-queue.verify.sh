#!/usr/bin/env bash
# Feature: the durable notification queue delivers work once, holds it until it
# is acknowledged with the generation it was handed, and leaves nothing behind.
# shellcheck source=tests/verification/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

verify_home
HOME_DIR="$VERIFY_HOME"
export FM_HOME="$HOME_DIR"
BIN="$VERIFY_ROOT/bin"
STATE="$HOME_DIR/state"

"$BIN/fm-inbox.sh" note "first" >/dev/null 2>&1
"$BIN/fm-inbox.sh" note "second" >/dev/null 2>&1

drain=$("$BIN/fm-wake-drain.sh" 2>&1)
if [ "$(printf '%s' "$drain" | grep -c 'check: captain inbox note')" -eq 2 ]; then
  ok "every queued item is presented"
else
  bad "the queue did not present both items"
fi

seq=$(printf '%s' "$drain" | awk '/WAKE_ACK_REQUIRED/ { for (i=1;i<=NF;i++) if ($i=="--ack-through") print $(i+1) }' | tail -1)
gen=$(printf '%s' "$drain" | awk '/WAKE_ACK_REQUIRED/ { for (i=1;i<=NF;i++) if ($i=="--recovery-generation") print $(i+1) }' | tail -1)
if [ -n "$seq" ] && [ -n "$gen" ]; then
  ok "the drain names the acknowledgement it requires"
else
  bad "the drain did not name its acknowledgement"
  verify_done
fi

# Unacknowledged work must survive, or an interrupted turn loses it.
if [ "$("$BIN/fm-wake-drain.sh" 2>/dev/null | grep -c 'check: captain inbox note')" -eq 2 ]; then
  ok "work not yet acknowledged is presented again"
else
  bad "unacknowledged work was dropped"
fi

"$BIN/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation 99999.1.bogus >/dev/null 2>&1 # The generation binds an acknowledgement to one recovery episode. With no
# episode pending there is nothing to bind to and any generation is fine, so
# the question only means something once an episode exists.
printf 'pending:handling:fixture
' > "$STATE/.watcher-down"
redrain=$("$BIN/fm-wake-drain.sh" 2>&1)
rgen=$(printf '%s' "$redrain" | awk '/WAKE_ACK_REQUIRED/ { for (i=1;i<=NF;i++) if ($i=="--recovery-generation") print $(i+1) }' | tail -1)
rseq=$(printf '%s' "$redrain" | awk '/WAKE_ACK_REQUIRED/ { for (i=1;i<=NF;i++) if ($i=="--ack-through") print $(i+1) }' | tail -1)
"$BIN/fm-wake-drain.sh" --ack-through "$rseq" --recovery-generation 99999.1.bogus >/dev/null 2>&1 || true
if grep -q "^acked:handling:$rgen$" "$STATE/.watcher-down" 2>/dev/null; then
  bad "a stale generation retired a recovery episode it does not own"
else
  ok "a stale generation cannot retire a recovery episode"
fi
"$BIN/fm-wake-drain.sh" --ack-through "$rseq" --recovery-generation "$rgen" >/dev/null 2>&1 || true
if grep -q "^acked:handling:$rgen$" "$STATE/.watcher-down" 2>/dev/null; then
  ok "the episode's own generation retires it"
else
  bad "the correct generation did not retire the recovery episode"
fi
rm -f "$STATE/.watcher-down"

if "$BIN/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1; then
  ok "the right acknowledgement is accepted"
else
  bad "the correct acknowledgement was refused"
fi

if ! "$BIN/fm-wake-drain.sh" 2>/dev/null | grep -q 'check: captain inbox note'; then
  ok "acknowledged work is gone"
else
  bad "acknowledged work came back"
fi

# Regression, issue #59: an acknowledgement that empties the row set used to
# abandon its temp file, one per acknowledgement, forever.
leftovers=
for leftover in "$STATE"/.wake-rows.consume.* "$STATE"/.main-eligible-rows.tmp.*; do
  [ -e "$leftover" ] || continue
  leftovers="$leftovers $(basename "$leftover")"
done
if [ -z "$leftovers" ]; then
  ok "no temp files are left in the home"
else
  bad "the home was left holding temp files:$leftovers"
fi

verify_done
