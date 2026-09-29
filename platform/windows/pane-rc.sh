# shellcheck shell=bash
# The rcfile of the Git Bash that herdr.sh starts in every herdr pane, in
# place of the ~/.bashrc an interactive bash would read.

# Herdr drops a PATH passed with --env, so the creating shell's PATH arrives
# under this name.
[ -z "${FM_PANE_PATH:-}" ] || PATH=$FM_PANE_PATH
# shellcheck source=/dev/null
[ ! -r ~/.bashrc ] || . ~/.bashrc
# shellcheck source=platform/windows/env.sh
. "${BASH_SOURCE[0]%/*}/env.sh"

# Herdr's pane cwd on Windows is whatever the shell last reported with OSC 9;9.
_fm_win_report_cwd() { printf '\e]9;9;%s\a' "$(cygpath -w "$PWD")"; }
PROMPT_COMMAND="_fm_win_report_cwd${PROMPT_COMMAND:+;$PROMPT_COMMAND}"

# herdr.sh waits for this title before it lets anything be typed, so it
# comes last.
printf '\e]0;Git Bash\a'
