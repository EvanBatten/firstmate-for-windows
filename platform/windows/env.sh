# shellcheck shell=bash
# Source this from the Git Bash that runs firstmate on Windows: a profile, a
# pane bootstrap, or a test lane. Sourcing it again changes nothing.
#
# What it sets up, for this shell and every MSYS child it starts:
#   - MSYS=winsymlinks:nativestrict, so `ln -s` makes a real symlink, not a copy.
#   - umask 077, and BASH_ENV so every bash below a native program such as
#     claude.exe gets it too. Git Bash mounts drives noacl: chmod changes
#     nothing, and stat reports the mode the reading process's umask implies,
#     not a mode stored on the file. At 077 every file reads as 600 or 700, so
#     upstream's private-mode checks and `mkdir -m 700` pass. What keeps the
#     files private is the directory ACL.

case ${BASH_SOURCE[0]} in
  */*) _fm_win_dir=${BASH_SOURCE[0]%/*} ;;
  *) _fm_win_dir=. ;;
esac
case $_fm_win_dir in /*) ;; *) _fm_win_dir=$PWD/$_fm_win_dir ;; esac

# A native parent such as claude.exe hands CLAUDE_CONFIG_DIR down in drive
# spelling, which upstream refuses as a relative path. A native child gets the
# POSIX spelling converted back.
case ${CLAUDE_CONFIG_DIR:-} in
  [A-Za-z]:*) CLAUDE_CONFIG_DIR=$(cygpath -u -- "$CLAUDE_CONFIG_DIR") && export CLAUDE_CONFIG_DIR ;;
esac

_fm_win_path=":$PATH:"
_fm_win_path=${_fm_win_path//":$_fm_win_dir/bin:"/:}
_fm_win_path=${_fm_win_path#:}
PATH=$_fm_win_dir/bin:${_fm_win_path%:}

_fm_win_msys=
for _fm_win_word in ${MSYS:-}; do
  case $_fm_win_word in winsymlinks*) ;; *) _fm_win_msys="$_fm_win_msys $_fm_win_word" ;; esac
done
MSYS="winsymlinks:nativestrict$_fm_win_msys"

_fm_win_home=${FM_HOME:-$_fm_win_dir/../..}
_fm_win_private=0
IFS=';' read -r -a _fm_win_roots <<< "${FM_WIN_PRIVATE_ROOTS:-}"
for _fm_win_root in "${_fm_win_roots[@]}"; do
  [ "$_fm_win_root" -ef "$_fm_win_home" ] && _fm_win_private=1 && break
done
if [ "$_fm_win_private" = 0 ]; then
  if _fm_win_out=$(bash "$_fm_win_dir/private-root.sh" check "$_fm_win_home" /tmp); then
    # Drive spelling and ';' pass through a native parent unconverted.
    FM_WIN_PRIVATE_ROOTS=${FM_WIN_PRIVATE_ROOTS:+$FM_WIN_PRIVATE_ROOTS;}$(cygpath -m -- "$_fm_win_home")
    _fm_win_private=1
  else
    printf '%s\n' "$_fm_win_out" | grep -v '^private ' >&2
  fi
fi
# A native parent hands BASH_ENV back in drive spelling, so compare files.
_fm_win_overlay_bash_env=0
if [ -n "${BASH_ENV:-}" ]; then
  [ "$BASH_ENV" -ef "$_fm_win_dir/bash-env.sh" ] && _fm_win_overlay_bash_env=1
  [ -n "${FM_PLATFORM_OVERLAY:-}" ] && [ "$BASH_ENV" -ef "${FM_PLATFORM_OVERLAY%/*}/bash-env.sh" ] && _fm_win_overlay_bash_env=1
fi
if [ "$_fm_win_private" = 1 ]; then
  umask 077
  [ "$_fm_win_overlay_bash_env" = 1 ] || FM_WIN_PRIOR_BASH_ENV=${BASH_ENV:-}
  BASH_ENV=$_fm_win_dir/bash-env.sh
  export BASH_ENV FM_WIN_PRIOR_BASH_ENV
else
  umask 022
  if [ "$_fm_win_overlay_bash_env" = 1 ]; then
    if [ -n "${FM_WIN_PRIOR_BASH_ENV:-}" ]; then BASH_ENV=$FM_WIN_PRIOR_BASH_ENV; else unset BASH_ENV; fi
    unset FM_WIN_PRIOR_BASH_ENV
  fi
fi

FM_PLATFORM_OVERLAY=$_fm_win_dir/overrides.sh
export PATH MSYS FM_PLATFORM_OVERLAY FM_WIN_PRIVATE_ROOTS
unset _fm_win_dir _fm_win_path _fm_win_msys _fm_win_word _fm_win_home _fm_win_out \
  _fm_win_private _fm_win_roots _fm_win_root _fm_win_overlay_bash_env
