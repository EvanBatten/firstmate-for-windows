# shellcheck shell=bash
# A Git Bash process chain has two pid spaces. A bash started by a native
# program (claude.exe, herdr.exe) reports ppid 1, so /proc stops there, and the
# rest of the chain exists only as Win32 pids.
#
# A native process has no readable command line without a CIM query per
# process, so its args are its executable path, the same as comm.

# A cached walk row can outlive its process by FM_WIN_CHAIN_TTL seconds, so the
# cache answers identity and parent links only, never liveness.
FM_WIN_CHAIN_TTL=${FM_WIN_CHAIN_TTL:-10}
FM_PROC_PPID='' FM_PROC_PGID='' FM_PROC_COMM='' FM_PROC_ARGS='' FM_PROC_WINPID=''
declare -gA _FM_W32_PPID=() _FM_W32_COMM=()

fm_win_msys_proc() {
  local root=/proc/$1 v
  local -a argv=()
  FM_PROC_COMM=''
  { read -r FM_PROC_COMM < "$root/exename"; } 2>/dev/null
  [ -n "$FM_PROC_COMM" ] || return 1
  v=0; { read -r v < "$root/ppid"; } 2>/dev/null; FM_PROC_PPID=$v
  v=0; { read -r v < "$root/pgid"; } 2>/dev/null; FM_PROC_PGID=$v
  v=''; { read -r v < "$root/winpid"; } 2>/dev/null; FM_PROC_WINPID=$v
  { mapfile -d '' -t argv < "$root/cmdline"; } 2>/dev/null
  FM_PROC_ARGS="${argv[*]}"
  FM_PROC_ARGS=${FM_PROC_ARGS//$'\n'/ }
  [ -n "$FM_PROC_ARGS" ] || FM_PROC_ARGS=$FM_PROC_COMM
}

_fm_win_image_name() {
  local p=${1//\\//}
  case "$p" in *.[Ee][Xx][Ee]) p=${p%????} ;; esac
  _FM_WIN_NAME=$p
}

_fm_win_cache_dir() {
  local dir=${TMPDIR:-/tmp}/fm-platform-windows
  [ -d "$dir" ] || mkdir -m 700 "$dir" 2>/dev/null || return 1
  [ -O "$dir" ] || return 1
  _FM_WIN_CACHE_DIR=$dir
}

_fm_win32_rows_load() {
  local pid ppid path
  while IFS=$'\t' read -r pid ppid path; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    _fm_win_image_name "$path"
    _FM_W32_PPID[$pid]=$ppid
    _FM_W32_COMM[$pid]=$_FM_WIN_NAME
  done <<< "$1"
}

_fm_win32_cache_load() {
  local file born out
  local -a stale=()
  [ -z "${_FM_WIN_CACHE_READ:-}" ] || return 0
  _FM_WIN_CACHE_READ=1
  _fm_win_cache_dir || return 0
  for file in "$_FM_WIN_CACHE_DIR"/chain-*; do
    born=0 out=''
    { IFS= read -r -d '' out < "$file"; } 2>/dev/null
    born=${out%%$'\n'*}
    case "$born" in ''|*[!0-9]*) continue ;; esac
    if [ $((EPOCHSECONDS - born)) -gt "$FM_WIN_CHAIN_TTL" ]; then
      stale+=("$file")
      continue
    fi
    _fm_win32_rows_load "${out#*$'\n'}"
  done
  [ "${#stale[@]}" -eq 0 ] || rm -f "${stale[@]}" 2>/dev/null
}

