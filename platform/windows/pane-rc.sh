# shellcheck shell=bash
# The rcfile of the Git Bash that herdr.sh starts in every herdr pane, in
# place of the ~/.bashrc an interactive bash would read.
#
# `treehouse get` in a pane opens a subshell with $SHELL, and fm-spawn waits
# for the pane's cwd to move into that subshell's worktree. Herdr sets SHELL
# to pwsh.exe, which treehouse starts and which exits at once, so the cwd
# never moves. SHELL is therefore this bash, and the prompt command is
# exported and self-contained: a nested bash reads no pane-rc, so the prompt
# command itself sources env.sh once per shell and reports the cwd.

# Herdr drops a PATH passed with --env, so the creating shell's PATH arrives
# under this name.
[ -z "${FM_PANE_PATH:-}" ] || PATH=$FM_PANE_PATH
# shellcheck source=/dev/null
[ ! -r ~/.bashrc ] || . ~/.bashrc
# shellcheck source=platform/windows/env.sh
. "${BASH_SOURCE[0]%/*}/env.sh"
_FM_WIN_PANE_SHELL=1

# A native program such as treehouse.exe needs the Windows spelling.
SHELL=$(cygpath -w "$BASH")

# Herdr's pane cwd on Windows is whatever the shell last reported with OSC 9;9.
# _FM_WIN_PANE_SHELL stays unexported, so each nested shell sees it unset.
_fm_win_env=${BASH_SOURCE[0]%/*}/env.sh
# shellcheck disable=SC2016,SC2089 # A command string, expanded at each prompt.
printf -v PROMPT_COMMAND '[ -n "${_FM_WIN_PANE_SHELL-}" ] || { _FM_WIN_PANE_SHELL=1; . %q; }; printf %q "$(cygpath -w "$PWD")"%s' \
  "$_fm_win_env" $'\e]9;9;%s\a' "${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
# shellcheck disable=SC2090
export SHELL PROMPT_COMMAND
unset _fm_win_env

# herdr.sh waits for this title before it lets anything be typed, so it
# comes last.
printf '\e]0;Git Bash\a'
