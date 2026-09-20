#!/usr/bin/env bash
# Feature: an instruction can never be delivered to a worker in the wrong home.
# Getting this wrong sends a steer to somebody else's crew, so it refuses
# rather than guessing which home was meant.
. "$(dirname "$0")/lib.sh"

verify_home
HOME_DIR="$VERIFY_HOME"
BIN="$VERIFY_ROOT/bin"

out=$(env -u FM_HOME "$BIN/fm-send.sh" some-task "hello" 2>&1)
if [ $? -eq 0 ]; then
  bad "a steer with no home was delivered anyway"
else
  ok "a steer with no home is refused"
  printf '%s' "$out" | grep -qi 'FM_HOME' \
    && ok "the refusal names what is missing" || bad "the refusal does not say what is missing: $out"
fi

out=$(FM_HOME="$HOME_DIR" "$BIN/fm-send.sh" no-such-task "hello" 2>&1)
[ $? -ne 0 ] && ok "a steer to an unknown worker is refused" \
  || bad "a steer to an unknown worker was accepted"

verify_done
