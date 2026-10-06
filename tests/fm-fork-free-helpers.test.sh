#!/usr/bin/env bash
# tests/fm-fork-free-helpers.test.sh - the pure-bash stand-ins that the
# watcher, drain, and lock paths use instead of forking small external
# commands every cycle. Each case compares the helper with the command it
# replaces on the same input, under every available Bash (stock macOS
# /bin/bash 3.2 included) and under both the C and a UTF-8 locale, so an edge
# case where the two disagree fails here instead of drifting silently.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-free-helpers)

# Every distinct Bash this host offers: the running one, stock /bin/bash, and
# whatever `bash` resolves to on PATH.
test_interpreters() {
  local seen='' candidate version
  for candidate in "${BASH:-bash}" /bin/bash "$(command -v bash 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    # shellcheck disable=SC2016 # Expanded by the candidate interpreter.
    version=$("$candidate" -c 'printf "%s" "$BASH_VERSION"' 2>/dev/null) || continue
    case " $seen " in *" $version "*) continue ;; esac
    seen="$seen $version"
    printf '%s\n' "$candidate"
  done
}

test_locales() {
  printf '%s\n' C
  if locale -a 2>/dev/null | grep -qx 'C.UTF-8'; then
    printf '%s\n' C.UTF-8
  elif locale -a 2>/dev/null | grep -qx 'en_US.UTF-8'; then
    printf '%s\n' en_US.UTF-8
  fi
}

# Run <script> under every interpreter and locale; any output is a mismatch
# report and fails the case.
run_everywhere() {  # <label> <script> [args...]
  local label=$1 script=$2 interpreter loc out
  shift 2
  while IFS= read -r interpreter; do
    while IFS= read -r loc; do
      out=$(LC_ALL=$loc FM_STATE_OVERRIDE="$TMP_ROOT/state" "$interpreter" "$script" "$ROOT" "$@" 2>&1) \
        || fail "$label failed under $interpreter ($loc): $out"
      [ -z "$out" ] || fail "$label differs under $interpreter ($loc):"$'\n'"$out"
    done < <(test_locales)
  done < <(test_interpreters)
}

test_path_helpers_match_dirname_and_basename() {
  local script="$TMP_ROOT/paths.sh" cases="$TMP_ROOT/path-cases"
  # NUL-separated so paths may carry newlines.
  printf '%s\0' '' / // /// a a/ a// /a /a/ //a a/b a/b/ a//b //a//b/ . .. ./ ../x \
    'a b/c d' 'a/-x' $'a\n/b' $'a/b\n' $'x\n' $'a/b\n\n' $'a\n' $'\n' $'/\n' $'a/\n/' \
    'state/crew.status' '/abs/state/.seen-x' 'x.y.z/.status' '*/?' 'a/[b]' \
    $'caf\xc3\xa9/\xc3\xbc.status' $'\xff\xfe/\xc3.x' $'a/\xff/' > "$cases"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
while IFS= read -r -d '' p; do
  fm_dirname_to got "$p"
  want=$(dirname -- "$p")
  [ "$got" = "$want" ] || printf 'dirname %q: helper %q, command %q\n' "$p" "$got" "$want"
  fm_basename_to got "$p"
  want=$(basename -- "$p")
  [ "$got" = "$want" ] || printf 'basename %q: helper %q, command %q\n' "$p" "$got" "$want"
done < "$2"
SH
  run_everywhere "path helpers" "$script" "$cases"
  pass "fm_dirname_to and fm_basename_to match dirname and basename on every edge case"
}

