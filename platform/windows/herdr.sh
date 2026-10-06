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
#   - A new pane runs herdr's default shell, pwsh, and a line typed into pwsh
#     echoes slowly under PSReadLine and lands in the captain's own history.
#     So no pane is typed into to start Git Bash: a created tab is laid out
#     with Git Bash on pane-rc.sh as its pane's program, through the
#     socket's layout.apply, which the CLI does not offer. A created
#     workspace's seeded pane is replaced the same way.
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
    return $?
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

# Answers as the CLI's create would, with a Git Bash pane where the CLI puts
# pwsh. Herdr drops a PATH passed in a pane's env, so pane-rc.sh restores PATH
# from FM_PANE_PATH. FM_WIN_PRIVATE_ROOTS spares env.sh in the pane its
# icacls check.
_fm_win_herdr_create() {  # <tab|workspace> create <args...>
  local kind=$1 arg prev='' workspace='' cwd='' label='' focus=false env root out layout session=()
  local rc=${FM_PLATFORM_OVERLAY%/*}/pane-rc.sh vars=(--arg FM_PANE_PATH "$PATH")
  [ -r "$rc" ] || { echo "error: no pane-rc.sh at $rc for the pane's Git Bash" >&2; return 1; }
  [ -z "${FM_WIN_PRIVATE_ROOTS:-}" ] || vars+=(--arg FM_WIN_PRIVATE_ROOTS "$FM_WIN_PRIVATE_ROOTS")
  for arg in "${@:3}"; do
    case $prev in
      --session) session=(--session "$arg") ;;
      --workspace) workspace=$arg ;;
      --cwd) cwd=$arg ;;
      --label) label=$arg ;;
      --env) vars+=(--arg "${arg%%=*}" "${arg#*=}") ;;
    esac
    case $arg in
      --focus) focus=true ;;
      --session=*) session=("$arg") ;;
    esac
    prev=$arg
  done
  env=$(MSYS2_ARG_CONV_EXCL='*' jq -nc "${vars[@]}" '$ARGS.named') || return 1
  root=$(jq -nc --argjson env "$env" --arg cwd "$cwd" --arg bash "$(cygpath -w -- "$BASH")" \
    --arg rc "$(cygpath -w -- "$rc")" \
    '{type: "pane", command: [$bash, "--rcfile", $rc, "-i"], env: $env} + if $cwd == "" then {} else {cwd: $cwd} end') || return 1

  if [ "$kind" = tab ]; then
    layout=$(_fm_win_herdr_api layout.apply "$(jq -nc --argjson root "$root" --argjson focus "$focus" \
      --arg ws "$workspace" --arg label "$label" \
      '{root: $root, focus: $focus} + (if $ws == "" then {} else {workspace_id: $ws} end)
        + if $label == "" then {} else {tab_label: $label} end')" "${session[@]}") || return 1
    jq -c --arg label "$label" '.result.layout as $l | {id: "cli:tab:create", result: {type: "tab_created",
      tab: {tab_id: $l.tab_id, workspace_id: $l.workspace_id, label: $label},
      root_pane: {pane_id: $l.root.pane_id, tab_id: $l.tab_id, workspace_id: $l.workspace_id}}}' <<< "$layout"
    return $?
  fi

  out=$(MSYS2_ARG_CONV_EXCL='*' "$_FM_WIN_HERDR_BIN" "$@") || { printf '%s\n' "$out"; return 1; }
  if ! layout=$(_fm_win_herdr_api layout.apply "$(jq -c --argjson root "$root" \
    '{tab_id: .result.tab.tab_id, focus: false, root: $root}' <<< "$out")" "${session[@]}"); then
    MSYS2_ARG_CONV_EXCL='*' "$_FM_WIN_HERDR_BIN" workspace close "$(jq -r .result.workspace.workspace_id <<< "$out")" \
      "${session[@]}" >/dev/null 2>&1
    return 1
  fi
  jq -c --argjson l "$(jq -c .result.layout <<< "$layout")" '.result.tab.tab_id = $l.tab_id
    | .result.workspace.active_tab_id = $l.tab_id
    | .result.root_pane = {pane_id: $l.root.pane_id, tab_id: $l.tab_id, workspace_id: $l.workspace_id}' <<< "$out"
}

# One request on herdr's socket, for a method its CLI does not offer. Status
# takes the create's own session arguments, so it names the socket the CLI
# picked for the create, HERDR_SOCKET_PATH included.
_fm_win_herdr_api() {  # <method> <params-json> [session-args...]
  local socket
  socket=$(MSYS2_ARG_CONV_EXCL='*' "$_FM_WIN_HERDR_BIN" status --json "${@:3}" | jq -r '.server.socket // empty')
  [ -n "$socket" ] || { echo "error: herdr status ${*:3} reported no socket" >&2; return 1; }
  MSYS2_ARG_CONV_EXCL='*' node "$(cygpath -w -- "${FM_PLATFORM_OVERLAY%/*}/herdr-api.mjs")" "$socket" "$1" "$2"
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
    return $?
  fi
  fm_backend_herdr_target_ready "$1" || return 0
  path=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane get "$FM_BACKEND_HERDR_PANE" 2>/dev/null \
    | jq -r '.result.pane.foreground_cwd // .result.pane.cwd // empty' 2>/dev/null)
  case $path in [A-Za-z]:[\\/]*) path=$(cygpath -u -- "$path") ;; esac
  [ -z "$path" ] || printf '%s\n' "$path"
}
