# shellcheck shell=bash
# Source this from the Git Bash that runs firstmate on Windows: a profile, a
# pane bootstrap, or a test lane. Sourcing it again changes nothing.
#
# What it sets up, for this shell and every MSYS child it starts:
#   - bin/ first on PATH, so upstream's `ps` and `jq` calls reach the shims.
#   - MSYS=winsymlinks:nativestrict, so `ln -s` makes a real symlink, not a copy.
#   - Private state with real modes. Git Bash mounts every drive noacl, so
#     `mkdir -m 700` exits 1 and leaves 755. A user mount with acl needs no
#     admin, but it is shared by every Git Bash of this Windows user until the
#     last one exits, and it redirects cygpath for every path beneath it. So
#     only directories firstmate owns are mounted: FM_HOME and a dedicated temp
#     directory, each at /tmp/fm-acl/<its drive spelling>, and FM_HOME and
#     TMPDIR are exported in that spelling. A mount only takes effect outside
#     the /c drive prefix, and only where its parent directory really exists,
#     which /tmp provides. The /tmp mount itself is a system entry a user
#     cannot replace, so any other literal /tmp path stays noacl.
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

# Set _fm_win_acl to the acl spelling of Windows path $1 (C:/x/y), mounting it
# unless /proc/mounts already has it.
_fm_win_acl_mount() {
  local win=$1 drive=${1%%:*} line
  _fm_win_acl=/tmp/fm-acl/${drive,,}${win#?:}
  while IFS= read -r line; do
    case $line in "$win $_fm_win_acl "*) return 0 ;; esac
  done < /proc/mounts
  mkdir -p "$win" "$_fm_win_acl" 2>/dev/null
  mount -o binary,posix=0,acl "$win" "$_fm_win_acl" 2>/dev/null
}

_fm_win_home='' _fm_win_tmp=''
case ${FM_HOME:-} in /tmp/fm-acl/*) ;; *) _fm_win_home=${FM_HOME:-$_fm_win_dir/../..} ;; esac
case ${TMPDIR:-} in /tmp/fm-acl/*) ;; *) _fm_win_tmp=/tmp/fm-platform-windows ;; esac
if [ -n "$_fm_win_home$_fm_win_tmp" ]; then
  {
    [ -z "$_fm_win_home" ] || read -r _fm_win_home
    [ -z "$_fm_win_tmp" ] || read -r _fm_win_tmp
  } < <(cygpath -m ${_fm_win_home:+"$_fm_win_home"} ${_fm_win_tmp:+"$_fm_win_tmp"})
  if [ -n "$_fm_win_home" ]; then _fm_win_acl_mount "$_fm_win_home"; FM_HOME=$_fm_win_acl; fi
  if [ -n "$_fm_win_tmp" ]; then _fm_win_acl_mount "$_fm_win_tmp"; TMPDIR=$_fm_win_acl; fi
fi

FM_PLATFORM_OVERLAY=$_fm_win_dir/overrides.sh
export PATH MSYS FM_HOME TMPDIR FM_PLATFORM_OVERLAY
unset -f _fm_win_acl_mount
unset _fm_win_dir _fm_win_path _fm_win_msys _fm_win_word _fm_win_home _fm_win_tmp _fm_win_acl