test_epoch_helper_matches_date_and_never_forks_more() {
  local script="$TMP_ROOT/epoch.sh" shim="$TMP_ROOT/epoch-shim" log="$TMP_ROOT/epoch-date.log"
  mkdir -p "$shim"
  cat > "$shim/date" <<SH
#!/bin/sh
printf 'date\n' >> "$log"
exec $(command -v date) "\$@"
SH
  chmod +x "$shim/date"
  # shellcheck disable=SC2016 # Expanded by the child shell.
  printf '%s\n' '. "$1/bin/fm-wake-lib.sh"' \
    'PATH="$2:$PATH"' \
    ': > "$3"' \
    'before=$(/bin/date +%s)' \
    'fm_epoch_seconds_to now' \
    'after=$(/bin/date +%s)' \
    'case "$now" in ""|*[!0-9]*) printf "not epoch seconds: %q\n" "$now" ;; esac' \
    '[ "$now" -ge "$before" ] && [ "$now" -le "$after" ] || printf "%s outside [%s, %s]\n" "$now" "$before" "$after"' \
    'forks=$(grep -c . "$3" || true)' \
    'if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then' \
    '  [ "$forks" -eq 0 ] || printf "bash %s ran date %s times\n" "$BASH_VERSION" "$forks"' \
    'else' \
    '  [ "$forks" -eq 1 ] || printf "bash %s ran date %s times, not exactly once\n" "$BASH_VERSION" "$forks"' \
    'fi' > "$script"
  run_everywhere "epoch helper" "$script" "$shim" "$log"
  pass "fm_epoch_seconds_to reads the clock like date +%s and forks date at most as often"
}

test_signal_seen_path_and_lock_abs_path_are_unchanged() {
  local script="$TMP_ROOT/seen.sh" dir="$TMP_ROOT/lockdir"
  mkdir -p "$dir/sub" "$TMP_ROOT/state"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
state=$2
for f in "$state/crew.status" "$state/a.b.c.status" "state/x.status" ".status" \
  "$state/crew.turn-ended" "$state/dir/" "x" "a.b/" "/" "$state/q.status.bak"; do
  got=$(fm_wake_signal_seen_path "$state" "$f")
  case "$f" in
    *.status)
      task=$(basename "$f"); task=${task%.status}
      want=$(printf '%s/.seen-%s' "$state" "$(printf '%s.status' "$task" | tr '.' '_')")
      ;;
    *) want=$(printf '%s/.seen-%s' "$state" "$(basename "$f" | tr '.' '_')") ;;
  esac
  [ "$got" = "$want" ] || printf 'seen path %q: helper %q, commands %q\n' "$f" "$got" "$want"
done
cd "$3" || exit 1
for p in "$3/x.lock" "$3/sub/x.lock" "$3//sub//x.lock" "sub/x.lock" "x.lock" "sub/x.lock/" "./sub/../x.lock"; do
  got=$(fm_lock_abs_path "$p")
  want="$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
  [ "$got" = "$want" ] || printf 'lock path %q: helper %q, commands %q\n' "$p" "$got" "$want"
done
SH
  run_everywhere "seen and lock paths" "$script" "$TMP_ROOT/state" "$dir"
  pass "signal seen paths and absolute lock paths are byte-identical to the dirname/basename/tr forms"
}

test_recovery_marker_read_accepts_exactly_one_newline() {
  local script="$TMP_ROOT/marker.sh" cases="$TMP_ROOT/marker-cases"
  mkdir -p "$cases"
  printf 'pending:handling:g1\n' > "$cases/one"
  printf 'pending:handling:g1' > "$cases/unterminated"
  printf 'pending:handling:g1\npending:handling:g2\n' > "$cases/two"
  printf 'pending:handling:g1\ntrailing-partial' > "$cases/partial-second"
  : > "$cases/empty"
  printf '\n' > "$cases/blank"
  printf 'announced:downtime:g\0x\n' > "$cases/nul"
  printf 'acked:handling:g1\r\n' > "$cases/crlf"
  printf 'pending:handling:g1\n\n' > "$cases/blank-second"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
for marker in "$2"/*; do
  # The replaced reference: one newline byte by wc -l, then the same token read.
  want=reject
  if [ "$(wc -l < "$marker" | tr -d '[:space:]')" = 1 ] && IFS= read -r line < "$marker"; then
    case "$line" in
      pending:handling:*|pending:downtime:*|announced:handling:*|announced:downtime:*|acked:handling:*|acked:downtime:*)
        case "${line##*:}" in ''|*[!A-Za-z0-9._-]*) ;; *) want="accept:$line" ;; esac ;;
    esac
  fi
  if fm_recovery_marker_read "$marker"; then got="accept:$FM_RECOVERY_MARKER_TOKEN"; else got=reject; fi
  [ "$got" = "$want" ] || printf 'marker %s: helper %q, reference %q\n' "${marker##*/}" "$got" "$want"
