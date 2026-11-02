#!/usr/bin/env bash
# Behavior tests for bin/fm-lavish-session-lib.sh through the Lavish adapter:
# a Lavish session whose stored `file` is the Windows spelling of the artifact
# is still found from the POSIX spelling realpath answers, two spellings of one
# artifact still resolve to that one session, a differently-cased stored
# spelling still resolves, a different file resolves to none, and a host
# without cygpath keeps the exact comparison it always had.
#
# cygpath is faked so the Windows path translation runs on every host.
# Its -lm folds a POSIX path under the Z:/posix drive and a Windows path to
# forward slashes, the two answers the real one gives for the two spellings of
# one file, and leaves case alone as the real one does for a path not on disk.
# The fixture state.json stands in for Lavish's own store; the real one is
# never read, no Lavish server is started, and `arm` is never run.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADAPTER="$ROOT/bin/fm-procevent-lavish.sh"
TMP_ROOT=$(fm_test_tmproot fm-lavish-session-path)
STORE="$TMP_ROOT/lavish-state"
SEEN="$TMP_ROOT/seen"
mkdir -p "$STORE" "$TMP_ROOT/sub"
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/config"

ART="$TMP_ROOT/board.html"
OTHER="$TMP_ROOT/other.html"
printf '<h1>board</h1>\n' > "$ART"
printf '<h1>other</h1>\n' > "$OTHER"
REAL=$(perl -MCwd=realpath -e 'print realpath($ARGV[0])' "$ART")
OTHER_REAL=$(perl -MCwd=realpath -e 'print realpath($ARGV[0])' "$OTHER")

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/cygpath" <<'SH'
#!/usr/bin/env bash
# Stands in for Git Bash's cygpath -lm: a Windows spelling comes back with
# forward slashes, a POSIX spelling comes back under the Z:/posix drive, one
# answer per path argument in order.
[ "${1-}" = -lm ] || exit 2
shift
[ "${1-}" != -- ] || shift
for path in "$@"; do
  case "$path" in
    [A-Za-z]:*) printf '%s\n' "$path" | tr '\\' / ;;
    *) printf 'Z:/posix%s\n' "$path" ;;
  esac
done
SH
cat > "$FAKEBIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
[ "${1-}" = poll ] || exit 2
printf '%s:%s\n' "${LAVISH_AXI_HOST-unset}" "${LAVISH_AXI_PORT-unset}" >> "$SEEN"
printf 'session:\n  status: ended\n  ended_by: user\n'
SH
chmod +x "$FAKEBIN/cygpath" "$FAKEBIN/lavish-axi"

# The Windows spelling the fake cygpath pairs with a POSIX realpath: the
# Z:\posix drive prefix with backslashes, and a lowercase drive letter so the
# case-insensitive comparison is exercised rather than assumed.
windows_spelling() {  # <posix-path>
  printf 'z:\\posix%s\n' "$1" | tr / '\134'
}

# The same Windows spelling in upper case, as lavish-axi may record it when
# the on-disk case differs from the case the artifact was armed under.
upper_windows_spelling() {  # <posix-path>
  windows_spelling "$1" | tr '[:lower:]' '[:upper:]'
}

# Writes the fixture store with the given sessions, each `<file>|<url>`.
write_store() {
  perl -MJSON::PP -e '
    my $state = { sessions => {} };
    my $n = 0;
    for (@ARGV) {
      my ($file, $url) = split /\|/, $_, 2;
      $state->{sessions}{sprintf("%016x", ++$n)} = { file => $file, url => $url };
    }
    open my $out, ">", $ENV{STORE_FILE} or die $!;
    print $out encode_json($state);
  ' "$@"
}
export STORE_FILE="$STORE/state.json"

poll() {  # <artifact> -> sets POLL_RC and out
  POLL_RC=0
  : > "$SEEN"
  out=$(PATH="$FAKEBIN:$PATH" SEEN="$SEEN" LAVISH_AXI_STATE_DIR="$STORE" \
    LAVISH_AXI_HOST=ambient.example LAVISH_AXI_PORT=44387 \
    "$ADAPTER" poll "$1" 2>&1) || POLL_RC=$?
}

URL='http://board.example:24387/session/0123456789abcdef'

write_store "$(windows_spelling "$REAL")|$URL"
poll "$ART"
[ "$POLL_RC" -eq 0 ] || fail "poll failed against a Windows-spelled session: $out"
assert_equals "$(cat "$SEEN")" 'board.example:24387' \
  "host and port come from the session stored under the Windows spelling"
pass "a session stored under the Windows spelling of the artifact resolves its server"

for spelling in "$TMP_ROOT/./board.html" "$TMP_ROOT/sub/../board.html"; do
  poll "$spelling"
  [ "$POLL_RC" -eq 0 ] || fail "poll failed from the spelling $spelling: $out"
  assert_equals "$(cat "$SEEN")" 'board.example:24387' \
    "the spelling $spelling resolves the same single session"
