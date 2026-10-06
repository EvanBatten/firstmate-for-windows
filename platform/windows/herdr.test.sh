#!/usr/bin/env bash
# Herdr panes under the overlay, against the real herdr: its drive-spelled
# socket path, a task pane that runs Git Bash with the overlay's environment,
# the pane's cwd after a `cd`, a bare /exit typed without MSYS rewriting it,
# and a task kill. Starts its own throwaway herdr session and removes it.
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1
# shellcheck source=platform/windows/env.sh
. platform/windows/env.sh
# shellcheck source=bin/backends/herdr.sh
. bin/backends/herdr.sh

S=o3t-$(printf '%04x' "$RANDOM")
S2=$S-other
T=$(mktemp -d /tmp/fm-win-herdr.XXXXXX)
fails=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
expect_eq() {  # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 (expected: $2, got: $3)"; fi
}

cleanup() {
  local s
  for s in "$S" "$S2"; do
    herdr server stop --session "$s" >/dev/null 2>&1
    herdr session delete "$s" >/dev/null 2>&1
  done
  rm -rf "$T"
}
trap cleanup EXIT

wait_capture() {  # <target> <substring> -> the last capture
  local i out
  for ((i = 0; i < 100; i++)); do
    out=$(fm_backend_herdr_capture "$1" 60 2>/dev/null)
    case $out in *"$2"*) break ;; esac
    sleep 0.2
  done
  printf '%s' "$out"
}

fm_backend_herdr_server_ensure "$S" || { not_ok "herdr server $S starts"; exit 1; }

