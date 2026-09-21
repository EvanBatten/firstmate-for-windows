#!/usr/bin/env bash
# Feature: provisioning a second mate produces a home that actually works -
# its own identity, its charter, a routing entry, and the skills its harness
# needs. A home that looks fine but has no skills is the failure this covers.
# shellcheck source=tests/verification/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

verify_home
HOME_DIR="$VERIFY_HOME"
export FM_HOME="$HOME_DIR"
BIN="$VERIFY_ROOT/bin"
MATE="$VERIFY_TMP/mate"

cd "$HOME_DIR" || exit 1
if FM_SECONDMATE_CHARTER='Own the docs domain.' FM_SECONDMATE_SCOPE='docs'   "$BIN/fm-home-seed.sh" docsmate "$MATE" --no-projects >/dev/null 2>&1; then
  ok "a second mate home can be provisioned"
else
  bad "provisioning failed"
  verify_done
fi

if [ -f "$MATE/.fm-secondmate-home" ]; then
  ok "the home carries its identity marker"
else
  bad "the home has no identity marker"
fi
if grep -q '^parent_home=' "$MATE/.fm-secondmate-parent" 2>/dev/null; then
  ok "it knows which home owns it"
else
  bad "the home has no parent binding"
fi
if [ -s "$MATE/data/charter.md" ]; then
  ok "its charter travelled with it"
else
  bad "the charter was not copied into the home"
fi
if grep -q '^- docsmate - ' "$HOME_DIR/data/secondmates.md" 2>/dev/null; then
  ok "it is registered for routing"
else
  bad "the home is not in the routing table"
fi

# Regression, issue #60: .claude/skills is a tracked symlink into .agents/skills.
# A clone that does not ask for symlinks writes it as a text file holding the
# link target, leaving a mate whose harness silently has no skills at all.
if [ -L "$MATE/.claude/skills" ] && [ -d "$MATE/.claude/skills" ]; then
  ok "its harness can reach the skills"
  if [ -n "$(ls -A "$MATE/.claude/skills" 2>/dev/null)" ]; then
    ok "the skills are actually there"
  else
    bad "the skills directory is empty"
  fi
else
  if [ -f "$MATE/.claude/skills" ]; then
    bad "the harness skill link is a plain file holding $(cat "$MATE/.claude/skills"), so this mate has no skills"
  else
    bad "the harness skill link is missing entirely"
  fi
fi

if "$BIN/fm-home-seed.sh" validate >/dev/null 2>&1; then
  ok "the routing table validates"
else
  bad "the routing table does not validate"
fi

verify_done
