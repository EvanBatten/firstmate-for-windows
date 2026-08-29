#!/usr/bin/env bash
# tests/fm-proc-lib.test.sh - unit tests for bin/fm-proc-lib.sh, the one owner
# of "what process is this, and is it alive".
#
# The library has two branches and BOTH are covered from any host, because
# neither is allowed to regress unseen: the POSIX branch has to keep running
# literally the `ps -o ...` and `kill -0` calls its callers ran before it
# existed, and the MSYS branch only ever executes on a machine that upstream CI
# does not have. So the platform is faked the way tests/fm-backend-herdr.test.sh
# fakes the herdr CLI - a `uname` that says MINGW64, a `ps` that behaves like
# MSYS ps (rejects -o, prints a -W table), a `pwsh` replaying a canned Win32
# ancestry, and a fake /proc tree through FM_PROC_MSYS_PROC_ROOT.
#
# The library picks its branch by CAPABILITY: it asks `uname` first and then,
# only if that said Windows, probes whether `ps` accepts -o. So the MSYS cases
# need both fakes, and the POSIX cases need neither.
#
# Every fake logs its invocation, because the cost model is part of the
# contract: one pwsh process per ancestry walk, and none at all on POSIX.
# shellcheck disable=SC2016  # single quotes are deliberate throughout: every lib_eval argument is source text for a CHILD bash, whose $FM_PROC_OS/$pid/$comm must expand there and not here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-proc-lib)
LIB="$ROOT/bin/fm-proc-lib.sh"

# --- fixtures ---------------------------------------------------------------

# A `ps` that answers -o queries from a canned process table, and logs every
# invocation to $FM_PS_LOG. This is a POSIX ps: it accepts -o, so the library's
# capability probe keeps the POSIX branch even under a MINGW `uname`.
make_posix_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'ps'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "${FM_PS_LOG:-/dev/null}"
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
# 999 is the vanished pid; every other pid is an ordinary shell, so the
# library's own capability probe (`ps -o comm= -p $$`) is answered too.
case "$pid:$field" in
  999:*) exit 1 ;;
  700:comm=) printf '%s\n' /opt/claude/bin/claude ;;
  700:args=) printf '%s\n' '/opt/claude/bin/claude --resume' ;;
  700:ppid=) printf '%s\n' '    1' ;;
  600:comm=) printf '%s\n' bash ;;
  600:args=) printf '%s\n' 'bash /repo/bin/fm-harness.sh' ;;
  600:ppid=) printf '%s\n' '  700 ' ;;
  600:pgid=) printf '%s\n' ' 600  ' ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 1 ;;
  *:pgid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$1/ps"
}

# A `ps` that behaves like MSYS ps: -o is rejected outright, and -W prints the
# Cygwin table whose fourth column is the WINPID.
make_msys_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'ps'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "${FM_PS_LOG:-/dev/null}"
for a in "$@"; do
  case "$a" in
    -o) echo "ps: unknown option -- o" >&2; exit 1 ;;
  esac
done
case "${1:-}" in
  -W)
    printf '%s\n' '      PID    PPID    PGID     WINPID  TTY   UID    STIME COMMAND'
    printf '%s\n' '      600     601     600      90600  ?  197609 03:02:31 /usr/bin/bash'
    printf '%s\n' '   273976       0       0      90777  ?       0 03:02:31 C:\Users\u\claude.exe'
    ;;
esac
SH
  chmod +x "$1/ps"
}

make_mingw_uname() {  # <fakebin>
  cat > "$1/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' MINGW64_NT-10.0-26200
SH
  chmod +x "$1/uname"
}