sock=$(herdr session list --json | jq -r --arg s "$S" '.sessions[] | select(.name == $s) | .socket_path')
canon=$(fm_backend_herdr_canonical_socket_path "$sock")
case $canon in
  /c/*) ok "the drive-spelled socket path canonicalizes to /c/..." ;;
  *) not_ok "the drive-spelled socket path canonicalizes to /c/... (from $sock, got: $canon)" ;;
esac
expect_eq "the session's socket path is that canonical path" "${canon:-a canonical path}" "$(fm_backend_herdr_presentation_session_socket_path "$S")"

if lock=$(fm_backend_herdr_presentation_session_lock_path "$S"); then
  expect_eq "the presentation lock directory reads private and owned" "700 $(id -u)" "$(stat -c '%a %u' "${lock%/*}")"
else
  not_ok "the presentation lock path resolves"
fi

wsout=$(fm_backend_herdr_cli "$S" workspace create --cwd "$T" --label o3t --no-focus)
ws=$(jq -r '.result.workspace.workspace_id // empty' <<< "$wsout")
expect_eq "a workspace create answers with its laid-out tab as the workspace's root tab and active tab" "o3t true" \
  "$(jq -r '.result | "\(.workspace.label) \(.root_pane.tab_id == .tab.tab_id and .workspace.active_tab_id == .tab.tab_id
    and .root_pane.workspace_id == .workspace.workspace_id and (.root_pane.pane_id | type) == "string")"' <<< "$wsout")"
tabout=$(fm_backend_herdr_cli "$S" tab create --workspace "$ws" --cwd "$T" --label o3t-shape --no-focus)
expect_eq "a tab create answers as the CLI would, naming its tab and root pane" "cli:tab:create tab_created o3t-shape true" \
  "$(jq -r --arg ws "$ws" '"\(.id) \(.result.type) \(.result.tab.label) \(.result.tab.workspace_id == $ws
    and .result.root_pane.tab_id == .result.tab.tab_id and .result.root_pane.workspace_id == $ws
    and (.result.root_pane.pane_id | type) == "string")"' <<< "$tabout")"
fm_backend_herdr_cli "$S" tab close "$(jq -r .result.tab.tab_id <<< "$tabout")" >/dev/null
created=$(fm_backend_herdr_create_task "$S:$ws" fm-o3t "$T" "")
pane=${created#* }
target=$S:$pane

# shellcheck disable=SC2016 # Expanded by the pane's bash.
fm_backend_herdr_send_text_line "$target" 'echo "o3probe $BASH $(umask) ${PATH%%:*} conv=${MSYS2_ARG_CONV_EXCL-on}"'
want="o3probe /usr/bin/bash 0077 $ROOT/platform/windows/bin conv=on"
case $(wait_capture "$target" "$want") in
  *"$want"*) ok "a task pane runs Git Bash with the overlay's umask and PATH and MSYS argument conversion on" ;;
  *) not_ok "a task pane runs Git Bash with the overlay's umask and PATH and MSYS argument conversion on (want: $want, pane: $(fm_backend_herdr_capture "$target" 5 | tr '\n' '|'))" ;;
esac

mkdir -p "$T/cwd probe"
want=$(cd "$T/cwd probe" && pwd -P)
fm_backend_herdr_send_text_line "$target" "cd $(printf '%q' "$T/cwd probe")"
for ((i = 0; i < 50; i++)); do
  got=$(fm_backend_herdr_current_path "$target")
  [ -n "$got" ] && got=$(cd "$got" 2>/dev/null && pwd -P)
  [ "$got" = "$want" ] && break
  sleep 0.2
done
expect_eq "the pane's current path follows a cd" "$want" "$got"

fm_backend_herdr_send_literal "$target" /exit
for ((i = 0; i < 50; i++)); do
  last=$(fm_backend_herdr_capture "$target" 60 | awk 'NF { line = $0 } END { print line }')
  case $last in *exit) break ;; esac
  sleep 0.2
done
case $last in
  *'C:/Program Files'*) not_ok "a bare /exit reaches the pane as typed (got: $last)" ;;
  *'$ /exit' | *' /exit') ok "a bare /exit reaches the pane as typed" ;;
  *) not_ok "a bare /exit reaches the pane as typed (got: $last)" ;;
esac
fm_backend_herdr_send_key "$target" C-u

fm_backend_herdr_kill "$target"
expect_eq "a task kill removes the pane" dead "$(fm_backend_herdr_pane_presence_state "$S" "$pane")"

if broken=$(BASH=/c/fm-win-no-such-dir/bash.exe; fm_backend_herdr_cli "$S" tab create --workspace "$ws" --cwd "$T" --label broken --no-focus 2>&1); then
  not_ok "a tab whose Git Bash cannot start fails its create (got: $broken)"
else
  ok "a tab whose Git Bash cannot start fails its create"
fi

ws2=$(fm_backend_herdr_cli "$S" workspace create --cwd "$T" --label o3t-2 --no-focus | jq -r '.result.workspace.workspace_id // empty')
fm_backend_herdr_cli "$S" workspace close "$ws2" >/dev/null
expect_eq "a closed workspace leaves nothing of its panes under TMPDIR" "" \
  "$(find "${TMPDIR:-/tmp}/fm-win-herdr-panes/$S" -type f 2>/dev/null)"

labels() {  # <session> <workspace|tab> <prefix>
  herdr "$2" list --session "$1" | jq -r --arg p "$3" '[.result[] | arrays | .[].label | select(startswith($p))] | join(" ")'
}
snapshot() {  # <session>
  herdr workspace list --session "$1" | jq -c '[.result.workspaces[] | [.workspace_id, .label, .active_tab_id]]'
  herdr tab list --session "$1" | jq -c '[.result.tabs[] | [.tab_id, .label, .pane_count]]'
}

fm_backend_herdr_server_ensure "$S2" || { not_ok "herdr server $S2 starts"; exit 1; }
for v in 1 2 3 4 5; do herdr workspace create --cwd "$T" --label "victim$v" --no-focus --session "$S2" >/dev/null; done
before=$(snapshot "$S2")
wsx=$(fm_backend_herdr_cli "$S" workspace create --cwd "$T" --label xs-home --no-focus | jq -r '.result.workspace.workspace_id // empty')
{
  HERDR_SOCKET_PATH=$sock HERDR_SESSION=$S2 herdr tab create --workspace "$wsx" --cwd "$T" --label xs-env --no-focus
  HERDR_SOCKET_PATH=$sock HERDR_SESSION=$S2 herdr workspace create --cwd "$T" --label xs-env-ws --no-focus
  HERDR_SESSION=$S2 herdr tab create --session="$S" --workspace "$wsx" --cwd "$T" --label xs-eq --no-focus
  HERDR_SESSION=$S2 herdr workspace create --session="$S" --cwd "$T" --label xs-eq-ws --no-focus
  HERDR_SESSION=$S2 BASH=/c/fm-win-no-such-dir/bash.exe herdr workspace create --session="$S" --cwd "$T" --label xs-broken --no-focus
} >/dev/null 2>&1
expect_eq "a tab create lays out its tab in the session the CLI picks, from HERDR_SOCKET_PATH or --session=" \
  "xs-env xs-eq" "$(labels "$S" tab xs-)"
expect_eq "a workspace create lays out in the CLI's session, and a failed layout closes the workspace there" \
  "xs-home xs-env-ws xs-eq-ws" "$(labels "$S" workspace xs-)"
expect_eq "a create aimed at one session leaves another session's workspaces and tabs as they were" \
  "$before" "$(snapshot "$S2")"

mkdir -p "$T/norc/platform/windows"
cp platform/windows/herdr-api.mjs "$T/norc/platform/windows/"
for create in "tab create --workspace $wsx" "workspace create"; do
  # shellcheck disable=SC2086 # Splits into the create's own words.
  if out=$(FM_PLATFORM_OVERLAY=$T/norc/platform/windows/overrides.sh \
    herdr $create --cwd "$T" --label "norc-${create%% *}" --no-focus --session "$S" 2>&1); then
    not_ok "a ${create%% *} create with no pane-rc.sh to run fails (got: $out)"
  else
    ok "a ${create%% *} create with no pane-rc.sh to run fails"
  fi
done
expect_eq "a create with no pane-rc.sh leaves no tab or workspace behind" "|" "$(labels "$S" tab norc)|$(labels "$S" workspace norc)"

[ "$fails" -eq 0 ]
