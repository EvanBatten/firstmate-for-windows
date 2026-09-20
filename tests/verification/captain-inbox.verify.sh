#!/usr/bin/env bash
# Feature: the captain can drop a note while firstmate is mid-turn, and that
# note reaches firstmate exactly once and then stops counting as waiting.
. "$(dirname "$0")/lib.sh"

verify_home
HOME_DIR="$VERIFY_HOME"
export FM_HOME="$HOME_DIR"
BIN="$VERIFY_ROOT/bin"

note=$("$BIN/fm-inbox.sh" note "the release notes need a look" 2>&1) \
  || { bad "a note could not be queued"; verify_done; }
id=$(printf '%s' "$note" | sed -n 's/^queued \([A-Za-z0-9-]*\)$/\1/p')
[ -n "$id" ] && ok "the note is queued and names its own id" || bad "the note did not report an id: $note"

"$BIN/fm-inbox.sh" list 2>/dev/null | grep -Fq "$id" \
  && ok "the note is listed as waiting" || bad "the note is not listed as waiting"

"$BIN/fm-inbox.sh" status 2>/dev/null | grep -Eq '1 note' \
  && ok "the read-only status reports it waiting" || bad "the status did not report a waiting note"

drain=$("$BIN/fm-wake-drain.sh" 2>&1)
printf '%s' "$drain" | grep -Fq "$id" \
  && ok "it reaches firstmate as a durable notification" || bad "the note never reached the notification queue"

seq=$(printf '%s' "$drain" | awk '/WAKE_ACK_REQUIRED/ { for (i=1;i<=NF;i++) if ($i=="--ack-through") print $(i+1) }' | tail -1)
gen=$(printf '%s' "$drain" | awk '/WAKE_ACK_REQUIRED/ { for (i=1;i<=NF;i++) if ($i=="--recovery-generation") print $(i+1) }' | tail -1)

"$BIN/fm-inbox.sh" drain --ack "$id" >/dev/null 2>&1 \
  && ok "the note can be acknowledged" || bad "the note could not be acknowledged"
"$BIN/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 \
  && ok "its notification can be acknowledged" || bad "the notification could not be acknowledged"

[ -z "$("$BIN/fm-wake-drain.sh" 2>/dev/null | grep -F "$id")" ] \
  && ok "an acknowledged note is not delivered twice" || bad "the note was delivered again after acknowledgement"

"$BIN/fm-inbox.sh" status 2>/dev/null | grep -Eq '1 note' \
  && bad "the status still counts the handled note as waiting" || ok "the status no longer counts it as waiting"

verify_done