# A `pwsh` standing in for the real Get-Process/.Parent walk: it replays the
# canned Win32 ancestry rooted at $FM_PROC_QUERY_PID, one row per hop, in the
# shape the real one prints - RAW Windows paths with backslashes and .exe, and
# CRLF line endings - so the library's own normalization is what gets tested.
# Every call appends its root pid to $FM_PWSH_LOG, which is how the "one pwsh
# process per walk" cost contract is asserted.
make_fake_pwsh() {  # <fakebin>
  cat > "$1/pwsh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "${FM_PROC_QUERY_PID:-}" >> "${FM_PWSH_LOG:-/dev/null}"
emit() { printf '%s\t%s\t%s\r\n' "$1" "$2" "$3"; }
case "${FM_PROC_QUERY_PID:-}" in
  90601)
    emit 90601 90777 'C:\Program Files\Git\bin\bash.exe'
    emit 90777 90888 'C:\Users\u\.local\bin\claude.exe'
    emit 90888 0 'C:\Program Files\nodejs\node.exe'
    ;;
  90777)
    emit 90777 90888 'C:\Users\u\.local\bin\claude.exe'
    emit 90888 0 'C:\Program Files\nodejs\node.exe'
    ;;
  90999)
    emit 90999 0 'C:\tools\pi.EXE'
    ;;
esac
SH
  chmod +x "$1/pwsh"
}

# A fake MSYS /proc: two Git Bash processes, the outer one reporting PPID 1
# because its real parent is a native Windows process. Written with NO trailing
# newline, exactly as Cygwin writes these files - the library must read the
# value rather than trust `read`'s exit status.
make_fake_proc() {  # <dir>
  local root=$1
  mkdir -p "$root/600" "$root/601"
  printf '%s' /usr/bin/bash > "$root/600/exename"
  printf '%s' 601 > "$root/600/ppid"
  printf '%s' 90600 > "$root/600/winpid"
  # Deliberately NOT 601, which is this pid's ppid: a mutation reading
  # /proc/<pid>/ppid instead has to be visible in the value.
  printf '%s' 600 > "$root/600/pgid"
  printf 'bash\0/repo/bin/fm-harness.sh\0' > "$root/600/cmdline"
  printf '%s' /usr/bin/bash > "$root/601/exename"
  printf '%s' 1 > "$root/601/ppid"
  printf '%s' 90601 > "$root/601/winpid"
  printf '%s' 601 > "$root/601/pgid"
  printf '/usr/bin/bash\0--login\0' > "$root/601/cmdline"
  # A process whose pgid file exists but holds no number: the VALUE, not the
  # file's presence, has to decide the answer.
  mkdir -p "$root/602"
  printf '%s' 'not-a-pid' > "$root/602/pgid"
}

# Run one library expression with <fakebin> shadowing the tools. `kill` is a
# bash builtin and cannot be shimmed on PATH, so it is overridden as a function
# after the library is sourced, and answers only for the pids in $FM_LIVE_PIDS.
# The ps log is truncated right after the source so that every assertion about
# it means "calls the EXPRESSION made": the library's own capability probe runs
# at source time and only on a Windows host, and would otherwise make the same
# assertion read differently on Linux and on Git Bash.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    : > \"\${FM_PS_LOG:-/dev/null}\"
    kill() {
      local a want=
      for a in \"\$@\"; do case \"\$a\" in -*) ;; *) want=\$a ;; esac; done
      case \" \${FM_LIVE_PIDS:-} \" in *\" \$want \"*) return 0 ;; esac
      return 1
    }
    $expr
  " "$LIB"
}

# --- the POSIX branch: byte-for-byte the calls the callers used to make ------

test_posix_helpers_run_todays_ps_calls() {
  local dir fakebin log got
  dir="$TMP_ROOT/posix-calls"
  fakebin=$(fm_fakebin "$dir")
  make_posix_ps "$fakebin"
  make_fake_pwsh "$fakebin"
  # One log per call: lib_eval truncates it after the source, so each file
  # holds exactly the invocations that one expression made.
  got=$(FM_PS_LOG="$dir/comm.log" lib_eval "$fakebin" 'fm_proc_comm 700')
  [ "$got" = /opt/claude/bin/claude ] || fail "posix fm_proc_comm returned '$got'"
  got=$(FM_PS_LOG="$dir/args.log" lib_eval "$fakebin" 'fm_proc_args 700')
  [ "$got" = '/opt/claude/bin/claude --resume' ] || fail "posix fm_proc_args returned '$got'"
  # ppid comes back padded from real ps on both platforms; the callers compare
  # it numerically, so the whitespace has to be gone.
  got=$(FM_PS_LOG="$dir/ppid.log" lib_eval "$fakebin" 'fm_proc_ppid 600')
  [ "$got" = 700 ] || fail "posix fm_proc_ppid returned '$got', expected the whitespace stripped"

  for log in comm args ppid; do
    [ "$(grep -c . "$dir/$log.log")" = 1 ] \
      || fail "fm_proc_$log must run exactly one ps: $(cat "$dir/$log.log")"
  done
  assert_grep 'ps -o comm= -p 700' "$dir/comm.log" "fm_proc_comm must run today's exact ps invocation"
  assert_grep 'ps -o args= -p 700' "$dir/args.log" "fm_proc_args must run today's exact ps invocation"
  assert_grep 'ps -o ppid= -p 600' "$dir/ppid.log" "fm_proc_ppid must run today's exact ps invocation"
  pass "proc-lib: the POSIX helpers run exactly the ps invocations their callers ran before"
}

