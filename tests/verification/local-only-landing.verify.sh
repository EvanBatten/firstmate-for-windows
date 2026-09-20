#!/usr/bin/env bash
# Feature: work delivered as a local branch lands on the project's own main by
# fast-forward, and only by fast-forward. Anything else would rewrite history
# in a repository firstmate does not own.
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

"$BIN/fm-merge-local.sh" demo >/dev/null 2>&1 \
  && ok "approved local work lands" || bad "the landing was refused"

[ "$(git -C "$PROJ" rev-parse main)" = "$TIP" ] \
  && ok "the project's main is at the delivered commit" \
  || bad "main is not at the delivered commit"

[ "$(git -C "$PROJ" rev-list --count "$BASE..main")" -eq 1 ] \
  && ok "it landed as a fast-forward, with no merge commit" \
  || bad "landing did not fast-forward"

# A branch that has diverged must not land: fast-forward is the whole contract.
printf 'three\n' > "$PROJ/c.txt"
git -C "$PROJ" add -A && git -C "$PROJ" commit -qm "diverge on main"
printf 'four\n' > "$WT/d.txt"
git -C "$WT" add -A && git -C "$WT" commit -qm "diverge on the branch"
AFTER=$(git -C "$PROJ" rev-parse main)
"$BIN/fm-merge-local.sh" demo >/dev/null 2>&1 \
  && bad "a diverged branch was landed anyway" || ok "a diverged branch is refused"
[ "$(git -C "$PROJ" rev-parse main)" = "$AFTER" ] \
  && ok "the refusal left main untouched" || bad "the refused landing still moved main"

verify_done
