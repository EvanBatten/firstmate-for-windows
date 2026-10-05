# shellcheck shell=bash
# shellcheck source=/dev/null # Its pwd() would read as every caller's own function.
. "${BASH_SOURCE[0]%/*}/path.sh"
# A native program such as claude.exe does not pass the MSYS umask on to the
# bash it starts.
_fm_win_umask=022
IFS=';' read -r -a _fm_win_roots <<< "${FM_WIN_PRIVATE_ROOTS:-}"
for _fm_win_root in "${_fm_win_roots[@]}"; do
  [ "$_fm_win_root" -ef "${FM_HOME:-${BASH_SOURCE[0]%/*}/../..}" ] && _fm_win_umask=077 && break
done
umask "$_fm_win_umask"
unset _fm_win_umask _fm_win_roots _fm_win_root
# A native parent such as claude.exe hands CLAUDE_CONFIG_DIR down in drive
# spelling, which upstream refuses as a relative path. A native child gets the
# POSIX spelling converted back.
case ${CLAUDE_CONFIG_DIR:-} in
  [A-Za-z]:*) CLAUDE_CONFIG_DIR=$(cygpath -u -- "$CLAUDE_CONFIG_DIR") && export CLAUDE_CONFIG_DIR ;;
esac
# shellcheck source=/dev/null
[ -z "${FM_WIN_PRIOR_BASH_ENV:-}" ] || . "$FM_WIN_PRIOR_BASH_ENV"