test_posix_pgid_runs_todays_ps_call() {
  local dir fakebin got
  dir="$TMP_ROOT/posix-pgid"
  fakebin=$(fm_fakebin "$dir")
  make_posix_ps "$fakebin"
  # bin/fm-procevent.sh and bin/fm-watch.sh compare this against a pid, so a
  # padded answer that keeps its whitespace never equals its own leader.
  got=$(FM_PS_LOG="$dir/pgid.log" lib_eval "$fakebin" 'fm_proc_pgid 600')
  [ "$got" = 600 ] || fail "posix fm_proc_pgid returned '$got', expected the whitespace stripped"
  # Both callers write `pgid=$(fm_proc_pgid ...) || <refuse>`, so a success that
  # reports failure kills every runner start while the value above still reads
  # right.
  FM_PS_LOG="$dir/status.log" lib_eval "$fakebin" 'fm_proc_pgid 600 >/dev/null' \
    || fail "posix fm_proc_pgid must exit 0 when it answers"
  [ "$(grep -c . "$dir/pgid.log")" = 1 ] \
    || fail "fm_proc_pgid must run exactly one ps: $(cat "$dir/pgid.log")"
  assert_grep 'ps -o pgid= -p 600' "$dir/pgid.log" \
    "fm_proc_pgid must run today's exact ps invocation"
  # A pid that is not a pid never reaches ps at all, on either branch.
  : > "$dir/pgid.log"
  FM_PS_LOG="$dir/pgid.log" lib_eval "$fakebin" 'fm_proc_pgid "" >/dev/null' \
    && fail "fm_proc_pgid must refuse an empty pid"
  FM_PS_LOG="$dir/pgid.log" lib_eval "$fakebin" 'fm_proc_pgid abc >/dev/null' \
    && fail "fm_proc_pgid must refuse a non-numeric pid"
  [ ! -s "$dir/pgid.log" ] \
    || fail "a refused pid must run no ps at all: $(cat "$dir/pgid.log")"
  pass "proc-lib: fm_proc_pgid is today's exact ps call and refuses a non-pid without forking"
}

test_posix_comm_propagates_a_dead_pid_as_nonzero() {
  local dir fakebin
  dir="$TMP_ROOT/posix-dead"
  fakebin=$(fm_fakebin "$dir")
  make_posix_ps "$fakebin"
  # The ancestry walks break on this status, so swallowing it would turn a
  # finished walk into a silent 8- or 16-hop spin over a dead pid.
  lib_eval "$fakebin" 'fm_proc_comm 999 >/dev/null' \
    && fail "fm_proc_comm must fail for a pid ps cannot report, so the callers' walk still breaks"
  pass "proc-lib: fm_proc_comm propagates ps's non-zero status for a vanished pid"
}