done
SH
  run_everywhere "recovery marker read" "$script" "$cases"
  pass "recovery marker reads accept exactly the one-line records wc -l accepted"
}

test_window_to_task_matches_the_meta_pipeline() {
  local script="$TMP_ROOT/window.sh" state="$TMP_ROOT/window-state"
  mkdir -p "$state"
  printf 'window=sess:w1\nbackend=tmux\n' > "$state/alpha.meta"
  printf 'window=old\nwindow=sess:w2\n' > "$state/beta.meta"
  printf 'terminal=term-3\nwindow=\n' > "$state/gamma.meta"
  printf 'window=a=b=c' > "$state/delta.meta"
  printf 'window=sess:w5\r\n' > "$state/eps.meta"
  printf ' window=sess:w6\nwindow= sess:w6 \n' > "$state/zeta.meta"
  printf 'terminal=t7\nterminal=\n' > "$state/eta.meta"
  mkdir -p "$state/dir.meta"
  printf 'window=sess:w9\n' > "$state/theta.meta"
  chmod 000 "$state/theta.meta"
  cat > "$script" <<'SH'
. "$1/bin/fm-classify-lib.sh"
state=$2
reference() {  # the replaced grep | tail -1 | cut -d= -f2- lookup
  local w=$1 meta mw mt t
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
    t=$(basename "$meta"); printf '%s' "${t%.meta}"; return 0
  done
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}
for w in sess:w1 old sess:w2 term-3 '' a=b=c a sess:w5 $'sess:w5\r' ' sess:w6 ' sess:w6 t7 sess:w9 sess:fm-fallback-x unknown; do
  got=$(window_to_task "$w" "$state")
  want=$(reference "$w")
  [ "$got" = "$want" ] || printf 'window %q: helper %q, pipeline %q\n' "$w" "$got" "$want"
done
SH
  run_everywhere "window_to_task" "$script" "$state"
  chmod 600 "$state/theta.meta"
  pass "window_to_task resolves every recorded window exactly as the grep/tail/cut pipeline did"
}

test_classify_stat_helpers_read_the_kernel_name_once() {
  local script="$TMP_ROOT/uname.sh" shim="$TMP_ROOT/uname-shim" log="$TMP_ROOT/uname.log" file="$TMP_ROOT/sized"
  mkdir -p "$shim"
  cat > "$shim/uname" <<SH
#!/bin/sh
printf 'uname\n' >> "$log"
exec $(command -v uname) "\$@"
SH
  chmod +x "$shim/uname"
  printf 'caf\303\251 bytes\n' > "$file"
  cat > "$script" <<'SH'
PATH="$2:$PATH"
: > "$3"
. "$1/bin/fm-classify-lib.sh"
for _ in 1 2 3 4 5; do
  size=$(_fm_status_file_size "$4")
  [ "$size" = "$(LC_ALL=C wc -c < "$4" | tr -d ' ')" ] || printf 'size %q\n' "$size"
  mtime=$(_fm_status_file_mtime "$4")
  case "$mtime" in ''|*[!0-9]*) printf 'mtime %q\n' "$mtime" ;; esac
  _fm_open_decisions_file_ident "$4" >/dev/null || printf 'identity unreadable\n'
done
calls=$(grep -c . "$3" || true)
[ "$calls" -eq 1 ] || printf 'uname ran %s times for 15 stat reads\n' "$calls"
SH
  run_everywhere "classify stat helpers" "$script" "$shim" "$log" "$file"
  pass "classify stat helpers resolve the kernel name once per process"
}

