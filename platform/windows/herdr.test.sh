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
T=$(mktemp -d /tmp/fm-win-herdr.XXXXXX)
fails=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
expect_eq() {  # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 (expected: $2, got: $3)"; fi
}

cleanup() {
  herdr server stop --session "$S" >/dev/null 2>&1
  herdr session delete "$S" >/dev/null 2>&1
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

ws=$(fm_backend_herdr_cli "$S" workspace create --cwd "$T" --label o3t --no-focus | jq -r '.result.workspace.workspace_id // empty')
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

[ "$fails" -eq 0 ]