test_posix_prime_costs_nothing_and_memoises_nothing() {
  local dir fakebin log got
  dir="$TMP_ROOT/posix-prime"
  fakebin=$(fm_fakebin "$dir")
  make_posix_ps "$fakebin"
  make_fake_pwsh "$fakebin"
  log="$dir/ps.log"
  : > "$log"
  got=$(FM_PS_LOG="$log" FM_PWSH_LOG="$dir/pwsh.log" lib_eval "$fakebin" \
    'fm_proc_chain_prime 600; printf "memo=[%s]\n" "$FM_PROC_CHAIN_MEMO"')
  [ "$got" = 'memo=[]' ] || fail "the POSIX prime must be a no-op, got '$got'"
  [ ! -s "$log" ] || fail "the POSIX prime must not fork ps: $(cat "$log")"
  assert_absent "$dir/pwsh.log" "the POSIX branch must never reach for pwsh"
  pass "proc-lib: fm_proc_chain_prime is a free no-op on macOS and Linux"
}

test_posix_chain_walks_and_stops_at_init() {
  local dir fakebin got
  dir="$TMP_ROOT/posix-chain"
  fakebin=$(fm_fakebin "$dir")
  make_posix_ps "$fakebin"
  got=$(lib_eval "$fakebin" 'fm_proc_chain 600' | tr '\t' '|')
  assert_contains "$got" '600|700|bash|bash /repo/bin/fm-harness.sh' "chain row for the inner pid"
  assert_contains "$got" '700|1|/opt/claude/bin/claude|/opt/claude/bin/claude --resume' "chain row for the harness"
  [ "$(printf '%s\n' "$got" | grep -c '|')" = 2 ] \
    || fail "the chain must stop at ppid 1, got: $got"
  pass "proc-lib: fm_proc_chain walks the POSIX table and stops at init"
}

test_posix_liveness_is_kill_zero_alone() {
  local dir fakebin log
  dir="$TMP_ROOT/posix-alive"
  fakebin=$(fm_fakebin "$dir")
  make_posix_ps "$fakebin"
  log="$dir/ps.log"
  : > "$log"
  FM_PS_LOG="$log" FM_LIVE_PIDS=700 lib_eval "$fakebin" 'fm_pid_alive 700' \
    || fail "fm_pid_alive must report a live pid"
  FM_PS_LOG="$log" FM_LIVE_PIDS=700 lib_eval "$fakebin" 'fm_pid_alive 701' \
    && fail "fm_pid_alive must report a dead pid as dead"
  FM_PS_LOG="$log" FM_LIVE_PIDS=700 lib_eval "$fakebin" 'fm_pid_alive nonsense' \
    && fail "fm_pid_alive must refuse a non-numeric pid"
  [ ! -s "$log" ] || fail "POSIX liveness must be kill -0 alone, but ps ran: $(cat "$log")"
  pass "proc-lib: fm_pid_alive is kill -0 and nothing else on macOS and Linux"
}

# --- the MSYS branch --------------------------------------------------------

msys_env() {  # <dir> -> echoes the fakebin for a full MSYS fixture
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  make_mingw_uname "$fakebin"
  make_msys_ps "$fakebin"
  make_fake_pwsh "$fakebin"
  make_fake_proc "$dir/proc"
  printf '%s\n' "$fakebin"
}

test_msys_branch_is_chosen_only_when_ps_cannot_answer() {
  local dir fakebin got
  dir="$TMP_ROOT/msys-select"
  fakebin=$(msys_env "$dir")
  got=$(lib_eval "$fakebin" 'printf "%s\n" "$FM_PROC_OS"')
  [ "$got" = msys ] || fail "a MINGW uname with an MSYS ps must select the msys branch, got '$got'"
  # The same Windows uname with a ps that DOES accept -o must stay on the plain
  # path. Every ps-faking test in tests/ depends on this: without it a Windows
  # host would walk the real process tree and ignore the fixture entirely.
  make_posix_ps "$fakebin"
  got=$(lib_eval "$fakebin" 'printf "%s\n" "$FM_PROC_OS"')
  [ "$got" = posix ] || fail "a ps that accepts -o must win over the platform verdict, got '$got'"
  pass "proc-lib: the branch is chosen by ps capability, not by uname alone"
}