test_backlog_record_guard_resolves_its_paths_in_one_perl() {
  local script="$TMP_ROOT/guard.sh" shim="$TMP_ROOT/perl-shim" log="$TMP_ROOT/perl.log" home="$TMP_ROOT/guard-home"
  mkdir -p "$shim" "$home/data" "$home/plain" "$TMP_ROOT/outside"
  : > "$home/data/backlog.md"
  : > "$TMP_ROOT/outside/backlog.md"
  : > "$home/afile"
  ln -sfn "$TMP_ROOT/outside" "$home/escape"
  ln -sfn "$TMP_ROOT/outside/backlog.md" "$home/data/swapped.md"
  ln -sfn "$home/data/backlog.md" "$home/data/alias.md"
  cat > "$shim/perl" <<SH
#!/bin/sh
printf 'perl\n' >> "$log"
exec $(command -v perl) "\$@"
SH
  chmod +x "$shim/perl"
  cat > "$script" <<'SH'
PATH="$2:$PATH"
. "$1/bin/fm-backlog-transition-lib.sh"
log=$3 h=$4
FM_HOME=$h
c() {  # <want-rc> <want-error-substring> <path> <label> <root> [parent-only]
  local want_rc=$1 want_err=$2 rc=0 calls
  shift 2
  : > "$log"
  FM_BACKLOG_TRANSITION_ERROR=
  fm_backlog_record_parent_authorized "$@" || rc=$?
  calls=$(grep -c . "$log" || true)
  [ "$rc" = "$want_rc" ] || printf '%s: rc %s, want %s (%s)\n' "$1" "$rc" "$want_rc" "$FM_BACKLOG_TRANSITION_ERROR"
  case "$FM_BACKLOG_TRANSITION_ERROR" in
    *"$want_err"*) ;;
    *) printf '%s: error %q, want %q\n' "$1" "$FM_BACKLOG_TRANSITION_ERROR" "$want_err" ;;
  esac
  [ "$calls" -eq 1 ] || printf '%s: perl ran %s times for one guard check\n' "$1" "$calls"
}
c 0 '' "$h/data/backlog.md" "backlog file" "$h/data"
c 0 '' "$h/data/new.md" "backlog file" "$h/data"
c 0 '' "$h/data/backlog.md" "backlog file" "$h/data" parent-only
c 1 'backlog file resolves outside its authorized directory' "$h/data/swapped.md" "backlog file" "$h/data"
c 1 'backlog file resolves through a different final path' "$h/data/alias.md" "backlog file" "$h/data"
c 0 '' "$h/data/swapped.md" "backlog file" "$h/data" parent-only
c 1 'record authorized directory resolves outside this home' "$h/escape/backlog.md" record "$h/escape"
c 1 'record authorized directory cannot be resolved' "$h/gone/sub/x" record "$h/gone/sub"
c 1 'record authorized directory is not a directory' "$h/afile/x" record "$h/afile"
c 1 'record parent directory cannot be resolved' "$h/data/no/such/x" record "$h/data"
c 1 'record resolves outside its authorized directory' "$h/plain/x" record "$h/data"
FM_HOME=
c 0 '' "$h/escape/backlog.md" record "$h/escape"
SH
  run_everywhere "backlog record guard" "$script" "$shim" "$log" "$home"
  pass "the backlog record guard keeps every verdict and resolves its paths with one perl"
}

