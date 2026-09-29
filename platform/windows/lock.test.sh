#!/usr/bin/env bash
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1
# shellcheck source=platform/windows/env.sh
. platform/windows/env.sh
unset CLAUDE_CODE_SESSION_ID CLAUDE_PID

T=$(mktemp -d /tmp/fm-win-lock.XXXXXX)
BASH_EXE=$(cygpath -w /usr/bin/bash)
GIT_BASH_LAUNCHER="$(cygpath -w /)\bin\bash.exe"
fails=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
expect() {
  case $3 in *"$2"*) ok "$1" ;; *) not_ok "$1 (got: $3)" ;; esac
}
lock_status() { FM_HOME=$1 bin/fm-lock.sh status 2>&1; }

cleanup() {
  local pid
  for pid in "${HARNESS_PIDS[@]}"; do taskkill //F //T //PID "$pid" >/dev/null 2>&1; done
  rm -rf "$T"
}
HARNESS_PIDS=()
trap cleanup EXIT

H=$T/home
mkdir -p "$H/state" "$T/marks"
cat > "$T/session.sh" <<EOF
#!/usr/bin/env bash
cd $(printf '%q' "$ROOT") || exit 1
[ "\$3" = hook ] || . platform/windows/env.sh
unset CLAUDE_CODE_SESSION_ID CLAUDE_PID
export FM_HOME=\$2
while :; do
  for go in $(printf '%q' "$T")/marks/\$1.go.*; do
    [ -e "\$go" ] || continue
    cmd=\$(cat "\$go"); rm -f "\$go"
    eval "\${cmd:-bin/fm-lock.sh}" > "\${go/.go./.out.}" 2>&1
    echo "rc=\$?" >> "\${go/.go./.out.}"
  done
  sleep 0.2
done
EOF
chmod +x "$T/session.sh"
cat > "$T/hook.sh" <<EOF
[ -z "\${GROK_AGENT:-}" ] || exit 0; exec $(printf '%q' "$T/session.sh") "\$@"
EOF

start_session() {
  local i pid winpid bash_exe=$BASH_EXE
  mkdir -p "$T/$1"
  local script=$T/session.sh
  [ "${3:-}" != hook ] || bash_exe=$GIT_BASH_LAUNCHER script=$T/hook.sh
  cp /c/Windows/System32/cmd.exe "$T/$1/claude.exe"
  MSYS2_ARG_CONV_EXCL='*' "$T/$1/claude.exe" /c "$bash_exe" "$(cygpath -m "$script")" "$1" "$2" ${3:+"$3"} > /dev/null 2>&1 &
  for ((i = 0; i < 50; i++)); do
    read -r pid winpid < <(/usr/bin/ps -W | awk -v p="$1/claude" 'index($0, p) {print $1, $4; exit}')
    [ -n "$pid" ] && break
    sleep 0.2
  done
  HARNESS_PIDS+=("$winpid")
  SESSION_PID=$pid SESSION_WINPID=$winpid
}
run_lock() {
  local i
  printf '%s' "${3:-}" > "$T/marks/$1.go.$2"
  for ((i = 0; i < 600; i++)); do
    grep -q '^rc=' "$T/marks/$1.out.$2" 2>/dev/null && break
    sleep 0.1
  done
  cat "$T/marks/$1.out.$2"
}

# /tmp maps the user's Temp directory, so a home under it also has a drive
# spelling, and the lock must not spin when a caller uses that one.
spelled=$(cd "$T" && pwd -W)
spelled=$(cygpath -u -- "${spelled%%:*}:/")${spelled#?:/}/spelled
mkdir -p "$spelled/state"
start_session s0 "$spelled"; p0=$SESSION_PID
expect "a home spelled through the drive takes the lock" "lock acquired: harness pid $p0" "$(run_lock s0 1)"
expect "status agrees for that holder" "held by live harness pid $p0" "$(lock_status "$spelled")"

# Claude runs a hook through Git's bin/bash.exe, which puts /usr/bin ahead of
# the overlay's bin, and the hook inherits the overlay only through the
# environment claude.exe was started with. The hook command execs a script,
# and that exec leaves the script with no live Win32 parent, so only
# CLAUDE_PID still names the session.
mkdir -p "$T/hook/state" "$T/hook-noenv/state"
start_session s9 "$T/hook" hook; p9=$SESSION_PID w9=$SESSION_WINPID
expect "a hook-shaped session takes the lock" "lock acquired: harness pid $p9" "$(run_lock s9 1 "CLAUDE_PID=$w9 bin/fm-lock.sh")"
start_session s8 "$T/hook-noenv" hook
expect "a hook-shaped session without CLAUDE_PID does not" "cannot locate harness process in ancestry" "$(run_lock s8 1)"
expect "a hook-shaped session whose CLAUDE_PID is no Claude does not" "cannot locate harness process in ancestry" "$(run_lock s8 2 "CLAUDE_PID=$(cat /proc/$$/winpid) bin/fm-lock.sh")"
mkdir -p "$T/direct/state"
out=$(CLAUDE_PID=$w9 FM_HOME=$T/direct bin/fm-lock.sh 2>&1)
case $out in
  *"harness pid $p9"*) not_ok "a shell whose walk did not break ignores another session's CLAUDE_PID (got: $out)" ;;
  *) ok "a shell whose walk did not break ignores another session's CLAUDE_PID" ;;
esac

start_session s1 "$H"; p1=$SESSION_PID w1=$SESSION_WINPID
start_session s2 "$H"; p2=$SESSION_PID

expect "the first session takes the lock" "lock acquired: harness pid $p1" "$(run_lock s1 1)"
expect "status names the first session" "held by live harness pid $p1" "$(lock_status "$H")"
expect "a second session in the same home is refused" "another live firstmate session holds the lock (pid $p1)" "$(run_lock s2 1)"
expect "the same session re-enters" "lock acquired: harness pid $p1" "$(run_lock s1 2)"
taskkill //F //T //PID "$w1" >/dev/null 2>&1
expect "status reports a killed holder as stale" "lock: stale (pid $p1" "$(lock_status "$H")"
expect "a second session takes over from a killed holder" "lock acquired: harness pid $p2" "$(run_lock s2 2)"
expect "status names the new holder" "held by live harness pid $p2" "$(lock_status "$H")"

expect "the holder claims a task lease" "rc=0" "$(run_lock s2 3 'FM_SUPERVISION_ACTOR=main bin/fm-lease.sh claim t1')"
expect "the lease reads live while its holder lives" "main $p2 " "$(run_lock s2 4 'bin/fm-lease.sh check t1')"
expect "the lease reads live, not stale" " live" "$(run_lock s2 5 'bin/fm-lease.sh check t1')"
expect "another actor cannot claim a live lease" "rc=6" "$(run_lock s2 6 'FM_SUPERVISION_ACTOR=branch bin/fm-lease.sh claim t1 --actor branch')"

[ "$fails" -eq 0 ]
