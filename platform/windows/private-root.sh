#!/usr/bin/env bash
# Usage: platform/windows/private-root.sh check|apply <dir>...
#
# On Windows a firstmate file is private because of its directory's ACL, not
# its POSIX mode: Git Bash mounts drives noacl, so chmod changes nothing and
# stat reports the mode the reader's umask implies (see env.sh). A root is
# private when every entry of its ACL names this user, SYSTEM or
# Administrators, the same set that can read a 0700 directory on Linux.
#
# check prints "private <dir>" or "open <dir>: <principal>..." and exits 1 when
# any root is open. apply replaces an open root's ACL with that set, inherited
# by everything beneath it, which needs no admin because the user owns it.
set -u

mode=${1:-}
case $mode in check | apply) shift ;; *) echo "usage: $0 check|apply <dir>..." >&2; exit 2 ;; esac
[ $# -gt 0 ] || { echo "usage: $0 check|apply <dir>..." >&2; exit 2; }

me="$USERDOMAIN\\$USERNAME"

acl_outsiders() {
  local out line entry who entries=0
  out=$(MSYS2_ARG_CONV_EXCL='*' icacls "$1" 2>&1) || { echo unreadable-acl; return; }
  while IFS= read -r line; do
    line=${line//$'\r'/}
    case $line in *':('*) ;; *) continue ;; esac
    entries=$((entries + 1))
    entry=${line#"$1"}
    entry=${entry#"${entry%%[! ]*}"}
    who=${entry%%:(*}
    case $who in
      "NT AUTHORITY\\SYSTEM" | "BUILTIN\\Administrators" | "$me") continue ;;
    esac
    printf '%s %s\n' "$who" "${entry#"$who":}"
  done <<< "$out"
  [ "$entries" -gt 0 ] || echo unreadable-acl
}

rc=0
for dir in "$@"; do
  [ -d "$dir" ] || { echo "missing $dir" >&2; rc=1; continue; }
  win=$(cygpath -w -- "$dir")
  open=$(acl_outsiders "$win")
  if [ -n "$open" ] && [ "$mode" = apply ]; then
    MSYS2_ARG_CONV_EXCL='*' icacls "$win" /inheritance:r /grant:r \
      "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "$me:(OI)(CI)F" >/dev/null || { rc=1; continue; }
    open=$(acl_outsiders "$win")
  fi
  if [ -n "$open" ]; then
    printf 'open %s: %s\n' "$dir" "$(printf '%s' "$open" | tr '\n' ';')"
    rc=1
  else
    printf 'private %s\n' "$dir"
  fi
done
exit "$rc"
