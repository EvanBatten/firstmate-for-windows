# shellcheck shell=bash
# Sourced by overrides.sh once the herdr adapter is loaded, so it runs again
# after every hooked library. Sourcing it again changes nothing.
#
# Herdr here is a native Windows program, and upstream talks to it as if it
# were a Unix one. This file fixes the four places where that shows:
#   - MSYS rewrites any argument that looks like a POSIX path before a native
#     program sees it, so a bare `/exit` typed into a pane arrives as
#     `C:/Program Files/Git/exit`. Every herdr call runs with argument
#     conversion off, and only a `--cwd` value is converted, explicitly.
#   - A new pane runs herdr's default shell, pwsh. Each created root pane is
#     turned into an interactive Git Bash that sources env.sh (pane-rc.sh),
#     and the create returns only once that bash has set its title, because a
#     line typed while bash is still starting loses its head.
#   - Herdr reports its socket as C:\...\herdr.sock, which upstream refuses as
#     not absolute. It is folded to /c/... first.
#   - `pane get` never fills foreground_cwd here. The pane's cwd comes from
#     the OSC 9;9 that pane-rc.sh prints at each prompt, in drive spelling.
#
# A herdr found on PATH that is not a native program is a test fixture's fake,
# and gets every call byte for byte as upstream made it.

# Resolved again only when PATH changes. The common path must not fork: every
# adapter call runs through herdr().
_fm_win_herdr_resolve() {
  local magic=
  _FM_WIN_HERDR_PATH_KEY=$PATH
  _FM_WIN_HERDR_BIN=$(type -P herdr)
  _FM_WIN_HERDR_NATIVE=0
  [ -n "$_FM_WIN_HERDR_BIN" ] && IFS= LC_ALL=C read -r -n 2 magic < "$_FM_WIN_HERDR_BIN"
  [ "$magic" != MZ ] || _FM_WIN_HERDR_NATIVE=1
  return 0
}

herdr() {
  [ "$PATH" = "${_FM_WIN_HERDR_PATH_KEY-}" ] || _fm_win_herdr_resolve
  if [ "$_FM_WIN_HERDR_NATIVE" != 1 ]; then
    command herdr "$@"
    return
  fi
  local args=() arg next_is_cwd=0
  for arg; do
    if [ "$next_is_cwd" = 1 ]; then
      arg=$(cygpath -w -- "$arg")
      next_is_cwd=0
    else
      case $arg in
        --cwd) next_is_cwd=1 ;;
        --cwd=*) arg=--cwd=$(cygpath -w -- "${arg#--cwd=}") ;;
      esac
    fi
    args+=("$arg")
  done
  case "${1-} ${2-}" in
    'tab create' | 'workspace create')
      _fm_win_herdr_create "${args[@]}"
      ;;
    'server '*)
      # Every pane inherits the server's environment, and a pane shell needs
      # conversion on for the native programs it starts.
      "$_FM_WIN_HERDR_BIN" "${args[@]}"
      ;;
    *)
      MSYS2_ARG_CONV_EXCL='*' "$_FM_WIN_HERDR_BIN" "${args[@]}"
      ;;
  esac
}

# Herdr drops a PATH passed with --env and keeps other names, so pane-rc.sh
# restores PATH from FM_PANE_PATH. FM_WIN_PRIVATE_ROOTS spares env.sh in the
# pane its icacls check.
_fm_win_herdr_create() {  # <create-args...>
  local out rc=0 session="" arg prev="" pane re='"root_pane":\{[^}]*"pane_id":"([^"]*)"'
  set -- "$@" --env "FM_PANE_PATH=$PATH"
  [ -z "${FM_WIN_PRIVATE_ROOTS:-}" ] || set -- "$@" --env "FM_WIN_PRIVATE_ROOTS=$FM_WIN_PRIVATE_ROOTS"
  # The trailing dot keeps any trailing newlines of herdr's answer.
  out=$(MSYS2_ARG_CONV_EXCL='*' "$_FM_WIN_HERDR_BIN" "$@"; rc=$?; printf .; exit "$rc") || rc=$?
  printf '%s' "${out%.}"
  [ "$rc" -eq 0 ] || return "$rc"
  for arg; do
    case $prev in --session) session=$arg ;; esac
    case $arg in --session=*) session=${arg#--session=} ;; esac
    prev=$arg
  done
  [ -n "$session" ] || session=${HERDR_SESSION:-}
  if [[ $out =~ $re ]]; then
    pane=${BASH_REMATCH[1]}
    _fm_win_herdr_bootstrap "$pane" "$session" || echo "warning: herdr pane $pane did not start Git Bash within ${FM_WIN_PANE_READY_TIMEOUT:-30}s" >&2
  fi
  return 0
}

