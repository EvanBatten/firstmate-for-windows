#!/usr/bin/env bash
# Fleet-lock safety on Git Bash with real processes: a home reached through two
# spellings, a second session, re-entry, and a killed holder. Each session is
# a Git Bash under its own native harness, a copy of cmd.exe named claude.exe.
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1
# shellcheck source=platform/windows/env.sh
. platform/windows/env.sh
unset CLAUDE_CODE_SESSION_ID CLAUDE_PID

T=$(mktemp -d /tmp/fm-win-lock.XXXXXX)
BASH_EXE=$(cygpath -w /usr/bin/bash)
fails=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
expect() {  # <description> <expected-substring> <actual>
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
cd $(printf '%q' "$ROOT") && . platform/windows/env.sh
unset CLAUDE_CODE_SESSION_ID CLAUDE_PID
export FM_HOME=\$2
while :; do
  for go in $(printf '%q' "$T")/marks/\$1.go.*; do
    [ -e "\$go" ] || continue
    rm -f "\$go"
    bin/fm-lock.sh > "\${go/.go./.out.}" 2>&1
    echo "rc=\$?" >> "\${go/.go./.out.}"
  done
  sleep 0.2
done
EOF

start_session() {  # <name> <home>
  local i pid
  mkdir -p "$T/$1"
  cp /c/Windows/System32/cmd.exe "$T/$1/claude.exe"
  MSYS2_ARG_CONV_EXCL='*' "$T/$1/claude.exe" /c "$BASH_EXE" "$(cygpath -m "$T/session.sh")" "$1" "$2" > /dev/null 2>&1 &
  for ((i = 0; i < 50; i++)); do
    pid=$(/usr/bin/ps -W | awk -v p="$1/claude" 'index($0, p) {print $4; exit}')
    [ -n "$pid" ] && break
    sleep 0.2
  done
  HARNESS_PIDS+=("$pid")
  SESSION_PID=$pid
}
run_lock() {  # <name> <step>
  local i
  : > "$T/marks/$1.go.$2"
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

start_session s1 "$H"; p1=$SESSION_PID
start_session s2 "$H"; p2=$SESSION_PID

expect "the first session takes the lock" "lock acquired: harness pid $p1" "$(run_lock s1 1)"
expect "status names the first session" "held by live harness pid $p1" "$(lock_status "$H")"
expect "a second session in the same home is refused" "another live firstmate session holds the lock (pid $p1)" "$(run_lock s2 1)"
expect "the same session re-enters" "lock acquired: harness pid $p1" "$(run_lock s1 2)"
taskkill //F //T //PID "$p1" >/dev/null 2>&1
expect "status reports a killed holder as stale" "lock: stale (pid $p1" "$(lock_status "$H")"
expect "a second session takes over from a killed holder" "lock acquired: harness pid $p2" "$(run_lock s2 2)"
expect "status names the new holder" "held by live harness pid $p2" "$(lock_status "$H")"

[ "$fails" -eq 0 ]
