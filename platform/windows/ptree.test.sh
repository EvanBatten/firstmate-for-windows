#!/usr/bin/env bash
# fm_win32_chain_load answers the Win32 parent chain from ptree.exe, compiled
# once into the user's cache, with the same rows pwsh's Get-Process gives, and
# still answers through pwsh where the compiler is missing.
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1
# shellcheck source=platform/windows/env.sh
. platform/windows/env.sh

T=$(mktemp -d /tmp/fm-win-ptree.XXXXXX)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }

root=$(cat /proc/$$/winpid)
pwsh_rows() {
  # shellcheck disable=SC2016 # PowerShell expands these.
  FM_WIN_ROOT=$1 pwsh -NoProfile -NonInteractive -Command '
$p = Get-Process -Id ([int]$env:FM_WIN_ROOT) -ErrorAction SilentlyContinue
for ($i = 0; $i -lt 16 -and $p; $i++) {
  $q = $null; try { $q = $p.Parent } catch {}
  "{0}`t{1}" -f $p.Id, $(if ($q) { $q.Id } else { 0 })
  $p = $q
}' 2>/dev/null | tr -d '\r'
}
# Each case loads the chain in a fresh bash with its own empty cache, so no
# earlier row can answer for the helper or for pwsh.
chain_rows() {  # <tmpdir> [env...]
  local tmp=$1; shift
  mkdir -p "$tmp"
  # shellcheck disable=SC2016 # The child bash expands these.
  env TMPDIR="$tmp" "$@" bash -c '
    . platform/windows/proc.sh
    fm_win32_chain_load "$1" || exit 1
    pid=$1
    while [ -n "${_FM_W32_PPID[$pid]+x}" ]; do
      printf "%s\t%s\n" "$pid" "${_FM_W32_PPID[$pid]}"
      [ "${_FM_W32_PPID[$pid]}" != 0 ] || break
      pid=${_FM_W32_PPID[$pid]}
    done
    printf "helper=%s\n" "${_FM_WIN_PTREE_EXE:-none}"' _ "$root"
}

want=$(pwsh_rows "$root")
[ -n "$want" ] || not_ok "pwsh answered the chain of this shell"

got=$(chain_rows "$T/helper")
case $got in
  *"helper=$T/helper/fm-platform-windows/ptree.exe"*) ok "the chain load compiled ptree.exe into the private cache and used it" ;;
  *) not_ok "the chain load did not use a compiled ptree.exe (got: $got)" ;;
esac
if [ "${got%$'\n'helper=*}" = "$want" ]; then ok "ptree.exe gives the pids and parents pwsh gives"
else not_ok "ptree.exe rows differ from pwsh: ${got%$'\n'helper=*} vs $want"; fi

exe=$T/helper/fm-platform-windows/ptree.exe
# services.exe's parent is a process whose creation time a user cannot read, so
# nothing proves it older than its child and its pid may be a reused one.
services=$(tasklist //FI "IMAGENAME eq services.exe" //FO CSV //NH | tr -d '\r' | cut -d'"' -f4)
want_unread=$(pwsh_rows "$services")
got_unread=$("$exe" "$services" | cut -f1,2 | tr -d '\r')
if [ -n "$services" ] && [ "$got_unread" = "$want_unread" ]; then ok "ptree.exe stops where a parent's age cannot be read, as pwsh does"
else not_ok "ptree.exe followed a parent of unknown age from services.exe $services: $got_unread vs $want_unread"; fi

touch -d '2001-01-01' "$exe"
rm -f "$T"/helper/fm-platform-windows/chain-*
got=$(chain_rows "$T/helper" FM_WIN_CSC="$T/no-such-csc.exe")
case $got in
  *"helper=$exe"*) ok "a later load reuses the built ptree.exe without a compiler" ;;
  *) not_ok "a later load did not reuse ptree.exe (got: $got)" ;;
esac
if [ "$(stat -c %Y "$exe")" = "$(date -d '2001-01-01' +%s)" ]; then ok "the reuse did not rebuild it"; else not_ok "the reuse rebuilt ptree.exe"; fi
printf 'stale' > "$exe.cs"
rm -f "$T"/helper/fm-platform-windows/chain-*
got=$(chain_rows "$T/helper")
if [ "$(stat -c %Y "$exe")" != "$(date -d '2001-01-01' +%s)" ]; then ok "a changed source rebuilds ptree.exe"; else not_ok "a changed source kept the old ptree.exe"; fi

got=$(chain_rows "$T/nocsc" FM_WIN_CSC="$T/no-such-csc.exe")
case $got in
  *"helper=none"*) ok "without a compiler the chain load falls back to pwsh" ;;
  *) not_ok "a missing compiler still produced a helper (got: $got)" ;;
esac
if [ "${got%$'\n'helper=*}" = "$want" ]; then ok "the pwsh fallback gives the same rows"
else not_ok "the fallback rows differ: ${got%$'\n'helper=*} vs $want"; fi

[ "$fails" -eq 0 ]