# Ready means the rcfile has set the title. Before that, pwsh's title is
# null and then its own .exe path.
_fm_win_herdr_bootstrap() {  # <pane> <session>
  local pane=$1 bash_exe rcfile info title deadline sess=()
  local re='"terminal_title":"([^"]*)"'
  [ -z "$2" ] || sess=(--session "$2")
  bash_exe=$(cygpath -w "$BASH")
  rcfile=${FM_PLATFORM_OVERLAY%/*}/pane-rc.sh
  MSYS2_ARG_CONV_EXCL='*' "$_FM_WIN_HERDR_BIN" pane run "$pane" \
    "& '${bash_exe//\'/\'\'}' --rcfile '${rcfile//\'/\'\'}' -i; exit" "${sess[@]}" >/dev/null 2>&1 || return 1
  deadline=$(( ${EPOCHREALTIME/./} + ${FM_WIN_PANE_READY_TIMEOUT:-30} * 1000000 ))
  while [ "${EPOCHREALTIME/./}" -lt "$deadline" ]; do
    info=$(MSYS2_ARG_CONV_EXCL='*' "$_FM_WIN_HERDR_BIN" pane get "$pane" "${sess[@]}" 2>/dev/null)
    if [[ $info =~ $re ]]; then
      title=${BASH_REMATCH[1],,}
      [ -z "$title" ] || [[ $title == *.exe ]] || return 0
    fi
    sleep 0.1
  done
  return 1
}

# Keeps upstream's current body under _fm_win_upstream_<name> for the wrapper
# to call. Skipped when <name> is already the wrapper, so a second source
# neither wraps twice nor loses a body upstream has since redefined.
_fm_win_herdr_keep_upstream() {  # <name>
  local body
  body=$(declare -f "$1") || return 0
  case $body in *"_fm_win_upstream_$1"*) return 0 ;; esac
  eval "_fm_win_upstream_$body"
}

_fm_win_herdr_keep_upstream fm_backend_herdr_canonical_socket_path
fm_backend_herdr_canonical_socket_path() {  # <socket-path>
  local socket=$1
  case $socket in [A-Za-z]:[\\/]*) socket=$(cygpath -u -- "$socket") ;; esac
  _fm_win_upstream_fm_backend_herdr_canonical_socket_path "$socket"
}

_fm_win_herdr_keep_upstream fm_backend_herdr_current_path
fm_backend_herdr_current_path() {  # <target>
  local path
  [ "$PATH" = "${_FM_WIN_HERDR_PATH_KEY-}" ] || _fm_win_herdr_resolve
  if [ "$_FM_WIN_HERDR_NATIVE" != 1 ]; then
    _fm_win_upstream_fm_backend_herdr_current_path "$@"
    return
  fi
  fm_backend_herdr_target_ready "$1" || return 0
  path=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane get "$FM_BACKEND_HERDR_PANE" 2>/dev/null \
    | jq -r '.result.pane.foreground_cwd // .result.pane.cwd // empty' 2>/dev/null)
  case $path in [A-Za-z]:[\\/]*) path=$(cygpath -u -- "$path") ;; esac
  [ -z "$path" ] || printf '%s\n' "$path"
}
