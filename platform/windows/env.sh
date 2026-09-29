# shellcheck shell=bash
# Source this from the Git Bash that runs firstmate on Windows: a profile, a
# pane bootstrap, or a test lane. Sourcing it again changes nothing.
#
# What it sets up, for this shell and every MSYS child it starts:
#   - bin/ first on PATH, so upstream's `ps` and `jq` calls reach the shims.
#   - MSYS=winsymlinks:nativestrict, so `ln -s` makes a real symlink, not a copy.
#   - umask 077, and BASH_ENV so every bash below a native program such as
#     claude.exe gets it too. Git Bash mounts drives noacl: chmod changes
#     nothing, and stat reports the mode the reading process's umask implies,
#     not a mode stored on the file. At 077 every file reads as 600 or 700, so
#     upstream's private-mode checks and `mkdir -m 700` pass. What keeps the
#     files private is the directory ACL, so the umask is set only when
#     private-root.sh finds FM_HOME and /tmp private.
#   - FM_PLATFORM_OVERLAY, which the one-line hooks in upstream libraries source.

case ${BASH_SOURCE[0]} in
  */*) _fm_win_dir=${BASH_SOURCE[0]%/*} ;;
  *) _fm_win_dir=. ;;
esac
case $_fm_win_dir in /*) ;; *) _fm_win_dir=$PWD/$_fm_win_dir ;; esac

_fm_win_path=":$PATH:"
_fm_win_path=${_fm_win_path//":$_fm_win_dir/bin:"/:}
_fm_win_path=${_fm_win_path#:}
PATH=$_fm_win_dir/bin:${_fm_win_path%:}

_fm_win_msys=
for _fm_win_word in ${MSYS:-}; do
  case $_fm_win_word in winsymlinks*) ;; *) _fm_win_msys="$_fm_win_msys $_fm_win_word" ;; esac
done
MSYS="winsymlinks:nativestrict$_fm_win_msys"

# The umask only makes modes read private, so it is set only once the roots
# firstmate writes check private. Otherwise upstream's checks read 755 and
# refuse. A child inherits the verdict and skips the 0.3 s icacls check.
_fm_win_home=${FM_HOME:-$_fm_win_dir/../..}
if [ "${FM_WIN_PRIVATE_ROOTS:-}" != "$_fm_win_home:/tmp" ]; then
  FM_WIN_PRIVATE_ROOTS=
  if _fm_win_out=$(bash "$_fm_win_dir/private-root.sh" check "$_fm_win_home" /tmp); then
    FM_WIN_PRIVATE_ROOTS=$_fm_win_home:/tmp
  else
    printf '%s\n' "$_fm_win_out" | grep -v '^private ' >&2
  fi
fi
if [ -n "$FM_WIN_PRIVATE_ROOTS" ]; then
  umask 077
  # A native parent hands BASH_ENV back in drive spelling, so compare files.
  if [ -z "${BASH_ENV:-}" ] || [ ! "$BASH_ENV" -ef "$_fm_win_dir/bash-env.sh" ]; then
    FM_WIN_PRIOR_BASH_ENV=${BASH_ENV:-}
  fi
  BASH_ENV=$_fm_win_dir/bash-env.sh
  export BASH_ENV FM_WIN_PRIOR_BASH_ENV
fi

FM_PLATFORM_OVERLAY=$_fm_win_dir/overrides.sh
export PATH MSYS FM_PLATFORM_OVERLAY FM_WIN_PRIVATE_ROOTS
unset _fm_win_dir _fm_win_path _fm_win_msys _fm_win_word _fm_win_home _fm_win_out
