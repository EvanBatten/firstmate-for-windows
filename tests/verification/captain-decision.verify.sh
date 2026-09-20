#!/usr/bin/env bash
# Feature: a question that belongs to the captain is carried by a real backlog
# item until he answers, and his own words are what closes it.
. "$(dirname "$0")/lib.sh"

verify_home
HOME_DIR="$VERIFY_HOME"
export FM_HOME="$HOME_DIR"
BIN="$VERIFY_ROOT/bin"
command -v tasks-axi >/dev/null 2>&1 || verify_skip "tasks-axi is not installed"

cd "$HOME_DIR" || exit 1
tasks-axi add ship-or-wait --title "ship the notes or wait" >/dev/null 2>&1 \
  && ok "a work item can be filed" || bad "the work item could not be filed"

"$BIN/fm-captain-hold.sh" hold ship-or-wait \
  --reason "Ship now or wait for the fix? Options: ship now, wait." >/dev/null 2>&1 \
  && ok "it can be held for the captain" || bad "it could not be held for the captain"

tasks-axi show ship-or-wait 2>/dev/null | grep -Eq '^  held: yes' \
  && ok "the item reads as waiting on him" || bad "the item does not read as waiting on him"
tasks-axi show ship-or-wait 2>/dev/null | grep -Fq 'Ship now or wait' \
  && ok "the question travels with it" || bad "the question was not recorded on the item"

# A completion claim naming an origin this home does not own must be refused,
# or any caller could declare a review finished.
"$BIN/fm-captain-hold.sh" complete not-our-origin ship-or-wait >/dev/null 2>&1 \
  && bad "a completion claim for a foreign origin was accepted" \
  || ok "a completion claim for a foreign origin is refused"

printf 'Ship now.\n' > "$HOME_DIR/answer.txt"
"$BIN/fm-captain-hold.sh" answer ship-or-wait --decision-file "$HOME_DIR/answer.txt" >/dev/null 2>&1 \
  && ok "his answer can be recorded" || bad "his answer could not be recorded"

tasks-axi show ship-or-wait 2>/dev/null | grep -Eq '^  held: no' \
  && ok "recording the answer releases it" || bad "the item is still held after the answer"
tasks-axi show ship-or-wait 2>/dev/null | grep -Eq '^  state: done' \
  && ok "the item closes" || bad "the item did not close"

verify_done
