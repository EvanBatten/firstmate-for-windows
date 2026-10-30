#!/usr/bin/env bash
# lavish-axi is a native Node program, so on Windows it records a board under
# its Windows spelling (C:\Users\...\Temp\...\board.html) while Perl realpath
# under Git Bash answers /tmp/... for the same file. Against the real cygpath,
# the Lavish adapter must still find that session from either POSIX spelling
# of the artifact and read the server's listing, which quotes the Windows path.
# lavish-axi records the on-disk case while realpath keeps the case the artifact
# was named with, so a mixed-case artifact spelling and a differently-cased
# stored spelling must find the session too.
# The store is a fixture under a temp dir: the real ~/.lavish-axi/state.json is
# never read, no server is started, and no source is armed.
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1
T=$(mktemp -d /tmp/fm-win-lavish.XXXXXX)
trap 'rm -rf "$T"' EXIT
DRIVE_T=$(cygpath -u -- "$(cygpath -m -- "$LOCALAPPDATA")")/Temp/${T#/tmp/}
MIXED_T=$(printf '%s' "$DRIVE_T" | tr '[:lower:]' '[:upper:]')

fails=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
expect_eq() {  # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 (expected: $2, got: $3)"; fi
}

[ -d "$DRIVE_T" ] && [ "$DRIVE_T" != "$T" ] || { echo "not ok - $T has no second spelling ($DRIVE_T)"; exit 1; }
mkdir -p "$T/store" "$T/fakebin" "$T/home/config"
printf '<h1>board</h1>\n' > "$T/board.html"
printf '<h1>other</h1>\n' > "$T/other.html"
WIN=$(cygpath -w -- "$T/board.html")
OTHER_WIN=$(cygpath -w -- "$T/other.html")
URL='http://wopr3.example:4387/session/7db373d113d2d273'

cat > "$T/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
[ "${1-}" = poll ] || exit 2
printf '%s:%s\n' "${LAVISH_AXI_HOST-unset}" "${LAVISH_AXI_PORT-unset}" >> "$SEEN"
printf 'session:\n  status: ended\n  ended_by: user\n'
SH
chmod +x "$T/fakebin/lavish-axi"

write_store() {  # <windows-file>...
  perl -MJSON::PP -e '
    my $state = { sessions => {} };
    my $n = 0;
    $state->{sessions}{sprintf("%016x", ++$n)} = { file => $_, url => $ENV{URL} } for @ARGV;
    open my $out, ">", $ENV{STORE} or die $!;
    print $out encode_json($state);
  ' "$@"
}
export STORE="$T/store/state.json" URL

poll() {  # <artifact> -> "<seen>|rc=<rc>"
  local rc=0
  : > "$T/seen"
  PATH="$T/fakebin:$PATH" SEEN="$T/seen" LAVISH_AXI_STATE_DIR="$T/store" FM_HOME="$T/home" \
    LAVISH_AXI_HOST=ambient.example LAVISH_AXI_PORT=44387 \
    bash bin/fm-procevent-lavish.sh poll "$1" > "$T/out" 2>&1 || rc=$?
  printf '%s|rc=%s' "$(cat "$T/seen")" "$rc"
}

write_store "$WIN"
expect_eq "a session stored as $WIN is found from the /tmp spelling" \
  "wopr3.example:4387|rc=0" "$(poll "$T/board.html")"
expect_eq "the same session is found from the drive spelling" \
  "wopr3.example:4387|rc=0" "$(poll "$DRIVE_T/board.html")"
expect_eq "the same session is found from the mixed-case spelling $MIXED_T/board.html" \
  "wopr3.example:4387|rc=0" "$(poll "$MIXED_T/board.html")"

write_store "$(printf '%s' "$WIN" | tr '[:upper:]' '[:lower:]')"
expect_eq "a session stored under a differently-cased spelling is found from the /tmp spelling" \
  "wopr3.example:4387|rc=0" "$(poll "$T/board.html")"

write_store "$OTHER_WIN"
expect_eq "a session for another file is no session for this board" \
  "|rc=1" "$(poll "$T/board.html")"
case $(cat "$T/out") in
  *"board must have one saved Lavish session"*) ok "the refusal names the missing session" ;;
  *) not_ok "the refusal names the missing session (got: $(cat "$T/out"))" ;;
esac

write_store "$WIN" "$OTHER_WIN"
expect_eq "an unrelated session in the store does not disturb the match" \
  "wopr3.example:4387|rc=0" "$(poll "$T/board.html")"

# The server's listing as lavish-axi 0.1.92 prints it on Windows: the file
# TOON-quoted with doubled backslashes.
LISTING=$(printf 'sessions[1]{file,status,url,pending_prompts,listener}:\n  "%s",open,"%s",0,agent-listener\n' \
  "${WIN//\\/\\\\}" "$URL")
listing_open() {  # <listing> <artifact>
  bash -c '. bin/fm-lavish-session-lib.sh; fm_lavish_listing_open "$1" "$(fm_lavish_realpath "$2")"' _ "$1" "$2" \
    && echo open || echo not-open
}
expect_eq "the quoted Windows listing row shows the /tmp-spelled board open" \
  open "$(listing_open "$LISTING" "$T/board.html")"
expect_eq "the same row shows the drive-spelled board open" \
  open "$(listing_open "$LISTING" "$DRIVE_T/board.html")"
expect_eq "the same row shows the mixed-case-spelled board open" \
  open "$(listing_open "$LISTING" "$MIXED_T/board.html")"
expect_eq "the row says nothing about another file" \
  not-open "$(listing_open "$LISTING" "$T/other.html")"
expect_eq "a closed row is not open" \
  not-open "$(listing_open "${LISTING/,open,/,closed,}" "$T/board.html")"

[ "$fails" -eq 0 ] && echo "all tests passed"
exit "$fails"