fm_win32_chain_load() {
  local root=$1 out
  case "$root" in ''|*[!0-9]*|0) return 1 ;; esac
  [ -n "${_FM_W32_PPID[$root]+x}" ] && return 0
  _fm_win32_cache_load
  [ -n "${_FM_W32_PPID[$root]+x}" ] && return 0
  # shellcheck disable=SC2016 # PowerShell syntax, passed through unexpanded.
  out=$(FM_WIN_ROOT=$root pwsh -NoProfile -NonInteractive -Command '
$p = Get-Process -Id ([int]$env:FM_WIN_ROOT) -ErrorAction SilentlyContinue
for ($i = 0; $i -lt 16 -and $p; $i++) {
  $q = $null; try { $q = $p.Parent } catch {}
  $c = $p.ProcessName; try { if ($p.Path) { $c = $p.Path } } catch {}
  "{0}`t{1}`t{2}" -f $p.Id, $(if ($q) { $q.Id } else { 0 }), $c
  $p = $q
}' 2>/dev/null) || return 1
  out=${out//$'\r'/}
  [ -n "$out" ] || return 1
  if _fm_win_cache_dir; then
    printf '%s\n%s\n' "$EPOCHSECONDS" "$out" > "$_FM_WIN_CACHE_DIR/chain-$root.$$" 2>/dev/null \
      && mv -f "$_FM_WIN_CACHE_DIR/chain-$root.$$" "$_FM_WIN_CACHE_DIR/chain-$root" 2>/dev/null
  fi
  _fm_win32_rows_load "$out"
  [ -n "${_FM_W32_PPID[$root]+x}" ]
}

# A native program started from an MSYS process, such as claude.exe started
# from Git Bash, has an MSYS pid too, whose /proc winpid is its Win32 pid.
fm_win_msys_pid() {
  local p w
  for p in /proc/[0-9]*; do
    w=''
    { read -r w < "$p/winpid"; } 2>/dev/null
    [ "$w" = "$1" ] || continue
    FM_WIN_MSYS_PID=${p#/proc/}
    return 0
  done
  return 1
}

_fm_win_parent_msys_first() {
  if fm_win_msys_pid "$1"; then
    FM_PROC_PPID=$FM_WIN_MSYS_PID FM_PROC_PSPACE=msys
  else
    FM_PROC_PPID=$1 FM_PROC_PSPACE=w32
  fi
}

# shellcheck disable=SC2034 # FM_PROC_PSPACE is read by the walks in overrides.sh.
fm_win_proc() {
  local pid=$1
  FM_PROC_PSPACE=msys
  if [ "${2:-}" != w32 ] && fm_win_msys_proc "$pid"; then
    if [ "$FM_PROC_PPID" -le 1 ] && fm_win32_chain_load "$FM_PROC_WINPID"; then
      _fm_win_parent_msys_first "${_FM_W32_PPID[$FM_PROC_WINPID]}"
    fi
    return 0
  fi
  [ -n "${_FM_W32_PPID[$pid]+x}" ] || _fm_win32_cache_load
  [ -n "${_FM_W32_PPID[$pid]+x}" ] || fm_win32_alive "$pid" || return 1
  fm_win32_chain_load "$pid" || return 1
  _fm_win_parent_msys_first "${_FM_W32_PPID[$pid]}"
  FM_PROC_PGID=$pid
  FM_PROC_COMM=${_FM_W32_COMM[$pid]}
  FM_PROC_ARGS=$FM_PROC_COMM
  FM_PROC_WINPID=$pid
}

# Windows pids are multiples of 4, so anything else is answered without a fork.
fm_win32_alive() {
  local pid=$1 line header='' wstart wlen cstart w
  case "$pid" in ''|*[!0-9]*|0) return 1 ;; esac
  [ $((pid % 4)) -eq 0 ] || return 1
  while IFS= read -r line; do
    if [ -z "$header" ]; then
      header=${line%%WINPID*}
      w=${header%%PGID*}
      wstart=$((${#w} + 4))
      wlen=$((${#header} + 6 - wstart))
      header=${line%%COMMAND*}
      cstart=${#header}
      continue
    fi
    w=${line:wstart:wlen}
    [ "${w// /}" = "$pid" ] || continue
    _fm_win_image_name "${line:cstart}"
    FM_PROC_COMM=$_FM_WIN_NAME FM_PROC_ARGS=$_FM_WIN_NAME
    return 0
  done < <(/usr/bin/ps -W 2>/dev/null)
  return 1
}

fm_win_ps() {
  local -a fields=()
  local pid='' table=0 exec_real=0 f a spec
  local -a argv=("$@")
  while [ $# -gt 0 ]; do
    case $1 in
      -o) spec=$2; shift 2 ;;
      -eo|-Ao|-axo) table=1; spec=$2; shift 2 ;;
      -e|-A|-ax) table=1; shift; continue ;;
      -p) pid=$2; shift 2; continue ;;
      *) exec_real=1; break ;;
    esac
    IFS=, read -r -a a <<< "$spec"
    for f in "${a[@]}"; do
      case $f in
        pid=|ppid=|pgid=|comm=|args=|command=) fields+=("${f%=}") ;;
        *) exec_real=1; break 2 ;;
      esac
    done
  done
  if [ "$exec_real" = 1 ] || { [ "$table" = 0 ] && [ -z "$pid" ]; } \
    || { [ "$table" = 1 ] && [ -n "$pid" ]; }; then
    /usr/bin/ps "${argv[@]}"
    return
  fi
  if [ "$table" = 1 ]; then
    for f in /proc/[0-9]*; do
      fm_win_msys_proc "${f#/proc/}" || continue
      _fm_win_ps_row "${f#/proc/}"
    done
    return 0
  fi
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ "${#fields[@]}" -eq 0 ]; then
    fm_win_msys_proc "$pid" || fm_win32_alive "$pid" || return 1
    fields=(pid comm)
  else
    fm_win_proc "$pid" || return 1
  fi
  _fm_win_ps_row "$pid"
}

_fm_win_ps_row() {
  local f
  local -a out=()
  for f in "${fields[@]}"; do
    case $f in
      pid) out+=("$1") ;;
      ppid) out+=("${FM_PROC_PPID:-0}") ;;
      pgid) out+=("${FM_PROC_PGID:-$1}") ;;
      comm) out+=("$FM_PROC_COMM") ;;
      args|command) out+=("$FM_PROC_ARGS") ;;
    esac
  done
  printf '%s\n' "${out[*]}"
}
