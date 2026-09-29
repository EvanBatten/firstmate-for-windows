# shellcheck shell=bash
# A native program such as claude.exe does not pass the MSYS umask on to the
# bash it starts. See env.sh for why the umask is 077.
umask 077
# shellcheck source=/dev/null
[ -z "${FM_WIN_PRIOR_BASH_ENV:-}" ] || . "$FM_WIN_PRIOR_BASH_ENV"
