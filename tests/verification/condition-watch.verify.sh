#!/usr/bin/env bash
# Feature: "do X as soon as Y is true" can be armed, and it fires the action and
# tells firstmate, without anyone sitting and watching for it.
. "$(dirname "$0")/lib.sh"

verify_home
HOME_DIR="$VERIFY_HOME"
export FM_HOME="$HOME_DIR"
BIN="$VERIFY_ROOT/bin"

flag="$HOME_DIR/condition-met"
done_marker="$HOME_DIR/action-ran"

cd "$HOME_DIR" || exit 1
"$BIN/fm-procevent-when.sh" arm probe --interval 2 --stable 1 --deadline 180 \
  --condition test -f "$flag" --action touch "$done_marker" >/dev/null 2>&1 \
  && ok "a condition and its action can be armed" || { bad "arming failed"; verify_done; }

"$BIN/fm-procevent.sh" list 2>/dev/null | grep -q 'when-probe' \
  && ok "it is registered as a source" || bad "the armed watch is not registered"

"$BIN/fm-procevent.sh" reconcile >/dev/null 2>&1 \
  && ok "it starts on reconcile" || bad "the source did not start"

[ -e "$done_marker" ] && bad "the action ran before its condition was true" \
  || ok "the action does not run before its condition is true"

touch "$flag"
deadline=$(( $(date +%s) + 90 ))
while [ ! -e "$done_marker" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 1; done
[ -e "$done_marker" ] && ok "the action runs once the condition holds" \
  || bad "the action never ran"

# The result is captured and published after the action runs, so give the
# notification its own wait rather than assuming it lands in the same instant.
deadline=$(( $(date +%s) + 90 ))
told=false
while [ "$(date +%s)" -lt "$deadline" ]; do
  if "$BIN/fm-wake-drain.sh" 2>/dev/null | grep -q 'procevent'; then told=true; break; fi
  sleep 2
done
[ "$told" = true ] && ok "firstmate is told about it" || bad "firstmate was never told"

"$BIN/fm-procevent-when.sh" retire probe >/dev/null 2>&1 \
  && ok "it can be retired" || bad "the watch could not be retired"

verify_done
