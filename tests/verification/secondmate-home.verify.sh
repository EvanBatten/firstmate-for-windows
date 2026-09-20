#!/usr/bin/env bash
# Feature: provisioning a second mate produces a home that actually works -
# its own identity, its charter, a routing entry, and the skills its harness
# needs. A home that looks fine but has no skills is the failure this covers.
. "$(dirname "$0")/lib.sh"

verify_home
HOME_DIR="$VERIFY_HOME"
export FM_HOME="$HOME_DIR"
BIN="$VERIFY_ROOT/bin"
MATE="$VERIFY_TMP/mate"

cd "$HOME_DIR" || exit 1
FM_SECONDMATE_CHARTER='Own the docs domain.' FM_SECONDMATE_SCOPE='docs' \
  "$BIN/fm-home-seed.sh" docsmate "$MATE" --no-projects >/dev/null 2>&1 \
  && ok "a second mate home can be provisioned" || { bad "provisioning failed"; verify_done; }

[ -f "$MATE/.fm-secondmate-home" ] && ok "the home carries its identity marker" \
  || bad "the home has no identity marker"
grep -q '^parent_home=' "$MATE/.fm-secondmate-parent" 2>/dev/null \
  && ok "it knows which home owns it" || bad "the home has no parent binding"
[ -s "$MATE/data/charter.md" ] && ok "its charter travelled with it" \
  || bad "the charter was not copied into the home"
grep -q '^- docsmate - ' "$HOME_DIR/data/secondmates.md" 2>/dev/null \
  && ok "it is registered for routing" || bad "the home is not in the routing table"

# Regression, issue #60: .claude/skills is a tracked symlink into .agents/skills.
# A clone that does not ask for symlinks writes it as a text file holding the
# link target, leaving a mate whose harness silently has no skills at all.
if [ -L "$MATE/.claude/skills" ] && [ -d "$MATE/.claude/skills" ]; then
  ok "its harness can reach the skills"
  [ -n "$(ls -A "$MATE/.claude/skills" 2>/dev/null)" ] \
    && ok "the skills are actually there" || bad "the skills directory is empty"
else
  if [ -f "$MATE/.claude/skills" ]; then
    bad "the harness skill link is a plain file holding $(cat "$MATE/.claude/skills"), so this mate has no skills"
  else
    bad "the harness skill link is missing entirely"
  fi
fi

"$BIN/fm-home-seed.sh" validate >/dev/null 2>&1 \
  && ok "the routing table validates" || bad "the routing table does not validate"

verify_done