test_file_contents_helper_matches_cat_and_lock_cycle_never_forks_it() {
  local script="$TMP_ROOT/contents.sh" shim="$TMP_ROOT/cat-shim" log="$TMP_ROOT/cat.log" dir="$TMP_ROOT/contents"
  mkdir -p "$shim" "$dir/adir" "$TMP_ROOT/lockstate"
  printf '' > "$dir/empty"
  printf '123\n' > "$dir/pid"
  printf '123' > "$dir/bare"
  printf '123\n\n\n' > "$dir/newlines"
  printf '\n' > "$dir/newline"
  printf '  12 3 \t\n' > "$dir/spaces"
  printf '12\r\n' > "$dir/crlf"
  printf 'a\b\nc\n' > "$dir/lines"
  printf '12\0003\n' > "$dir/nul"
  printf '\000\n' > "$dir/onlynul"
  printf 'caf\303\251\377\n' > "$dir/bytes"
  cat > "$shim/cat" <<SH
#!/bin/sh
printf 'cat\n' >> "$log"
exec $(command -v cat) "\$@"
SH
  chmod +x "$shim/cat"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
for f in empty pid bare newlines newline spaces crlf lines nul onlynul bytes adir missing; do
  { fm_file_contents_to got "$2/$f"; } 2>/dev/null
  { want=$(cat "$2/$f" 2>/dev/null || true); } 2>/dev/null
  [ "$got" = "$want" ] || printf 'contents %s: helper %q, cat %q\n' "$f" "$got" "$want"
done
PATH="$3:$PATH"
: > "$4"
fm_lock_try_acquire "$5/.x.lock" || printf 'lock not acquired\n'
fm_lock_release "$5/.x.lock"
[ ! -e "$5/.x.lock" ] && [ ! -L "$5/.x.lock" ] || printf 'lock left behind\n'
calls=$(grep -c . "$4" || true)
[ "$calls" -eq 0 ] || printf 'an uncontended lock cycle ran cat %s times\n' "$calls"
SH
  run_everywhere "file contents helper" "$script" "$dir" "$shim" "$log" "$TMP_ROOT/lockstate"
  pass "fm_file_contents_to reads a file as \$(cat) does and a lock cycle never forks cat"
}

test_helpers_assign_any_output_variable_name() {
  local script="$TMP_ROOT/names.sh"
  printf '42
' > "$TMP_ROOT/names-pid"
  cat > "$script" <<'SH'
. "$1/bin/fm-path-lib.sh"
for name in fm_path fm_contents got; do
  unset "$name"
  fm_dirname_to "$name" /a/b/c
  [ "${!name-UNSET}" = /a/b ] || printf 'fm_dirname_to into %s left %s
' "$name" "${!name-UNSET}"
  unset "$name"
  fm_basename_to "$name" /a/b/c
  [ "${!name-UNSET}" = c ] || printf 'fm_basename_to into %s left %s
' "$name" "${!name-UNSET}"
  unset "$name"
  fm_file_contents_to "$name" "$2"
  [ "${!name-UNSET}" = 42 ] || printf 'fm_file_contents_to into %s left %s
' "$name" "${!name-UNSET}"
  fm_file_contents_to "$name" "$2.missing"
  [ "${!name-UNSET}" = '' ] || printf 'fm_file_contents_to of a missing file into %s left %s
' "$name" "${!name-UNSET}"
done
SH
  run_everywhere "output variable names" "$script" "$TMP_ROOT/names-pid"
  pass "path and contents helpers assign any output variable name, their own locals' included"
}

