#!/usr/bin/env bash
# Round-2 evidence: run the tracked Claude SessionStart registration end to end
# (e2e-claude-sessionstart-lock-r2.sh: node spawns Git for Windows'
# bash.exe -c <registered command>, JSON payload on stdin, under this session's
# claude.exe) with a counting `pwsh` shim first on PATH. Every Win32 ancestry
# walk in bin/fm-proc-lib.sh is exactly one pwsh process, so the shim's log is
# the number of walks one session open paid, and which script paid each one.
# The shim execs the real pwsh, so the walks still resolve the real ancestry.
#
# SOURCE this from the agent's own foreground tool shell, do not run it with
# `bash`: an MSYS fork+exec of another bash between claude.exe and node leaves
# that bash with a dead Win32 parent, so the walk would stop short of claude.exe
# and the hook would (correctly) divert to the nudge. The same applies to a
# background tool task. The first attempt this round did exactly that and both
# commits nudged; sourcing keeps node a direct child of the tool shell.
# usage: . e2e-sessionstart-walk-count.sh <repo> <commit> <label>
set -u
_wc_repo=$1 _wc_commit=$2 _wc_label=$3
_wc_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_wc_shim=$(mktemp -d "${TMPDIR:-/tmp}/fm-e2e-pwsh-shim.XXXXXX")
_wc_log="$_wc_shim/pwsh.log"
_wc_real=$(command -v pwsh) || { echo "no pwsh on PATH" >&2; return 2; }
: > "$_wc_log"
cat > "$_wc_shim/pwsh" <<SH
#!/usr/bin/env bash
caller=\$(tr '\0' ' ' < /proc/\$PPID/cmdline 2>/dev/null)
printf '%s\tquery_pid=%s\tcaller=%s\n' "\$(date +%s)" "\${FM_PROC_QUERY_PID:-}" "\${caller:0:120}" >> "$_wc_log"
exec "$_wc_real" "\$@"
SH
chmod +x "$_wc_shim/pwsh"
_wc_path=$PATH
PATH="$_wc_shim:$PATH"
. "$_wc_here/e2e-claude-sessionstart-lock-r2.sh" "$_wc_repo" "$_wc_commit" "$_wc_label"
PATH=$_wc_path
echo "--- Win32 ancestry walks (pwsh processes) this session open paid: $(grep -c . "$_wc_log")"
awk -F'\t' '{ sub(/^caller=/, "", $3); sub(/fm-e2e-ss-[^\/]*\//, "<home>/", $3); n[$3]++ } END { for (c in n) printf "  %d x %s\n", n[c], c }' "$_wc_log" | sort -rn
rm -rf "$_wc_shim"
