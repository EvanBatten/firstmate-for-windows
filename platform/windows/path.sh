# shellcheck shell=bash
# Sourced by env.sh and bash-env.sh, so every bash the overlay reaches has it.
#
# Git Bash mounts some Windows directories a second time, most visibly %TEMP%
# at /tmp, so one directory has two POSIX spellings: /tmp/x and
# /c/Users/<user>/AppData/Local/Temp/x. `pwd -P` keeps whichever one the shell
# entered by, while a path a native program prints, such as git.exe's
# --git-common-dir or the gitdir treehouse writes, comes back through the
# mount as /tmp/x. Upstream decides "same directory" by comparing the strings
# `pwd` and `pwd -P` print, so here both answer in the mount's spelling, the
# one `cygpath -u` gives, without forking.

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


# Sets <var> to <path> respelled through the mount that holds it.
_fm_win_mount_spelling() {  # <var> <path>
  local _fm_win_p=$2 i src best=-1 len=0
  for i in "${!_fm_win_mount_src[@]}"; do
    src=${_fm_win_mount_src[i],,}
    case ${_fm_win_p,,}/ in
      "$src"/*) [ "${#src}" -le "$len" ] || { best=$i len=${#src}; } ;;
    esac
  done
  [ "$best" -lt 0 ] || _fm_win_p=${_fm_win_mount_dst[best]}${_fm_win_p:len}
  printf -v "$1" '%s' "${_fm_win_p:-/}"
}

pwd() {
  local dir logical=$PWD oldpwd=${OLDPWD-} had_oldpwd=${OLDPWD+1}
  case $* in
    '' | -L) dir=$PWD ;;
    -P)
      # cd -P resolves symlinks as `builtin pwd -P` does, without the subshell
      # that capturing its output would fork. If the logical spelling no
      # longer resolves, the shell stays in the same directory spelled
      # physically.
      builtin cd -P . || return
      dir=$PWD
      [ "$dir" = "$logical" ] || builtin cd -- "$logical" 2>/dev/null || :
      if [ -n "$had_oldpwd" ]; then OLDPWD=$oldpwd; else unset OLDPWD; fi
      ;;
    *) builtin pwd "$@"; return ;;
  esac
  _fm_win_mount_spelling dir "$dir"
  printf '%s\n' "$dir"
}

# Upstream compares FM_HOME as a string with the home a session recorded, and
# the primary may type either spelling.
case ${FM_HOME:-} in /*) _fm_win_mount_spelling FM_HOME "$FM_HOME" ;; esac