test_spawn_shell_quote_round_trips_and_never_forks() {
  local script="$TMP_ROOT/quote.sh" shim="$TMP_ROOT/quote-shim" log="$TMP_ROOT/quote.log" cmd
  mkdir -p "$shim"
  for cmd in sed cat tr awk perl; do
    printf '#!/bin/sh\nprintf "%%s\\n" %s >> "%s"\nexit 1\n' "$cmd" "$log" > "$shim/$cmd"
    chmod +x "$shim/$cmd"
  done
  awk '/^shell_quote\(\) \{/,/^\}/' "$ROOT/bin/fm-spawn.sh" > "$TMP_ROOT/quote-fn.sh"
  cat > "$script" <<'SH'
. "$2"
PATH="$3:$PATH"
: > "$4"
check() {  # <input> [<expected>]
  local got back
  got=$(shell_quote "$1")
  [ $# -lt 2 ] || [ "$got" = "$2" ] || printf 'shell_quote %q: got %q, want %q\n' "$1" "$got" "$2"
  eval "back=$got"
  [ "$back" = "$1" ] || printf 'shell_quote %q does not round-trip: %q\n' "$1" "$back"
}
check '' "''"
check plain "'plain'"
check "it's" "'it'\\''s'"
check "''" "''\\'''\\'''"
check '/tmp/launch.1.sh' "'/tmp/launch.1.sh'"
check $'a\nb\'c\n'
check $'trailing\n\n'
check 'back\slash\'
check 'amp & '"'"'&'"'"' \&'
check '$(echo no) `x` ${y} * ? [a]'
check $'caf\303\251 \t tab'
[ ! -s "$4" ] || printf 'shell_quote ran %s\n' "$(< "$4")"
SH
  run_everywhere "spawn shell_quote" "$script" "$TMP_ROOT/quote-fn.sh" "$shim" "$log"
  pass "fm-spawn's shell_quote round-trips every input through eval without starting a process"
}

test_backlog_data_absolute_to_resolves_like_cd_and_pwd() {
  local script="$TMP_ROOT/data-abs.sh" dir="$TMP_ROOT/data-abs"
  rm -rf "$dir"; mkdir -p "$dir/real dir" "$dir/café"
  ln -s "real dir" "$dir/link" 2>/dev/null || true
  : > "$dir/file"
  cat > "$script" <<'SH'
. "$1/bin/fm-backlog-transition-lib.sh"
d=$2
real=$(cd "$d/real dir" && pwd -P)
check() {  # <want-status> <want-value> <data-dir>
  local status=0 out=UNSET
  FM_BACKLOG_TRANSITION_ERROR=untouched
  fm_backlog_data_absolute_to out "$3" 2>/dev/null || status=$?
  [ "$status" = "$1" ] || printf 'data %q: status %s, want %s\n' "$3" "$status" "$1"
  [ "$status" != 0 ] || [ "$out" = "$2" ] || printf 'data %q: %q, want %q\n' "$3" "$out" "$2"
  [ "$FM_BACKLOG_TRANSITION_ERROR" = untouched ] || printf 'data %q set the error global\n' "$3"
}
check 0 "$real" "$d/real dir"
check 0 "$real" "$d/real dir///"
check 0 "$(cd "$d/café" && pwd -P)" "$d/café"
[ ! -L "$d/link" ] || check 0 "$real" "$d/link"
check 0 / /
check 0 / ///
check 1 '' "$d/file"
check 1 '' "$d/missing"
check 1 '' "$d/file/"
check 2 '' "$d/real dir"$'\n'
check 2 '' "$d/tab"$'\t'"dir"
err=$(fm_backlog_data_absolute_to out "$d/x"$'\001' 2>&1)
[ "$err" = 'error: data directory contains an invalid control byte' ] || printf 'control byte message: %q\n' "$err"
for name in out status data; do
  unset "$name"
  fm_backlog_data_absolute_to "$name" "$d/real dir" || printf 'into %s failed\n' "$name"
  [ "${!name-UNSET}" = "$real" ] || printf 'into %s left %s\n' "$name" "${!name-UNSET}"
done
SH
  run_everywhere "backlog data directory" "$script" "$dir"
  pass "fm_backlog_data_absolute_to resolves a data directory as cd and pwd -P do, into any variable"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
else
  test_path_helpers_match_dirname_and_basename
  test_epoch_helper_matches_date_and_never_forks_more
  test_signal_seen_path_and_lock_abs_path_are_unchanged
  test_recovery_marker_read_accepts_exactly_one_newline
  test_window_to_task_matches_the_meta_pipeline
  test_classify_stat_helpers_read_the_kernel_name_once
  test_backlog_record_guard_resolves_its_paths_in_one_perl
  test_file_contents_helper_matches_cat_and_lock_cycle_never_forks_it
  test_helpers_assign_any_output_variable_name
  test_spawn_shell_quote_round_trips_and_never_forks
  test_backlog_data_absolute_to_resolves_like_cd_and_pwd
fi
