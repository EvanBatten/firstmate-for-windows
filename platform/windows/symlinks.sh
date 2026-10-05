#!/usr/bin/env bash
# Usage: platform/windows/symlinks.sh <checkout>
#
# Git for Windows clones with core.symlinks=false unless told otherwise, and
# then writes each tracked symlink as a plain file holding its target, so
# .claude/skills is a 17-byte file and the harness finds no skills. This checks
# those paths out again as real links, in the checkout the launch runs from and
# in every worktree of its repository, and turns core.symlinks on only once a
# rescan finds none of them still a plain file, so a failed restore or a layout
# git names oddly (a submodule's worktree is its git dir) leaves no type change
# for a commit -a to record. A path whose content is anything other than its
# link target is the captain's edit and is left alone. A directory that is not
# the top level of its own repository is left alone too, so a copy inside
# another repository never writes that one.
set -u

root=${1:?usage: symlinks.sh <checkout>}
prefix=$(git -C "$root" rev-parse --show-prefix 2>/dev/null) && [ -z "$prefix" ] || exit 0
common=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir) || exit 1

probe=$(mktemp -d "$common/fm-symlink-probe.XXXXXX") || exit 1
if ! MSYS=winsymlinks:nativestrict ln -s probe "$probe/link" 2>/dev/null; then
  rm -rf "$probe"
  echo "firstmate: $root has its links as plain files, so the harness has no skills, and this Windows account cannot create symlinks. Turn on Developer Mode (Settings > System > For developers), open a new shell, and launch again." >&2
  exit 1
fi
rm -rf "$probe"

scan() {
  local wt=$1 meta path i paths=() shas=() hashes=()
  restore=() kept=()
  while IFS=$'\t' read -r -d '' meta path; do
    [ "${meta%% *}" = 120000 ] || continue
    [ -f "$wt/$path" ] && [ ! -L "$wt/$path" ] || continue
    paths+=("$path")
    meta=${meta#* }
    shas+=("${meta%% *}")
  done < <(git -C "$wt" ls-files -s -z)
  [ "${#paths[@]}" -gt 0 ] || return 0
  mapfile -t hashes < <(cd "$wt" && git hash-object --no-filters -- "${paths[@]}")
  for i in "${!paths[@]}"; do
    if [ "${hashes[$i]:-}" = "${shas[$i]}" ]; then restore+=("${paths[$i]}"); else kept+=("${paths[$i]}"); fi
  done
}

declare -A seen
checkouts=()
while IFS= read -r wt; do
  top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || continue
  [ -z "${seen[$top]:-}" ] || continue
  seen[$top]=1
  checkouts+=("$top")
done < <(printf '%s\n' "$root"; git -C "$root" worktree list --porcelain | sed -n 's/^worktree //p')

for wt in "${checkouts[@]}"; do
  scan "$wt"
  for path in "${kept[@]}"; do
    echo "firstmate: left $wt/$path as it is: it should be a symlink, but its content is not the link target" >&2
  done
  [ "${#restore[@]}" -gt 0 ] || continue
  git -c core.symlinks=true -C "$wt" checkout -- "${restore[@]}"
done

rc=0
for wt in "${checkouts[@]}"; do
  scan "$wt"
  for path in "${restore[@]}"; do
    echo "firstmate: could not make $wt/$path a symlink" >&2
    rc=1
  done
done
[ "$rc" -eq 0 ] || exit 1
git -C "$root" config --replace-all core.symlinks true