done
pass "two spellings of one artifact still yield the one saved session"

write_store "$(upper_windows_spelling "$REAL")|$URL"
poll "$ART"
[ "$POLL_RC" -eq 0 ] || fail "poll failed against a differently-cased Windows-spelled session: $out"
assert_equals "$(cat "$SEEN")" 'board.example:24387' \
  "host and port come from the session stored under the differently-cased spelling"
pass "a differently-cased stored spelling of the artifact still yields the one session"

write_store "$(windows_spelling "$OTHER_REAL")|$URL"
poll "$ART"
[ "$POLL_RC" -ne 0 ] || fail "a session for a different file was accepted"
assert_contains "$out" 'board must have one saved Lavish session' \
  "a different file's session is reported as no session for this board"
[ ! -s "$SEEN" ] || fail "a different file's session reached the CLI"
pass "a Windows-spelled session for a different file yields none"

write_store "$(windows_spelling "$REAL")|$URL" "$(windows_spelling "$OTHER_REAL")|$URL"
poll "$ART"
[ "$POLL_RC" -eq 0 ] || fail "poll failed with a second, unrelated session present: $out"
assert_equals "$(cat "$SEEN")" 'board.example:24387' \
  "an unrelated Windows-spelled session does not disturb the match"
pass "only the matching session counts when the store holds several boards"

# Without cygpath the key is the spelling itself: a POSIX-spelled session still
# resolves and a Windows-spelled one is not guessed at, exactly as before. The
# fake above is simply left off PATH; a host whose own PATH carries cygpath is
# the Windows host, where that exact comparison is not what runs.
if command -v cygpath >/dev/null 2>&1; then
  printf 'skip: without-cygpath comparison: this host has a real cygpath\n'
else
  NO_CYGPATH_BIN=$(fm_fakebin "$TMP_ROOT/no-cygpath")
  cp "$FAKEBIN/lavish-axi" "$NO_CYGPATH_BIN/lavish-axi"
  write_store "$REAL|$URL"
  : > "$SEEN"
  rc=0
  out=$(PATH="$NO_CYGPATH_BIN:$PATH" SEEN="$SEEN" LAVISH_AXI_STATE_DIR="$STORE" \
    LAVISH_AXI_HOST=ambient.example LAVISH_AXI_PORT=44387 \
    "$ADAPTER" poll "$ART" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "poll without cygpath failed against a POSIX-spelled session: $out"
  assert_equals "$(cat "$SEEN")" 'board.example:24387' \
    "a POSIX host resolves the POSIX-spelled session"
  write_store "$(windows_spelling "$REAL")|$URL"
  : > "$SEEN"
  rc=0
  out=$(PATH="$NO_CYGPATH_BIN:$PATH" SEEN="$SEEN" LAVISH_AXI_STATE_DIR="$STORE" \
    LAVISH_AXI_HOST=ambient.example LAVISH_AXI_PORT=44387 \
    "$ADAPTER" poll "$ART" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a POSIX host accepted a Windows-spelled session it cannot translate"
  assert_contains "$out" 'board must have one saved Lavish session' \
    "a POSIX host keeps the exact comparison"
  [ ! -s "$SEEN" ] || fail "an untranslatable session reached the CLI"
  pass "without cygpath the comparison stays exact, as on macOS and Linux"
fi

# lavish-axi's own listing is the other Lavish-written spelling the fleet
# reads: TOON-quoted with doubled backslashes on Windows, bare on POSIX.
# The quoted row is in upper case so the listing match folds case too.
listing_open() {  # <listing> <real>
  PATH="$FAKEBIN:$PATH" bash -c '
    set -u
    . "$1/bin/fm-lavish-session-lib.sh"
    fm_lavish_listing_open "$2" "$3"
  ' _ "$ROOT" "$1" "$2"
}
quoted=$(upper_windows_spelling "$REAL")
quoted=${quoted//\\/\\\\}
LISTING=$(printf 'sessions[2]{file,status,url,pending_prompts,listener}:\n  "%s",open,"%s",0,agent-listener\n  %s,open,"%s",0,none\n' \
  "$quoted" "$URL" "$OTHER_REAL" "$URL")
listing_open "$LISTING" "$REAL" \
  || fail "a quoted Windows row for the artifact was not read as open"
listing_open "$LISTING" "$OTHER_REAL" \
  || fail "a bare POSIX row for another artifact was not read as open"
listing_open "${LISTING/,open,\"$URL\",0,agent-listener/,closed,\"$URL\",0,agent-listener}" "$REAL" \
  && fail "a closed Windows row was read as open"
listing_open "$LISTING" "$TMP_ROOT/sub" \
  && fail "a file with no row was read as open"
pass "the session listing matches the artifact through either spelling and only when open"

printf 'all tests passed\n'
