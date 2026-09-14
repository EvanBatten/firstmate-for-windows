export PATH="$HOME/bin:$PATH"
B=/tmp/nm-01M2EGJ8
LIMIT_KIB=9437184   # 9 GiB watchdog, three times the fixed watch peak
CAP_S=${CAP_S:-200}
cd "$B/prefix" || exit 1
root=$1
echo "== tree: 0f5d34d (parent of the fix bd62bac: pending-reply lock helpers and teardown's guarded reload still carry source=bin/fm-wake-lib.sh)"
grep -n 'shellcheck source=bin/fm-wake-lib.sh' bin/fm-pending-reply-lib.sh bin/fm-teardown.sh
echo "== bin/fm-lint.sh --jobs 1 $root   (watchdog: kill at ${LIMIT_KIB} KiB RSS or ${CAP_S}s)"
start=$(date +%s)
bin/fm-lint.sh --jobs 1 "$root" > "$B/prefix-lint.out" 2>&1 &
lint_pid=$!
peak=0; verdict=finished
while kill -0 "$lint_pid" 2>/dev/null; do
  for p in $(pgrep -x shellcheck); do
    rss=$(awk '/^VmRSS:/{print $2}' "/proc/$p/status" 2>/dev/null)
    [ -n "$rss" ] && [ "$rss" -gt "$peak" ] && peak=$rss
  done
  now=$(( $(date +%s) - start ))
  if [ "$peak" -ge "$LIMIT_KIB" ]; then verdict="killed: RSS passed ${LIMIT_KIB} KiB at ${now}s"; break; fi
  if [ "$now" -ge "$CAP_S" ]; then verdict="killed: still running at ${CAP_S}s cap"; break; fi
  if [ $((now % 10)) -eq 0 ]; then echo "t=${now}s shellcheck_rss_peak=${peak} KiB"; fi
  sleep 1
done
if [ "$verdict" != finished ]; then
  kill -TERM "$lint_pid" 2>/dev/null; sleep 2; pkill -KILL -x shellcheck 2>/dev/null
fi
wait "$lint_pid"; rc=$?
echo "verdict=$verdict lint_exit=$rc sampled_peak_rss=${peak} KiB elapsed=$(( $(date +%s) - start ))s"
echo "-- lint output:"; cat "$B/prefix-lint.out"
pgrep -x shellcheck >/dev/null && echo "LEFTOVER shellcheck" || echo "no shellcheck left running"
