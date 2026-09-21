#!/usr/bin/env bash
# Feature: the captain can drop a note while firstmate is mid-turn, and that
# note reaches firstmate exactly once and then stops counting as waiting.
# shellcheck source=tests/verification/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

verify_home
HOME_DIR="$VERIFY_HOME"
export FM_HOME="$HOME_DIR"
BIN="$VERIFY_ROOT/bin"

note=$("$BIN/fm-inbox.sh" note "the release notes need a look" 2>&1)   || { bad "a note could not be queued"; verify_done; }
id=$(printf '%s' "$note" | sed -n 's/^queued \([A-Za-z0-9-]*\)$/\1/p')
if [ -n "$id" ]; then
  ok "the note is queued and names its own id"
else
  bad "the note did not report an id: $note"
fi

if "$BIN/fm-inbox.sh" list 2>/dev/null | grep -Fq "$id"; then
  ok "the note is listed as waiting"
else
  bad "the note is not listed as waiting"
fi

if "$BIN/fm-inbox.sh" status 2>/dev/null | grep -Eq '1 note'; then
  ok "the read-only status reports it waiting"
else
  bad "the status did not report a waiting note"
fi

drain=$("$BIN/fm-wake-drain.sh" 2>&1)
if printf '%s' "$drain" | grep -Fq "$id"; then
  ok "it reaches firstmate as a durable notification"
else
  bad "the note never reached the notification queue"
fi

seq=$(printf '%s' "$drain" | awk '/WAKE_ACK_REQUIRED/ { for (i=1;i<=NF;i++) if ($i=="--ack-through") print $(i+1) }' | tail -1)
gen=$(printf '%s' "$drain" | awk '/WAKE_ACK_REQUIRED/ { for (i=1;i<=NF;i++) if ($i=="--recovery-generation") print $(i+1) }' | tail -1)

if "$BIN/fm-inbox.sh" drain --ack "$id" >/dev/null 2>&1; then
  ok "the note can be acknowledged"
else
  bad "the note could not be acknowledged"
fi
if "$BIN/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1; then
  ok "its notification can be acknowledged"
else
  bad "the notification could not be acknowledged"
fi

if ! "$BIN/fm-wake-drain.sh" 2>/dev/null | grep -qF "$id"; then
  ok "an acknowledged note is not delivered twice"
else
  bad "the note was delivered again after acknowledgement"
fi

if "$BIN/fm-inbox.sh" status 2>/dev/null | grep -Eq '1 note'; then
  bad "the status still counts the handled note as waiting"
else
  ok "the status no longer counts it as waiting"
fi

verify_done
