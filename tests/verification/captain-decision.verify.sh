#!/usr/bin/env bash
# Feature: a question that belongs to the captain is carried by a real backlog
# item until he answers, and his own words are what closes it.
# shellcheck source=tests/verification/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

verify_home
HOME_DIR="$VERIFY_HOME"
export FM_HOME="$HOME_DIR"
BIN="$VERIFY_ROOT/bin"
command -v tasks-axi >/dev/null 2>&1 || verify_skip "tasks-axi is not installed"

cd "$HOME_DIR" || exit 1
if tasks-axi add ship-or-wait --title "ship the notes or wait" >/dev/null 2>&1; then
  ok "a work item can be filed"
else
  bad "the work item could not be filed"
fi

if "$BIN/fm-captain-hold.sh" hold ship-or-wait   --reason "Ship now or wait for the fix? Options: ship now, wait." >/dev/null 2>&1; then
  ok "it can be held for the captain"
else
  bad "it could not be held for the captain"
fi

if tasks-axi show ship-or-wait 2>/dev/null | grep -Eq '^  held: yes'; then
  ok "the item reads as waiting on him"
else
  bad "the item does not read as waiting on him"
fi
if tasks-axi show ship-or-wait 2>/dev/null | grep -Fq 'Ship now or wait'; then
  ok "the question travels with it"
else
  bad "the question was not recorded on the item"
fi

# A completion claim naming an origin this home does not own must be refused,
# or any caller could declare a review finished.
if "$BIN/fm-captain-hold.sh" complete not-our-origin ship-or-wait >/dev/null 2>&1; then
  bad "a completion claim for a foreign origin was accepted"
else
  ok "a completion claim for a foreign origin is refused"
fi

printf 'Ship now.\n' > "$HOME_DIR/answer.txt"
if "$BIN/fm-captain-hold.sh" answer ship-or-wait --decision-file "$HOME_DIR/answer.txt" >/dev/null 2>&1; then
  ok "his answer can be recorded"
else
  bad "his answer could not be recorded"
fi

if tasks-axi show ship-or-wait 2>/dev/null | grep -Eq '^  held: no'; then
  ok "recording the answer releases it"
else
  bad "the item is still held after the answer"
fi
if tasks-axi show ship-or-wait 2>/dev/null | grep -Eq '^  state: done'; then
  ok "the item closes"
else
  bad "the item did not close"
fi

verify_done
