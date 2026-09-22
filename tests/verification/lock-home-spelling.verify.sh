#!/usr/bin/env bash
# Feature: a home that can be reached by two spellings of its path is still one
# home to the lock. On Git Bash the system temp directory is mounted at /tmp,
# so C:\Users\<you>\AppData\Local\Temp\x is both /tmp/x and
# /c/Users/<you>/AppData/Local/Temp/x, and a harness hands firstmate the second
# spelling. Every script that takes a state/ lock must work under either one,
# leave no lock behind, and never grow a takeover chain (#82).
# shellcheck source=tests/verification/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

verify_home
BIN="$VERIFY_ROOT/bin"

# The other spelling of the same directory. Where the temp directory has only
# one spelling the two drives below are the same drive, and both must pass.
other_spelling() {
  local win
  command -v cygpath >/dev/null 2>&1 || { printf '%s' "$1"; return 0; }
  win=$(cygpath -w "$1" 2>/dev/null) || { printf '%s' "$1"; return 0; }
  printf '/%s' "$(printf '%s' "$win" | sed 's|^\([A-Za-z]\):|\L\1|; s|\\|/|g')"
}
ALIAS="$VERIFY_HOME"
PHYSICAL=$(other_spelling "$VERIFY_HOME")
if [ "$PHYSICAL" = "$ALIAS" ]; then
  verify_note "this temp directory has one spelling, so both drives use $ALIAS"
else
  verify_note "the home is $ALIAS and also $PHYSICAL"
fi
[ -d "$PHYSICAL" ] || { bad "the second spelling $PHYSICAL does not reach the home"; verify_done; }

drive() {  # <spelling> <label>: one note and one drain against the home, as firstmate runs them
  local home=$1 label=$2 chain lock rows
  rm -rf "$VERIFY_HOME/state" && mkdir -p "$VERIFY_HOME/state"
  if FM_HOME="$home" timeout 60 bash "$BIN/fm-inbox.sh" note "a note under the $label spelling" > "$VERIFY_TMP/note-$label.txt" 2>&1; then
    ok "a captain note is queued under the $label spelling"
  else
    bad "queuing a captain note under the $label spelling failed or hung: $(tail -1 "$VERIFY_TMP/note-$label.txt")"
  fi
  verify_keep "note-$label.txt" "$VERIFY_TMP/note-$label.txt"
  chain=$(find "$VERIFY_HOME/state" -maxdepth 1 -name '*.steal*' | wc -l | tr -d ' ')
  if [ "$chain" -eq 0 ]; then
    ok "no lock takeover chain grew under the $label spelling"
  else
    ls -la "$VERIFY_HOME/state" > "$VERIFY_TMP/state-$label.txt"; verify_keep "state-$label.txt" "$VERIFY_TMP/state-$label.txt"
    bad "a $chain-deep lock takeover chain grew under the $label spelling: $(find "$VERIFY_HOME/state" -maxdepth 1 -name '*.steal*' | sed 's|.*/||' | sort | tail -1)"
  fi
  lock=$(find "$VERIFY_HOME/state" -maxdepth 1 -name '.wake-queue.lock*' | wc -l | tr -d ' ')
  if [ "$lock" -eq 0 ]; then ok "the queue lock was released under the $label spelling"; else bad "$lock queue lock entries are left behind under the $label spelling"; fi
  rows=$(grep -c . "$VERIFY_HOME/state/.wake-queue" 2>/dev/null || echo 0)
  if [ "$rows" -eq 1 ]; then ok "the queue holds the one notification under the $label spelling"; else bad "the queue holds $rows rows under the $label spelling, not one"; fi
  if FM_HOME="$home" timeout 60 bash "$BIN/fm-wake-drain.sh" > "$VERIFY_TMP/drain-$label.txt" 2>&1 && grep -q 'captain inbox note' "$VERIFY_TMP/drain-$label.txt"; then
    ok "the drain presents that notification under the $label spelling"
  else
    bad "the drain under the $label spelling failed, hung, or did not present the note: $(grep -v '^$' "$VERIFY_TMP/drain-$label.txt" | tail -1)"
  fi
  verify_keep "drain-$label.txt" "$VERIFY_TMP/drain-$label.txt"
}

drive "$ALIAS" temp-alias
drive "$PHYSICAL" physical

verify_done
