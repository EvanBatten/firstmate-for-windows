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
    FM_LOCK_LOG_PREFIX=teardown
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
WIN_LOCK=$(cygpath -w "$LOCK")
WIN_WT=$(cygpath -w "$T/wt")
want="teardown: kept git lock $WIN_LOCK because Windows cannot tell whether a git process still holds it. To clear it, close every git command, editor and terminal working in $WIN_WT, then delete $WIN_LOCK. The next teardown of this task retries the cleanup.
kept"
if [ "$out" = "$want" ]; then
  ok "the refusal names the lock and worktree in Windows spelling and says how to clear it"
else
  not_ok "the refusal names the lock and worktree in Windows spelling and says how to clear it (got: $out)"
fi

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

rm -f "$LOCK"

# Session start relays only fleet-sync's stdout, so the skip line itself has to
# say why the clone was not synced and how to clear the lock.
H=$T/home
mkdir -p "$H/projects"
git init -q --bare -b main "$T/origin.git"
git -C "$T/repo" push -q "$T/origin.git" main main:refs/heads/gone
git clone -q "file://$(cygpath -m "$T/origin.git")" "$H/projects/proj"
git -C "$H/projects/proj" pack-refs --all
git -C "$T/origin.git" branch -q -D gone
PACKED_LOCK=$H/projects/proj/.git/packed-refs.lock
: > "$PACKED_LOCK"
out=$(
  # shellcheck source=platform/windows/env.sh
  . platform/windows/env.sh
  FM_HOME=$H FM_ROOT_OVERRIDE=$ROOT FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
    bin/fm-fleet-sync.sh proj 2>/dev/null
)
WIN_PACKED_LOCK=$(cygpath -w "$PACKED_LOCK")
want="proj: skipped: fetch failed: kept git lock $WIN_PACKED_LOCK because Windows cannot tell whether a git process still holds it. To clear it, close every git command, editor and terminal working in $(cygpath -w "$H/projects/proj"), then delete $WIN_PACKED_LOCK. The next session start retries the sync."
if [ "$out" = "$want" ] && [ -e "$PACKED_LOCK" ]; then
  ok "a fleet-sync skip on a held lock says how to clear it on the line session start relays"
else
  not_ok "a fleet-sync skip on a held lock says how to clear it on the line session start relays (got: $out)"
fi

[ "$fails" -eq 0 ]
