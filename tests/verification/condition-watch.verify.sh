#!/usr/bin/env bash
# Feature: "do X as soon as Y is true" can be armed, and it fires the action and
# tells firstmate, without anyone sitting and watching for it.
# shellcheck source=tests/verification/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

verify_home
HOME_DIR="$VERIFY_HOME"
export FM_HOME="$HOME_DIR"
BIN="$VERIFY_ROOT/bin"

flag="$HOME_DIR/condition-met"
done_marker="$HOME_DIR/action-ran"

cd "$HOME_DIR" || exit 1
if "$BIN/fm-procevent-when.sh" arm probe --interval 2 --stable 1 --deadline 180   --condition test -f "$flag" --action touch "$done_marker" >/dev/null 2>&1; then
  ok "a condition and its action can be armed"
else
  bad "arming failed"
  verify_done
fi

if "$BIN/fm-procevent.sh" list 2>/dev/null | grep -q 'when-probe'; then
  ok "it is registered as a source"
else
  bad "the armed watch is not registered"
fi

if "$BIN/fm-procevent.sh" reconcile >/dev/null 2>&1; then
  ok "it starts on reconcile"
else
  bad "the source did not start"
fi

if [ -e "$done_marker" ]; then
  bad "the action ran before its condition was true"
else
  ok "the action does not run before its condition is true"
fi

touch "$flag"
deadline=$(( $(date +%s) + 90 ))
while [ ! -e "$done_marker" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 1; done
if [ -e "$done_marker" ]; then
  ok "the action runs once the condition holds"
else
  bad "the action never ran"
fi

# The result is captured and published after the action runs, so give the
# notification its own wait rather than assuming it lands in the same instant.
deadline=$(( $(date +%s) + 90 ))
told=false
while [ "$(date +%s)" -lt "$deadline" ]; do
  if "$BIN/fm-wake-drain.sh" 2>/dev/null | grep -q 'procevent'; then told=true; break; fi
  sleep 2
done
if [ "$told" = true ]; then
  ok "firstmate is told about it"
else
  bad "firstmate was never told"
fi

if "$BIN/fm-procevent-when.sh" retire probe >/dev/null 2>&1; then
  ok "it can be retired"
else
  bad "the watch could not be retired"
fi

verify_done
