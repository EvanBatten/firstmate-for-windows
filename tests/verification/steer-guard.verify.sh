#!/usr/bin/env bash
# Feature: an instruction can never be delivered to a worker in the wrong home.
# Getting this wrong sends a steer to somebody else's crew, so it refuses
# rather than guessing which home was meant.
# shellcheck source=tests/verification/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

verify_home
HOME_DIR="$VERIFY_HOME"
BIN="$VERIFY_ROOT/bin"

if out=$(env -u FM_HOME "$BIN/fm-send.sh" some-task "hello" 2>&1); then
  bad "a steer with no home was delivered anyway"
else
  ok "a steer with no home is refused"
  if printf '%s' "$out" | grep -qi 'FM_HOME'; then
    ok "the refusal names what is missing"
  else
    bad "the refusal does not say what is missing: $out"
  fi
fi

if FM_HOME="$HOME_DIR" "$BIN/fm-send.sh" no-such-task "hello" >/dev/null 2>&1; then
  bad "a steer to an unknown worker was accepted"
else
  ok "a steer to an unknown worker is refused"
fi

verify_done
