# shellcheck shell=bash
# env.sh exports this as BASH_ENV, so every non-interactive bash below it runs
# it first, including one started by a native program such as claude.exe, which
# does not pass the MSYS umask on. See env.sh for why the umask is 077.
umask 077
# shellcheck source=/dev/null
[ -z "${FM_WIN_PRIOR_BASH_ENV:-}" ] || . "$FM_WIN_PRIOR_BASH_ENV"
