#!/usr/bin/env bash
# Git Bash mounts %TEMP% at /tmp, so a home there has two POSIX spellings:
# /tmp/... and /c/Users/.../Temp/.... A native program such as git.exe or
# treehouse.exe answers in drive spelling, which MSYS reads back as /tmp/...,
# while the captain or the primary may type either one.
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1
T=$(mktemp -d /tmp/fm-win-paths.XXXXXX)
trap 'rm -rf "$T"' EXIT
DRIVE_T=$(cygpath -u -- "$(cygpath -m -- "$LOCALAPPDATA")")/Temp/${T#/tmp/}

fails=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
expect() {
  case $3 in *"$2"*) ok "$1" ;; *) not_ok "$1 (got: $3)" ;; esac
}

[ -d "$DRIVE_T" ] && [ "$DRIVE_T" != "$T" ] || { echo "not ok - $T has no second spelling ($DRIVE_T)"; exit 1; }
git init -q -b main "$T/project"
git -C "$T/project" -c user.email=t@x.invalid -c user.name=t commit -q --allow-empty -m start
git -C "$T/project" worktree add -q "$(cygpath -m "$T/wt")" -b task
mkdir -p "$T/config"

expect "trust accepts a worktree of a project spelled through the drive" \
  "trusted: $T/wt" \
  "$(. platform/windows/env.sh; CLAUDE_CONFIG_DIR=$T/config bash bin/fm-claude-trust.sh "$T/wt" "$DRIVE_T/project" 2>&1)"
expect "trust accepts a worktree spelled through the drive of a project under /tmp" \
  "trusted: " \
  "$(. platform/windows/env.sh; CLAUDE_CONFIG_DIR=$T/config bash bin/fm-claude-trust.sh "$DRIVE_T/wt" "$T/project" 2>&1)"
expect "pwd -P names a directory under %TEMP% one way from either spelling" \
  "$T|$T" \
  "$(. platform/windows/env.sh; bash -c 'a=$(cd -P "$1" && pwd -P); b=$(cd -P "$2" && pwd -P); printf "%s|%s" "$a" "$b"' _ "$T" "$DRIVE_T")"

# shellcheck disable=SC2016 # Expanded by the inner bash.
expect "pwd -P answers without a subshell, at a fraction of the cost of one fork per call" \
  "no fork" \
  "$(. platform/windows/env.sh; cd "$T" && bash -c '
    s=$EPOCHREALTIME; for ((i = 0; i < 40; i++)); do x=$(builtin pwd -P); done; forked=$((${EPOCHREALTIME/./} - ${s/./}))
    s=$EPOCHREALTIME; for ((i = 0; i < 40; i++)); do pwd -P >/dev/null; done; overlay=$((${EPOCHREALTIME/./} - ${s/./}))
    if [ $((overlay * 4)) -lt "$forked" ]; then echo "no fork"; else echo "overlay ${overlay}us for 40 calls, forked ${forked}us"; fi')"

mkdir -p "$T/real/sub"
if ln -s "$T/real" "$T/link" && [ -L "$T/link" ]; then
  # shellcheck disable=SC2016 # Expanded by the inner bash.
  expect "pwd -P resolves a symlinked cwd and leaves the shell in its logical spelling" \
    "[$T/real/sub|$T/link/sub|$T/link]" \
    "[$(. platform/windows/env.sh; bash -c 'cd "$1/link/sub" && pwd -P && pwd && cd .. && echo "$PWD"' _ "$T" | paste -sd '|')]"
else
  ok "pwd -P resolves a symlinked cwd # skip: this Git Bash makes no symlinks"
fi

expect "a script run through the drive spelling finds its root as upstream does, in the /tmp spelling" \
  "[$T]" \
  "$(. platform/windows/env.sh; bash -c 'printf "[%s]" "$(cd "$1/project/.." && pwd)"' _ "$DRIVE_T")"
expect "a script reads FM_HOME spelled through the drive as the /tmp spelling a session records" \
  "[$T/home]" \
  "$(. platform/windows/env.sh; FM_HOME=$DRIVE_T/home bash -c 'printf "[%s]" "$FM_HOME"')"

[ "$fails" -eq 0 ]
