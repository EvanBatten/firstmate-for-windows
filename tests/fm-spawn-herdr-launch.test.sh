#!/usr/bin/env bash
# fm-spawn.sh's herdr launch step against a fake herdr pane that renders typed
# text after a delay and drops an Enter that arrives before the text renders,
# as a loaded worker pane does (issue #160: the launch line sat typed and
# unsubmitted). The step runs from fm-spawn.sh's own source, lifted from the
# launch-sent marker to the harness-specific follow-up, with the real herdr
# adapter on top of the fake.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-launch)

make_slow_pane_herdr() {  # <fakebin> <pane-dir>
  cat > "$1/herdr" <<SH
#!/usr/bin/env bash
pane=$2
now() { perl -MTime::HiRes=time -e 'printf "%d", time * 1000'; }
case "\$1 \$2" in
  'status --json') printf '%s\n' '{"client":{"protocol":99,"version":"9.9.9"},"server":{"running":true,"compatible":true}}' ;;
  'pane send-text') printf '%s\t%s\n' "\$((\$(now) + \${FM_FAKE_RENDER_MS:-5000}))" "\$4" > "\$pane/typed" ;;
  'pane send-keys')
    if [ "\$4" = enter ] && [ -f "\$pane/typed" ]; then
      IFS=\$'\t' read -r ready text < "\$pane/typed"
      if [ "\$(now)" -ge "\$ready" ]; then
        printf '%s\n' "\$text" >> "\$pane/submitted"
        rm -f "\$pane/typed"
      else
        printf 'enter before render\n' >> "\$pane/lost"
      fi
    fi
    ;;
  'pane run') printf '%s\n' "\$4" >> "\$pane/submitted" ;;
esac
exit 0
SH
  chmod +x "$1/herdr"
}

lift() {  # <awk-range-program>
  awk "$1" "$ROOT/bin/fm-spawn.sh"
}

# shellcheck disable=SC2016 # The lifted step expands these in its own shell.
test_herdr_launch_line_is_submitted_on_a_slow_pane() {
  local dir="$TMP_ROOT/slow" fakebin step out
  mkdir -p "$dir/pane"
  fakebin=$(fm_fakebin "$dir")
  make_slow_pane_herdr "$fakebin" "$dir/pane"
  step="$dir/step.sh"
  {
    printf '%s\n' '. "$ROOT/bin/fm-backend.sh"' 'fm_backend_source herdr'
    lift '/^shell_quote\(\) \{/,/^\}/'
    lift '/^spawn_send_text_line\(\) \{/,/^\}/'
    lift '/^spawn_send_literal\(\) \{/,/^\}/'
    lift '/^spawn_send_key\(\) \{/,/^\}/'
    lift '/^SPAWN_LAUNCH_SENT=1$/{on=1} /^if \[ "\$HARNESS" = kimi \]; then$/{on=0} on'
    printf '%s\n' 'printf "abort-cleanup=%s\n" "$HERDR_PROJECTION_ABORT_CLEANUP"'
  } > "$step"
  grep -q 'spawn_send' "$step" || fail "the launch step was not found in fm-spawn.sh"
  out=$(cd "$dir" && PATH="$fakebin:$PATH" ROOT="$ROOT" BACKEND=herdr HARNESS=claude T=fmtest:w1:p1 \
    LAUNCH_FILE="$dir/launch.1.sh" HERDR_PROJECTED=1 HERDR_PROJECTION_ABORT_CLEANUP=1 \
    bash -u "$step" 2>&1) || fail "the launch step failed: $out"
  assert_contains "$out" "abort-cleanup=0" "the launch step left projection abort cleanup armed"
  [ ! -s "$dir/pane/lost" ] || fail "the pane dropped the launch Enter: $(cat "$dir/pane/lost")"
  [ "$(cat "$dir/pane/submitted" 2>/dev/null)" = ". '$dir/launch.1.sh'" ] \
    || fail "the pane never ran the launch line (submitted: $(cat "$dir/pane/submitted" 2>/dev/null))"
  pass "fm-spawn submits the herdr launch line even when the pane renders it late"
}

test_herdr_launch_line_is_submitted_on_a_slow_pane
