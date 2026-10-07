#!/usr/bin/env bash
# Teardown and fleet-sync remove a git lock only when fm_lock_is_provably_stale
# proves no live process holds it. Git Bash ships no lsof, and an lsof that
# could run here would not see a native git.exe's open files or working
# directory, so its empty answer proves nothing.
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1
T=$(mktemp -d /tmp/fm-win-git-lock.XXXXXX)
GIT_PID=
cleanup() {
  rm -f "$T/hold"
  [ -z "$GIT_PID" ] || wait "$GIT_PID" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

fails=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x.invalid
git init -q -b main "$T/repo"
git -C "$T/repo" config core.autocrlf false
echo a > "$T/repo/f"
git -C "$T/repo" add f
git -C "$T/repo" commit -qm start
git -C "$T/repo" worktree add -q "$T/wt" -b task
LOCK=$(git -C "$T/wt" rev-parse --path-format=absolute --git-path index.lock)

mkdir -p "$T/blind"
printf '#!/bin/sh\nexit 1\n' > "$T/blind/lsof"
chmod +x "$T/blind/lsof"

# remove_if_stale <lock> <dir>: what both callers do with the proof.
remove_if_stale() {
  (
    # shellcheck source=platform/windows/env.sh
    . platform/windows/env.sh
    PATH=$T/blind:$PATH
    # shellcheck source=bin/fm-lock-lib.sh
    . bin/fm-lock-lib.sh
    if fm_lock_is_provably_stale "$1" "$2" 30; then
      rm -f "$1"
      echo removed
    else
      echo kept
    fi
  ) 2>&1
}

: > "$T/hold"
echo b >> "$T/wt/f"
(cd "$T/wt" && GIT_EDITOR="while [ -e '$T/hold' ]; do sleep 0.2; done; :" exec git commit -qa) > "$T/commit.out" 2>&1 &
GIT_PID=$!
for _ in $(seq 1 100); do [ -e "$LOCK" ] && break; sleep 0.1; done
[ -e "$LOCK" ] || { echo "not ok - git commit never took $LOCK"; exit 1; }
touch -d 2020-01-01 "$LOCK"

out=$(remove_if_stale "$LOCK" "$T/wt")
if [ -e "$LOCK" ] && kill -0 "$GIT_PID" 2>/dev/null; then
  ok "an aged index.lock held by a live git survives an lsof that sees no holder"
else
  not_ok "an aged index.lock held by a live git survives an lsof that sees no holder (got: $out)"
fi
case $out in
  *"no Windows-aware liveness check"*) ok "the refusal says why the lock was kept" ;;
  *) not_ok "the refusal says why the lock was kept (got: $out)" ;;
esac

rm -f "$T/hold"
wait "$GIT_PID" 2>/dev/null
GIT_PID=

: > "$LOCK"
touch -d 2020-01-01 "$LOCK"
out=$(remove_if_stale "$LOCK" "$T/wt")
if [ -e "$LOCK" ]; then
  ok "an aged index.lock with no holder is kept, because no holder cannot be proven"
else
  not_ok "an aged index.lock with no holder is kept, because no holder cannot be proven (got: $out)"
fi

[ "$fails" -eq 0 ]
