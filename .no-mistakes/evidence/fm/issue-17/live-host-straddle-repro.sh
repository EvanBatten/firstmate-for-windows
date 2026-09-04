#!/usr/bin/env bash
# Live reproduction of issue #17 on this host's real /proc (no fixtures, no overrides):
# a process whose creation instant lands near a whole-second boundary, read repeatedly
# by the base commit's library and by HEAD's library, with every HEAD read checked
# against the first ("recorded") read through fm_pid_identity_equal.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NEW="$ROOT/bin/fm-wake-lib.sh"
BASE="$ROOT/tests/scratchpad-base-bin/fm-wake-lib.sh"
read_with() { bash -c '. "$1"; fm_pid_identity "$2"' _ "$1" "$2"; }
equal_with_new() { bash -c '. "$1"; fm_pid_identity_equal "$2" "$3"' _ "$NEW" "$1" "$2"; }
ms_of() { local v=${1#proc-createtime-ms=}; printf '%s\n' "${v%% *}"; }

printf 'host: %s, bash %s, CLK_TCK %s, EPOCHREALTIME present: %s\n' "$(uname -s)" "${BASH_VERSION}" "$(getconf CLK_TCK)" "$([ -n "${EPOCHREALTIME:-}" ] && echo yes || echo no)"
printf 'uptime file: %s\n' "$(cat /proc/uptime)"

# Spawn until a process is born within 8 ms of a whole second (real scheduler, no override).
attempt=0
while :; do
  attempt=$((attempt + 1))
  sleep 300 &
  pid=$!
  id=$(read_with "$NEW" "$pid") || { kill "$pid"; wait "$pid" 2>/dev/null; continue; }
  ms=$(ms_of "$id")
  off=$(( ms % 1000 ))
  if [ "$off" -ge 992 ] || [ "$off" -le 8 ]; then
    printf 'attempt %d: pid %d born at epoch-ms %d (%d ms into its second) - near a boundary, keeping it\n' "$attempt" "$pid" "$ms" "$off"
    break
  fi
  kill "$pid"; wait "$pid" 2>/dev/null
  if [ "$attempt" -ge 120 ]; then printf 'could not land a process near a boundary in %d attempts\n' "$attempt"; exit 2; fi
done

printf '\n--- base commit (9b1deac) library: 24 reads of pid %d ---\n' "$pid"
declare -A base_seen=()
for i in $(seq 1 24); do
  v=$(read_with "$BASE" "$pid") || v='(unreadable)'
  key=${v%% *}
  base_seen[$key]=$(( ${base_seen[$key]:-0} + 1 ))
done
for k in "${!base_seen[@]}"; do printf '  %-32s x%d\n' "$k" "${base_seen[$k]}"; done
printf 'distinct identities from the base library for ONE live process: %d\n' "${#base_seen[@]}"

printf '\n--- HEAD library: 24 reads of pid %d, each compared with the first through fm_pid_identity_equal ---\n' "$pid"
recorded=$(read_with "$NEW" "$pid")
rec_ms=$(ms_of "$recorded")
printf '  recorded: %s\n' "${recorded%% *}"
min=$rec_ms; max=$rec_ms; mismatches=0
declare -A new_seen=()
for i in $(seq 1 24); do
  v=$(read_with "$NEW" "$pid") || { printf '  read %d unreadable\n' "$i"; mismatches=$((mismatches+1)); continue; }
  m=$(ms_of "$v")
  new_seen[${v%% *}]=$(( ${new_seen[${v%% *}]:-0} + 1 ))
  [ "$m" -lt "$min" ] && min=$m
  [ "$m" -gt "$max" ] && max=$m
  if equal_with_new "$v" "$recorded"; then verdict=equal; else verdict=MISMATCH; mismatches=$((mismatches+1)); fi
  printf '  read %2d: %-32s delta %+4d ms -> %s\n' "$i" "${v%% *}" "$(( m - rec_ms ))" "$verdict"
done
printf 'distinct raw strings from the HEAD library: %d, spread across all reads: %d ms (bound for two readers: about 32 ms)\n' "${#new_seen[@]}" "$(( max - min ))"
printf 'comparator mismatches for the same live process: %d of 24\n' "$mismatches"

# The comparator must still refuse a genuinely different process: a fresh sleep.
sleep 300 &
other=$!
other_id=$(read_with "$NEW" "$other")
if equal_with_new "$other_id" "$recorded"; then printf 'ERROR: a different process compared equal\n'; else printf 'a different live process (pid %d, %s) is still rejected against the record\n' "$other" "${other_id%% *}"; fi
kill "$other" "$pid" 2>/dev/null; wait "$other" "$pid" 2>/dev/null
[ "$mismatches" -eq 0 ] && [ "${#base_seen[@]}" -ge 2 ]
