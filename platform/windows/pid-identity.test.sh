#!/usr/bin/env bash
# shellcheck disable=SC2016
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1
# shellcheck source=platform/windows/env.sh
. platform/windows/env.sh
# shellcheck source=tests/lib.sh
. tests/lib.sh

T=$(fm_test_tmproot fm-win-pid-identity)
LIB=$ROOT/bin/fm-wake-lib.sh
WATCH=$ROOT/bin/fm-watch.sh
home=$T/home state=$T/home/state proc=$T/proc
mkdir -p "$state/.watch.lock" "$proc"

# One process the way MSYS shows it: stat counts the start from Windows' boot
# time, the directory carries the second the pid was made, and winpid names the
# Windows process behind it.
fake_msys_process() {  # <pid> <start-since-boot-ms> <made-at-epoch> <winpid>
  local dir=$proc/$1
  mkdir -p "$dir"
  printf '%s (bash) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 %s 20 21 22\n' "$1" "$2" > "$dir/stat"
  printf 'bash\0%s\0' "$WATCH" > "$dir/cmdline"
  printf '%s\n' "$4" > "$dir/winpid"
  touch -d "@$3" "$dir"
}
in_lib() {  # <proc-root> <script> [args...]
  FM_PROC_ROOT_OVERRIDE=$1 FM_HOME=$home FM_STATE_OVERRIDE=$state bash -c '. "$1"; shift; eval "$1"' _ "$LIB" "${@:2}"
}
identity() { in_lib "$proc" 'fm_pid_identity "$2"' "$1"; }
lock_matches() { in_lib "$proc" 'fm_watcher_lock_matches_pid "$STATE" "$2" "$3" "$FM_HOME"' "$WATCH" "$1"; }
watcher_healthy() { in_lib "$proc" 'fm_watcher_healthy "$STATE" "$2" 300 "$FM_HOME"' "$WATCH"; }

sleep 300 &
watcher=$!

# The watcher takes its lock, the way bin/fm-watch.sh records itself.
fake_msys_process "$watcher" 976306 1794000000 4242
printf '%s\n' "$watcher" > "$state/.watch.lock/pid"
printf '%s\n' "$home" > "$state/.watch.lock/fm-home"
printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
recorded=$(identity "$watcher") || fail "could not read the watcher's identity"
printf '%s\n' "$recorded" > "$state/.watch.lock/pid-identity"
touch "$state/.last-watcher-beat"
lock_matches "$watcher" || fail "a watcher did not match the lock it had just taken"

# Windows corrects its clock by 1.5 s: the boot time moves, and with it the
# start time MSYS reports for the same process.
fake_msys_process "$watcher" 977806 1794000000 4242
lock_matches "$watcher" \
  || fail "a live watcher stopped matching its lock when its reported start time drifted (recorded '$recorded', now '$(identity "$watcher")')"
watcher_healthy || fail "a live, beating watcher read as down after its reported start time drifted"
pass "a live watcher keeps its lock when Windows moves the start time it reports"

fake_msys_process "$watcher" 977806 1794000090 5150
! lock_matches "$watcher" || fail "a different process on the watcher's pid matched the watcher's lock"
! watcher_healthy || fail "a different process on the watcher's pid read as the healthy watcher"
pass "a different process that reuses the watcher's pid does not match its lock"

fake_msys_process "$watcher" 976306 1794000000 5150
! lock_matches "$watcher" || fail "a different process made in the same second matched the watcher's lock"
pass "nor does one made in the same second with the same command line"

# A proc tree that is not MSYS's has no winpid, and keeps upstream's identity.
mkdir -p "$T/plain/4242"
cp "$proc/$watcher/stat" "$proc/$watcher/cmdline" "$T/plain/4242/"
want=$(FM_PLATFORM_OVERLAY='' in_lib "$T/plain" 'fm_pid_identity 4242') || fail "upstream read no identity from a plain proc tree"
got=$(in_lib "$T/plain" 'fm_pid_identity 4242') || fail "the overlay read no identity from a plain proc tree"
[ "$got" = "$want" ] || fail "the overlay changed the identity of a plain proc tree (want '$want', got '$got')"
pass "a proc tree without winpid keeps upstream's identity"

# The real /proc: one process reads the same from two shells, and two
# processes with one command line read apart.
sleep 300 &
twin=$!
first=$(in_lib /proc 'fm_pid_identity "$2"' "$watcher") || fail "could not identify a live process"
again=$(in_lib /proc 'fm_pid_identity "$2"' "$watcher") || fail "could not identify a live process a second time"
other=$(in_lib /proc 'fm_pid_identity "$2"' "$twin") || fail "could not identify a second live process"
[ -n "$first" ] && [ "$again" = "$first" ] || fail "one live process read as two identities ('$first', '$again')"
[ "$other" != "$first" ] || fail "two live processes with one command line shared an identity ('$first')"
pass "a real process has one identity, and its twin another"

kill "$twin" 2>/dev/null
wait "$twin" 2>/dev/null
! in_lib /proc 'fm_pid_identity "$2"' "$twin" >/dev/null 2>&1 || fail "an exited process still had an identity"
pass "an exited process has no identity"
