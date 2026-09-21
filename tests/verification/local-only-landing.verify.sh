#!/usr/bin/env bash
# Feature: work delivered as a local branch lands on the project's own main by
# fast-forward, and only by fast-forward. Anything else would rewrite history
# in a repository firstmate does not own.
# shellcheck source=tests/verification/lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"

verify_home
HOME_DIR="$VERIFY_HOME"
export FM_HOME="$HOME_DIR"
BIN="$VERIFY_ROOT/bin"
PROJ="$HOME_DIR/projects/demo"
WT="$VERIFY_TMP/demo-work"

mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
git -C "$PROJ" config user.email verify@example.invalid
git -C "$PROJ" config user.name verification
printf 'one\n' > "$PROJ/a.txt"
git -C "$PROJ" add -A && git -C "$PROJ" commit -qm "base"
BASE=$(git -C "$PROJ" rev-parse HEAD)

git -C "$PROJ" worktree add -q -b fm/demo "$WT"
printf 'two\n' > "$WT/b.txt"
git -C "$WT" add -A && git -C "$WT" commit -qm "add b"
TIP=$(git -C "$WT" rev-parse HEAD)

cat > "$HOME_DIR/state/demo.meta" <<META
worktree=$WT
project=$PROJ
kind=ship
mode=local-only
yolo=off
branch=fm/demo
META

if "$BIN/fm-merge-local.sh" demo >/dev/null 2>&1; then
  ok "approved local work lands"
else
  bad "the landing was refused"
fi

if [ "$(git -C "$PROJ" rev-parse main)" = "$TIP" ]; then
  ok "the project's main is at the delivered commit"
else
  bad "main is not at the delivered commit"
fi

if [ "$(git -C "$PROJ" rev-list --count "$BASE..main")" -eq 1 ]; then
  ok "it landed as a fast-forward, with no merge commit"
else
  bad "landing did not fast-forward"
fi

# A branch that has diverged must not land: fast-forward is the whole contract.
printf 'three\n' > "$PROJ/c.txt"
git -C "$PROJ" add -A && git -C "$PROJ" commit -qm "diverge on main"
printf 'four\n' > "$WT/d.txt"
git -C "$WT" add -A && git -C "$WT" commit -qm "diverge on the branch"
AFTER=$(git -C "$PROJ" rev-parse main)
if "$BIN/fm-merge-local.sh" demo >/dev/null 2>&1; then
  bad "a diverged branch was landed anyway"
else
  ok "a diverged branch is refused"
fi
if [ "$(git -C "$PROJ" rev-parse main)" = "$AFTER" ]; then
  ok "the refusal left main untouched"
else
  bad "the refused landing still moved main"
fi

verify_done
