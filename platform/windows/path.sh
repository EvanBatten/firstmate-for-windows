# shellcheck shell=bash
# Sourced by env.sh and bash-env.sh, so every bash the overlay reaches has it.
#
# Git Bash mounts some Windows directories a second time, most visibly %TEMP%
# at /tmp, so one directory has two POSIX spellings: /tmp/x and
# /c/Users/<user>/AppData/Local/Temp/x. `pwd -P` keeps whichever one the shell
# entered by, while a path a native program prints, such as git.exe's
# --git-common-dir or the gitdir treehouse writes, comes back through the
# mount as /tmp/x. Upstream decides "same directory" by comparing `pwd -P`
# strings, so here `pwd -P` answers in the mount's spelling, the one
# `cygpath -u` gives, without forking it.

_fm_win_mount_src=()
_fm_win_mount_dst=()
_fm_win_re='^([A-Za-z]):(/.*) (/[^ ]*) [^ ]+ [^ ]+ [0-9]+ [0-9]+$'
while IFS= read -r _fm_win_line; do
  [[ $_fm_win_line =~ $_fm_win_re ]] || continue
  # /bin is Git's alias of /usr/bin, which cygpath never answers with.
  [ "${BASH_REMATCH[3]}" != /bin ] || continue
  _fm_win_mount_src+=("/${BASH_REMATCH[1],,}${BASH_REMATCH[2]%/}")
  _fm_win_mount_dst+=("${BASH_REMATCH[3]%/}")
done < /proc/mounts
unset _fm_win_line _fm_win_re

pwd() {
  local dir i src best=-1 len=0
  if [ "$*" != -P ]; then
    builtin pwd "$@"
    return
  fi
  dir=$(builtin pwd -P) || return
  for i in "${!_fm_win_mount_src[@]}"; do
    src=${_fm_win_mount_src[i],,}
    case ${dir,,}/ in
      "$src"/*) [ "${#src}" -le "$len" ] || { best=$i len=${#src}; } ;;
    esac
  done
  [ "$best" -lt 0 ] || dir=${_fm_win_mount_dst[best]}${dir:len}
  printf '%s\n' "${dir:-/}"
}