test_msys_chain_stitches_proc_onto_the_win32_walk() {
  local dir fakebin got
  dir="$TMP_ROOT/msys-chain"
  fakebin=$(msys_env "$dir")
  got=$(FM_PROC_MSYS_PROC_ROOT="$dir/proc" lib_eval "$fakebin" 'fm_proc_chain 600' | tr '\t' '|')
  # Segment 1, straight out of /proc: real exename and real cmdline.
  assert_contains "$got" '600|601|/usr/bin/bash|bash /repo/bin/fm-harness.sh' \
    "the inner MSYS row must come from /proc, with its real argument vector"
  # The boundary row keeps /proc's identity but takes its parent from Win32,
  # which is the whole point: /proc only knows how to say "PPID 1" there.
  assert_contains "$got" '601|90777|/usr/bin/bash|/usr/bin/bash --login' \
    "the boundary row must keep /proc's identity and take its parent from the Win32 walk"
  assert_not_contains "$got" '601|1|' "the boundary row must not report PPID 1"
  # Segment 2, from pwsh, normalized into something basename can read.
  assert_contains "$got" '90777|90888|C:/Users/u/.local/bin/claude|' \
    "the Win32 rows must be appended with backslashes and .exe normalized away"
  assert_contains "$got" '90888|0|C:/Program Files/nodejs/node|' \
    "the walk must continue to the top of the Win32 chain"
  # The first Win32 row describes the boundary process again, less precisely;
  # emitting it twice would give the caller's walk a duplicate hop.
  assert_not_contains "$got" '90601|' "the Win32 walk's first row duplicates the boundary and must be dropped"
  pass "proc-lib: the MSYS chain reads /proc for MSYS processes and pwsh for the Win32 ancestors"
}

test_msys_names_survive_the_callers_matchers() {
  local dir fakebin got
  dir="$TMP_ROOT/msys-names"
  fakebin=$(msys_env "$dir")
  # bin/fm-harness.sh matches `basename -- "$comm"`, and bin/fm-session-lock-lib.sh
  # matches FM_HARNESS_RE, which anchors ^pi$. A raw Windows path defeats both:
  # basename of a backslash path is the whole string, and "pi.EXE" is not "pi".
  got=$(FM_PROC_MSYS_PROC_ROOT="$dir/proc" lib_eval "$fakebin" 'fm_proc_comm 90777')
  [ "$(basename -- "$got")" = claude ] \
    || fail "basename of a Win32 comm must be the bare harness name, got '$(basename -- "$got")'"
  got=$(FM_PROC_MSYS_PROC_ROOT="$dir/proc" lib_eval "$fakebin" 'fm_proc_comm 90999')
  [ "$(basename -- "$got")" = pi ] \
    || fail "a .EXE suffix in any case must be dropped so ^pi\$ still matches, got '$(basename -- "$got")'"
  pass "proc-lib: Win32 command names are normalized into what the harness matchers expect"
}

