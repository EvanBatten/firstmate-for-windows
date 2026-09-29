#!/usr/bin/env bash
# shellcheck disable=SC2016
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1

T=$(mktemp -d /tmp/fm-win-claude.XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/bin" "$T/home/platform" "$T/native" "$T/msys" "$T/elsewhere"
cp -r platform/windows "$T/home/platform/windows"
: > "$T/home/bin/fm-lock.sh"
cp "$(cygpath -u "$COMSPEC")" "$T/native/claude.exe"
cp /usr/bin/env.exe "$T/msys/claude.exe"
printf '%s\n' '. $env:FM_T_PS1' 'Set-Location -LiteralPath $env:FM_T_DIR' 'claude @args' '"rc=$LASTEXITCODE"' > "$T/run.ps1"
cat > "$T/report.sh" << EOF
o=off; [ -n "\${FM_PLATFORM_OVERLAY:-}" ] && [ "\$FM_PLATFORM_OVERLAY" -ef "$T/home/platform/windows/overrides.sh" ] && o=on
m=none; for p in /proc/[0-9]*; do [ "\$(cat "\$p/exename" 2> /dev/null)" = "$T/native/claude" ] && m=msys; done
echo "overlay=\$o umask=\$(umask) claude_pid=\$m"
EOF
report=$(cygpath -w "$T/report.sh")

fails=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
expect() {
  if [ "$3" = "$2" ]; then ok "$1"; else not_ok "$1 (want: $2, got: $3)"; fi
}

pwsh_claude() {
  local fake=$1 dir=$2
  shift 2
  env -u FM_PLATFORM_OVERLAY -u BASH_ENV -u FM_WIN_PRIVATE_ROOTS -u FM_WIN_PRIOR_BASH_ENV \
    PATH="$fake:$PATH" FM_T_DIR="$(cygpath -w "$dir")" FM_T_PS1="$(cygpath -w "$ROOT/platform/windows/claude.ps1")" \
    MSYS2_ARG_CONV_EXCL='*' pwsh -NoProfile -File "$(cygpath -w "$T/run.ps1")" "$@" | tr -d '\r' | tr '\n' ' ' | sed 's/ $//'
}

expect "in a firstmate home claude runs under the overlay with an MSYS pid" \
  "overlay=on umask=0077 claude_pid=msys rc=0" \
  "$(pwsh_claude "$T/native" "$T/home" /d /c bash "$report")"
expect "outside a home claude is the plain executable" \
  "overlay=off umask=0022 claude_pid=none rc=0" \
  "$(pwsh_claude "$T/native" "$T/elsewhere" /d /c bash "$report")"
expect "arguments reach claude unchanged" \
  '[a b][c"d][] rc=0' \
  "$(pwsh_claude "$T/msys" "$T/home" sh -c 'printf "[%s]" "$@"; echo' _ 'a b' 'c"d' '')"
expect "claude's exit code comes back to PowerShell" \
  "rc=7" \
  "$(pwsh_claude "$T/native" "$T/home" /d /c exit 7)"

[ "$fails" -eq 0 ]
