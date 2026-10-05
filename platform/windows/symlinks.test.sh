#!/usr/bin/env bash
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1

T=$(mktemp -d /tmp/fm-win-symlinks.XXXXXX)
trap 'rm -rf "$T"' EXIT

fails=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
expect() {
  if [ "$3" = "$2" ]; then ok "$1"; else not_ok "$1 (want: $2, got: $3)"; fi
}
clean() { env -u FM_WIN_PRIVATE_ROOTS -u BASH_ENV -u FM_WIN_PRIOR_BASH_ENV -u FM_PLATFORM_OVERLAY "$@"; }

# A clone the way Git for Windows makes one by default, with the working tree's
# overlay copied in so the code under test is this checkout's.
default_clone() {
  git clone -q -c core.symlinks=false "$ROOT" "$1" || return 1
  cp -R "$ROOT/platform/windows/." "$1/platform/windows/"
}
launch() { (cd "$1" && clean FM_HOME="$1" PATH="${2:-$PATH}" bash -c '. platform/windows/env.sh' 2>&1); }
mapfile -t LINKS < <(git ls-files -s | awk '$1 == 120000 { print $4 }')
links() {
  local p out=
  for p in "${LINKS[@]}"; do
    if [ -L "$1/$p" ] && [ -e "$1/$p" ]; then out="$out $p=link"; else out="$out $p=file"; fi
  done
  echo "${out# }"
}
all_links=$(for p in "${LINKS[@]}"; do printf '%s=link ' "$p"; done)
all_links=${all_links% }
all_files=${all_links//=link/=file}
tracked_status() { git -C "$1" status --porcelain -- "${LINKS[@]}"; }

H=$T/home
default_clone "$H"
git -C "$H" worktree add -q --detach "$T/old-wt"
expect "a default Windows clone has every tracked symlink as a plain file" "$all_files" "$(links "$H")"

launch "$H" >/dev/null
expect "launching from it restores every tracked symlink" "$all_links" "$(links "$H")"
expect "and turns core.symlinks on" "true" "$(git -C "$H" config core.symlinks)"
expect "and leaves git seeing nothing changed" "" "$(tracked_status "$H")"
expect "a worktree made from it before the launch is restored too" "$all_links" "$(links "$T/old-wt")"
expect "with nothing changed there either" "" "$(tracked_status "$T/old-wt")"
ls "$H/.claude/skills/" > "$T/skills" 2>&1
expect "the harness finds its skills through the link" "yes" "$(grep -qx verify-firstmate "$T/skills" && echo yes || echo no)"

git -C "$H" worktree add -q --detach "$T/new-wt"
expect "a worktree made after the launch gets real symlinks" "$all_links" "$(links "$T/new-wt")"
expect "a second launch prints nothing" "" "$(launch "$H")"

rm "$T/new-wt/.claude/skills"
printf '%s' ../.agents/skills > "$T/new-wt/.claude/skills"
launch "$H" >/dev/null
expect "a worktree left with a plain file under a healthy checkout is restored on launch" "$all_links" "$(links "$T/new-wt")"

E=$T/edited
default_clone "$E"
printf 'my own notes\n' > "$E/.claude/skills"
launch "$E" >/dev/null
expect "a link path the captain edited keeps the captain's content" "my own notes" "$(cat "$E/.claude/skills")"
expect "while the other tracked symlinks are restored" "${all_links/.claude\/skills=link/.claude/skills=file}" "$(links "$E")"

N=$T/no-privilege
default_clone "$N"
mkdir -p "$T/fake"
printf '#!/bin/sh\necho "ln: failed to create symbolic link: Operation not permitted" >&2\nexit 1\n' > "$T/fake/ln"
chmod +x "$T/fake/ln"
out=$(launch "$N" "$T/fake:$PATH")
case $out in
  *"Developer Mode"*) ok "an account that cannot make symlinks is told to turn on Developer Mode" ;;
  *) not_ok "an account that cannot make symlinks is told to turn on Developer Mode (got: $out)" ;;
esac
expect "and its checkout is left as it was" "$all_files false" "$(links "$N") $(git -C "$N" config core.symlinks)"

L=$T/locked
default_clone "$L"
: > "$L/.git/index.lock"
launch "$L" >/dev/null
rm "$L/.git/index.lock"
expect "a launch that meets an index lock leaves core.symlinks off" "false" "$(git -C "$L" config core.symlinks)"
expect "so a commit -a after the lock clears records no type change" "" "$(tracked_status "$L")"
launch "$L" >/dev/null
expect "and the next launch restores the links" "$all_links" "$(links "$L")"

O=$T/outer
git init -q "$O"
outer_symlinks=$(git -C "$O" config --local core.symlinks)
default_clone "$O/fm"
rm -rf "$O/fm/.git"
expect "a copy with no .git inside another repo launches silently" "" "$(launch "$O/fm")"
expect "and leaves the enclosing repo's config alone" "$outer_symlinks" "$(git -C "$O" config --local core.symlinks)"
expect "and its own links as they were" "$all_files" "$(links "$O/fm")"

A=$T/archive
mkdir "$A"
default_clone "$A/fm"
rm -rf "$A/fm/.git"
expect "a copy outside any repo launches silently" "" "$(GIT_CEILING_DIRECTORIES=$A launch "$A/fm")"

[ "$fails" -eq 0 ]