test_msys_walk_costs_exactly_one_pwsh_process() {
  local dir fakebin log calls pid
  dir="$TMP_ROOT/msys-cost"
  fakebin=$(msys_env "$dir")
  log="$dir/pwsh.log"
  : > "$log"
  # A caller's real shape: prime once, then query every hop. A memo that did
  # not survive into the per-hop command substitutions would show up here as
  # one pwsh process per field read.
  FM_PROC_MSYS_PROC_ROOT="$dir/proc" FM_PWSH_LOG="$log" lib_eval "$fakebin" '
    fm_proc_chain_prime 600
    pid=600
    for _ in 1 2 3 4 5 6 7 8; do
      comm=$(fm_proc_comm "$pid") || break
      args=$(fm_proc_args "$pid")
      printf "%s %s %s\n" "$pid" "$comm" "$args"
      pid=$(fm_proc_ppid "$pid")
      [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
    done' > "$dir/walk.out" || fail "the primed MSYS walk failed"
  calls=$(grep -c . "$log" || true)
  [ "$calls" = 1 ] || fail "a primed ancestry walk must start exactly one pwsh process, started $calls"
  pid=$(head -n 1 "$log")
  [ "$pid" = 90601 ] || fail "pwsh must be rooted at the boundary process's WINPID, was rooted at '$pid'"
  assert_grep 'claude' "$dir/walk.out" "the primed walk must reach the harness"
  pass "proc-lib: a primed MSYS ancestry walk costs exactly one pwsh process"
}

test_msys_lookup_without_a_memo_still_answers() {
  local dir fakebin got
  dir="$TMP_ROOT/msys-unprimed"
  fakebin=$(msys_env "$dir")
  # bin/fm-session-lock-lib.sh asks about a pid out of state/.lock with no walk
  # in progress, and on MSYS that pid is a Win32 pid with no /proc entry.
  got=$(FM_PROC_MSYS_PROC_ROOT="$dir/proc" lib_eval "$fakebin" 'fm_proc_comm 90777')
  [ "$got" = 'C:/Users/u/.local/bin/claude' ] || fail "an unprimed Win32 lookup returned '$got'"
  got=$(FM_PROC_MSYS_PROC_ROOT="$dir/proc" lib_eval "$fakebin" 'fm_proc_comm 600')
  [ "$got" = /usr/bin/bash ] || fail "an unprimed MSYS lookup returned '$got'"
  lib_eval "$fakebin" 'FM_PROC_MSYS_PROC_ROOT=/nonexistent fm_proc_comm 12345 >/dev/null' \
    && fail "a pid neither /proc nor pwsh knows must fail, not answer"
  pass "proc-lib: an unprimed lookup answers from /proc or its own Win32 walk"
}

test_msys_prime_rooted_at_a_win32_pid_needs_no_second_walk() {
  local dir fakebin log calls
  dir="$TMP_ROOT/msys-win-prime"
  fakebin=$(msys_env "$dir")
  log="$dir/pwsh.log"
  : > "$log"
  # bin/fm-session-lock-lib.sh's fm_harness_pid_alive primes on a pid out of
  # state/.lock, which on MSYS is a Win32 pid with no /proc row at all: the
  # chain has ZERO MSYS rows and is the pwsh walk alone. Getting that stitch
  # wrong still answers correctly through the per-field fallback, just at one
  # pwsh process per field, so only the call count can catch it.
  FM_PROC_MSYS_PROC_ROOT="$dir/proc" FM_PWSH_LOG="$log" lib_eval "$fakebin" '
    fm_proc_chain_prime 90777
    comm=$(fm_proc_comm 90777)
    args=$(fm_proc_args 90777)
    ppid=$(fm_proc_ppid 90777)
    printf "%s %s %s\n" "$comm" "$args" "$ppid"' > "$dir/out" \
    || fail "a prime rooted at a Win32 pid failed"
  assert_grep 'C:/Users/u/.local/bin/claude C:/Users/u/.local/bin/claude 90888' "$dir/out" \
    "a Win32-rooted prime must answer comm, args and ppid for that pid"
  calls=$(grep -c . "$log" || true)
  [ "$calls" = 1 ] || fail "a Win32-rooted prime plus three reads must start one pwsh, started $calls"
  pass "proc-lib: a prime rooted at a Win32 pid serves every field from one pwsh process"
}

test_msys_chain_terminates_cleanly_without_a_working_pwsh() {
  local dir fakebin got
  dir="$TMP_ROOT/msys-no-pwsh"
  fakebin=$(msys_env "$dir")
  # A Windows host with no usable PowerShell 7 is the pre-library state: native
  # ancestors are unidentifiable. What must NOT happen is a chain that reports
  # the boundary's /proc PPID of 1 as if it were real, or one that fails
  # outright and leaves the caller with no ancestry at all. The stub answers
  # nothing rather than being deleted, because this suite also runs on a
  # Windows host where the REAL pwsh is still on PATH behind the fakebin.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/pwsh"
  chmod +x "$fakebin/pwsh"
  got=$(FM_PROC_MSYS_PROC_ROOT="$dir/proc" lib_eval "$fakebin" 'fm_proc_chain 600' | tr '\t' '|')
  assert_contains "$got" '600|601|/usr/bin/bash|' "the MSYS segment must still be reported without a working pwsh"
  assert_contains "$got" '601|0|/usr/bin/bash|' "the boundary must terminate the chain with ppid 0, not 1"
  pass "proc-lib: with no usable pwsh the chain stops at the MSYS boundary instead of failing or lying"
}

test_msys_liveness_falls_back_to_the_winpid_column() {
  local dir fakebin
  dir="$TMP_ROOT/msys-alive"
  fakebin=$(msys_env "$dir")
  # A native Windows process: kill -0 says "No such process" while ps -W lists
  # it. Getting this wrong evicts a live session lock.
  FM_LIVE_PIDS=600 lib_eval "$fakebin" 'fm_pid_alive 90777' \
    || fail "a native Windows pid listed in ps -W must be reported alive"
  FM_LIVE_PIDS=600 lib_eval "$fakebin" 'fm_pid_alive 600' \
    || fail "an MSYS pid must still be settled by kill -0"
  FM_LIVE_PIDS=600 lib_eval "$fakebin" 'fm_pid_alive 90778' \
    && fail "a Win32 pid absent from ps -W must be reported dead"
  # Column 1 is the MSYS pid column and lives in an unrelated pid space;
  # matching it would invent liveness for a Win32 pid that merely collides.
  FM_LIVE_PIDS=600 lib_eval "$fakebin" 'fm_pid_alive 273976' \
    && fail "fm_pid_alive must match ps -W's WINPID column only, never the MSYS pid column"
  pass "proc-lib: MSYS liveness falls back to the ps -W WINPID column for native processes"
}

test_msys_pgid_reads_proc_and_forks_nothing() {
  local dir fakebin got
  dir="$TMP_ROOT/msys-pgid"
  fakebin=$(msys_env "$dir")
  got=$(FM_PS_LOG="$dir/pgid.log" FM_PWSH_LOG="$dir/pgid.pwsh.log" \
    FM_PROC_MSYS_PROC_ROOT="$dir/proc" lib_eval "$fakebin" 'fm_proc_pgid 600')
  [ "$got" = 600 ] || fail "msys fm_proc_pgid returned '$got', expected /proc/600/pgid"
  FM_PROC_MSYS_PROC_ROOT="$dir/proc" lib_eval "$fakebin" 'fm_proc_pgid 600 >/dev/null' \
    || fail "msys fm_proc_pgid must exit 0 when it answers"
  # The whole point of reading the file: MSYS ps rejects -o, and a pwsh walk
  # would cost a process to answer something already on disk.
  [ ! -s "$dir/pgid.log" ] \
    || fail "the MSYS pgid read must run no ps: $(cat "$dir/pgid.log")"
  [ ! -s "$dir/pgid.pwsh.log" ] \
    || fail "the MSYS pgid read must run no pwsh: $(cat "$dir/pgid.pwsh.log")"
  # A pid with no pgid file at all, and one whose file holds something that is
  # not a pid: both must fail rather than hand a caller a bogus group to signal.
  FM_PROC_MSYS_PROC_ROOT="$dir/proc" lib_eval "$fakebin" 'fm_proc_pgid 604 >/dev/null' \
    && fail "an absent /proc entry must make fm_proc_pgid fail"
  FM_PROC_MSYS_PROC_ROOT="$dir/proc" lib_eval "$fakebin" 'fm_proc_pgid 602 >/dev/null' \
    && fail "a non-numeric pgid file must make fm_proc_pgid fail"
  pass "proc-lib: MSYS fm_proc_pgid reads /proc/<pid>/pgid and validates it, with no ps and no pwsh"
}

test_posix_helpers_run_todays_ps_calls
test_posix_pgid_runs_todays_ps_call
test_posix_comm_propagates_a_dead_pid_as_nonzero
test_posix_prime_costs_nothing_and_memoises_nothing
test_posix_chain_walks_and_stops_at_init
test_posix_liveness_is_kill_zero_alone
test_msys_branch_is_chosen_only_when_ps_cannot_answer
test_msys_chain_stitches_proc_onto_the_win32_walk
test_msys_names_survive_the_callers_matchers
test_msys_walk_costs_exactly_one_pwsh_process
test_msys_lookup_without_a_memo_still_answers
test_msys_prime_rooted_at_a_win32_pid_needs_no_second_walk
test_msys_chain_terminates_cleanly_without_a_working_pwsh
test_msys_liveness_falls_back_to_the_winpid_column
test_msys_pgid_reads_proc_and_forks_nothing
