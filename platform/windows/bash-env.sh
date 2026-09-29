# shellcheck shell=bash
# A native program such as claude.exe does not pass the MSYS umask on to the
# bash it starts, and a child can serve another home than its parent. Run at
# 077 only when this bash's FM_HOME is one env.sh recorded as private.
_fm_win_umask=022
IFS=';' read -r -a _fm_win_roots <<< "${FM_WIN_PRIVATE_ROOTS:-}"
for _fm_win_root in "${_fm_win_roots[@]}"; do
  [ "$_fm_win_root" -ef "${FM_HOME:-${BASH_SOURCE[0]%/*}/../..}" ] && _fm_win_umask=077 && break
done
umask "$_fm_win_umask"
unset _fm_win_umask _fm_win_roots _fm_win_root
# shellcheck source=/dev/null
[ -z "${FM_WIN_PRIOR_BASH_ENV:-}" ] || . "$FM_WIN_PRIOR_BASH_ENV"
