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

# set -T hands the DEBUG trap to every subshell, so a fork writes its command
# to $T/forks; an empty PATH makes any external program fail loudly instead.
# shellcheck disable=SC2016 # Expanded by the inner bash.
expect "pwd -P forks no subshell and runs no program" \
  "[$T|forks:]" \
  "$(. platform/windows/env.sh; cd "$T" && "$BASH" -c '
    set -T; trap "((BASH_SUBSHELL == 0)) || echo \"\$BASH_COMMAND\" >>forks" DEBUG
    : >forks; PATH= pwd -P >out 2>&1; trap - DEBUG
    printf "[%s|forks:%s]" "$(<out)" "$(<forks)"')"

# Runs <setup> in a fresh overlay bash, then one pwd -P in that same shell, and
# prints its answer and the shell's directory state after it.
# shellcheck disable=SC2016 # Expanded by the inner bash.
after_pwd_p() {  # <setup>
  (. platform/windows/env.sh; bash -c 'T=$1; eval "$2"; pwd -P >"$T/out" 2>&1; rc=$?
    printf "[%s rc=%s PWD=%s OLDPWD=%s cwd=%s dirs=%s]" "$(<"$T/out")" "$rc" "$PWD" "${OLDPWD-unset}" "$(builtin pwd -P)" "${DIRSTACK[0]}"' _ "$T" "$1")
}
mkdir -p "$T/plain" "$T/other" "$T/old"
# shellcheck disable=SC2016 # Expanded by the inner bash.
expect "pwd -P leaves the shell where it is when PWD names another directory" \
  "[$T/plain rc=0 PWD=$T/other OLDPWD=$T/old cwd=$T/plain dirs=$T/plain]" \
  "$(after_pwd_p 'cd "$T/plain"; PWD=$T/other OLDPWD=$T/old')"
# shellcheck disable=SC2016 # Expanded by the inner bash.
expect "pwd -P leaves PWD alone when it names no directory, and OLDPWD unset" \
  "[$T/plain rc=0 PWD=/no/such/dir OLDPWD=unset cwd=$T/plain dirs=$T/plain]" \
  "$(after_pwd_p 'cd "$T/plain"; unset OLDPWD; PWD=/no/such/dir')"
# shellcheck disable=SC2016 # Expanded by the inner bash.
expect "pwd -P answers a deleted cwd as builtin pwd -P does" \
  "[$T/gone rc=0 PWD=$T/gone OLDPWD=$T/old cwd=$T/gone dirs=$T/gone]" \
  "$(after_pwd_p 'mkdir "$T/gone"; cd "$T/gone"; rmdir "$T/gone"; OLDPWD=$T/old')"
# shellcheck disable=SC2016 # Expanded by the inner bash.
expect "pwd -P answers a cwd entered through the drive spelling in the /tmp spelling and keeps the shell's" \
  "[$T/plain rc=0 PWD=$DRIVE_T/plain OLDPWD=$T/old cwd=$DRIVE_T/plain dirs=$DRIVE_T/plain]" \
  "$(after_pwd_p "cd '$DRIVE_T/plain'; OLDPWD=\$T/old")"

mkdir -p "$T/real/sub" "$T/r2/s"
if ln -s "$T/real" "$T/link" && [ -L "$T/link" ]; then
  # shellcheck disable=SC2016 # Expanded by the inner bash.
  expect "pwd -P resolves a symlinked cwd and leaves the shell in its logical spelling" \
    "[$T/real/sub rc=0 PWD=$T/link/sub OLDPWD=$T/old cwd=$T/real/sub dirs=$T/link/sub]" \
    "$(after_pwd_p 'cd "$T/link/sub"; OLDPWD=$T/old')"
  # Builtin pwd -P itself moves the shell's own record to the physical path
  # once the logical one stops resolving; PWD stays as the caller left it.
  # shellcheck disable=SC2016 # Expanded by the inner bash.
  expect "pwd -P leaves PWD alone when a symlink in it was removed" \
    "[$T/r2/s rc=0 PWD=$T/l2/s OLDPWD=$T/old cwd=$T/r2/s dirs=$T/r2/s]" \
    "$(after_pwd_p 'ln -s "$T/r2" "$T/l2"; cd "$T/l2/s"; rm "$T/l2"; OLDPWD=$T/old')"
  # shellcheck disable=SC2016 # Expanded by the inner bash.
  expect "cd .. after pwd -P in a symlinked cwd climbs the logical path" \
    "[$T/link]" \
    "$(. platform/windows/env.sh; bash -c 'cd "$1/link/sub" && pwd -P >/dev/null && cd .. && printf "[%s]" "$PWD"' _ "$T")"
else
  ok "pwd -P resolves a symlinked cwd # skip: this Git Bash makes no symlinks"
fi

expect "a script run through the drive spelling finds its root as upstream does, in the /tmp spelling" \
  "[$T]" \
  "$(. platform/windows/env.sh; bash -c 'printf "[%s]" "$(cd "$1/project/.." && pwd)"' _ "$DRIVE_T")"
expect "a script reads FM_HOME spelled through the drive as the /tmp spelling a session records" \
  "[$T/home]" \
  "$(. platform/windows/env.sh; FM_HOME=$DRIVE_T/home bash -c 'printf "[%s]" "$FM_HOME"')"

# git.exe names a work tree in drive spelling, C:/..., whichever spelling the
# caller used. Builds <home>/projects/notes as a clone one commit behind origin.
fleet_home() {  # <home>
  local h=$1
  mkdir -p "$h/projects" "$h/data"
  git init -q -b main "$h/work"
  git -C "$h/work" -c user.email=t@x.invalid -c user.name=t commit -q --allow-empty -m C0
  git clone -q --bare "$h/work" "$h/notes.git"
  git clone -q "$h/notes.git" "$h/projects/notes"
  git -C "$h/work" -c user.email=t@x.invalid -c user.name=t commit -q --allow-empty -m C1
  git -C "$h/work" push -q "$h/notes.git" main
  printf -- '- notes [direct-PR] - notes\n' > "$h/data/projects.md"
}
fleet_sync() {  # <home>
  (. platform/windows/env.sh; FM_HOME=$1 FM_ROOT_OVERRIDE=$ROOT bash bin/fm-fleet-sync.sh 2>/dev/null
    printf '[%s]' "$(git -C "$1/projects/notes" log -1 --format=%s)")
}
fleet_home "$T/fleet"
expect "fleet-sync fast-forwards a clone under /tmp" \
  "[C1]" \
  "$(fleet_sync "$T/fleet")"
fleet_home "$T/fleet-drive"
expect "fleet-sync fast-forwards a clone in a home spelled through the drive" \
  "[C1]" \
  "$(fleet_sync "$DRIVE_T/fleet-drive")"
C_T=$(mktemp -d "$(cygpath -u -- "$LOCALAPPDATA")/fm-win-paths.XXXXXX")
trap 'rm -rf "$T" "$C_T"' EXIT
fleet_home "$C_T/fleet"
expect "fleet-sync fast-forwards a clone in a home outside every mount, as a live home is" \
  "[C1]" \
  "$(fleet_sync "$C_T/fleet")"

mkdir -p "$T/primary-config" "$T/secondmate/config"
printf 'claude\n' > "$T/primary-config/crew-harness"
git init -q "$T/secondmate"
printf '/config/\n' > "$T/secondmate/.gitignore"
expect "a secondmate home inherits config into its gitignored config dir" \
  "[claude]" \
  "$(. platform/windows/env.sh; FM_INHERITABLE_CONFIG=crew-harness bash -c '. bin/fm-config-inherit-lib.sh
    propagate_inheritable_config "$1/primary-config" "$1/secondmate/config"
    printf "[%s]" "$(cat "$1/secondmate/config/crew-harness" 2>/dev/null)"' _ "$T" 2>&1)"
rm -f "$T/secondmate/config/crew-harness"
# NTFS ignores letter case, so a destination typed in other case is the same directory.
expect "a secondmate home spelled in other letter case inherits config into its gitignored config dir" \
  "[claude]" \
  "$(. platform/windows/env.sh; FM_INHERITABLE_CONFIG=crew-harness bash -c '. bin/fm-config-inherit-lib.sh
    propagate_inheritable_config "$1/primary-config" "$2/config"
    printf "[%s]" "$(cat "$1/secondmate/config/crew-harness" 2>/dev/null)"' _ "$T" "$T/SECONDMATE" 2>&1)"

[ "$fails" -eq 0 ]
