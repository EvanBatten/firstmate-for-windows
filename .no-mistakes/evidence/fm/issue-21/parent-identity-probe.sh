#!/usr/bin/env bash
# Probe for issue #21: does a COPY of bash named cursor-agent hold its identity
# as the adapter's parent, as read by the REAL Cursor ancestry classifier in
# bin/fm-session-lock-lib.sh, on this box? Mirrors the suite's PARK_CHILD shape:
# the fake harness writes its own $$ into state/.lock, then runs a child that
# stands in for the adapter and reports what the classifier sees.
#   usage: parent-identity-probe.sh <repo-root>
set -u
ROOT=$1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-issue21-probe.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/fakebin" "$TMP/linkbin" "$TMP/state"

printf '== host ==\n%s\n%s\ncc=%s gcc=%s\n\n' "$(uname -a)" "$(bash --version | head -1)" \
  "$(command -v cc || echo none)" "$(command -v gcc || echo none)"

cp "$(command -v bash)" "$TMP/fakebin/cursor-agent" || { echo "copy failed"; exit 1; }
FAKE="$TMP/fakebin/cursor-agent"
printf '== fake harness ==\n'; ls -l "$FAKE"; printf 'copy vs bash: '
cmp -s "$FAKE" "$(command -v bash)" && echo "byte-identical" || echo "DIFFERENT"
echo

# The stand-in adapter: source the real lock lib and report the parent's identity.
cat > "$TMP/child.sh" <<EOF
#!/usr/bin/env bash
. "$ROOT/bin/fm-session-lock-lib.sh"
fm_proc_chain_prime "\$\$"
comm=\$(fm_proc_comm "\$PPID") || comm='<unreadable>'
args=\$(fm_proc_args "\$PPID")
printf '  child pid=%s ppid=%s\n' "\$\$" "\$PPID"
printf '  parent comm=%s\n' "\$comm"
printf '  parent args=%s\n' "\$args"
if fm_harness_process_matches "\$comm" "\$args"; then
  printf '  classifier: parent IS a verified harness\n'
else
  printf '  classifier: parent is NOT a harness\n'
fi
printf '  lock pid=%s\n' "\$(cat "$TMP/state/.lock" 2>/dev/null)"
printf '  harness ancestry pids: %s\n' "\$(fm_harness_ancestry_pids 2>/dev/null | tr '\n' ' ')"
if fm_session_lock_owned_by_self "$TMP/state"; then
  printf '  fm_session_lock_owned_by_self: YES\n'
else
  printf '  fm_session_lock_owned_by_self: NO\n'
fi
exit 3
EOF
chmod +x "$TMP/child.sh"

echo '== case A: copy of bash, body ends in exit "$?" (the suite shape) =='
"$FAKE" -c "printf '%s\n' \"\$\$\" > '$TMP/state/.lock'; '$TMP/child.sh'; exit \"\$?\""
printf '  fake harness exit status=%s (child exited 3)\n\n' "$?"

echo '== case B: copy of bash, NO exit guard (bash execs the final command) =='
: > "$TMP/state/.lock"
"$FAKE" -c "printf '%s\n' \"\$\$\" > '$TMP/state/.lock'; '$TMP/child.sh'"
printf '  fake harness exit status=%s (child exited 3)\n\n' "$?"

echo '== case C: exit status propagation through the guard =='
"$FAKE" -c 'bash -c "exit 0"; exit "$?"'; printf '  inner exit 0 -> %s\n' "$?"
"$FAKE" -c 'bash -c "exit 7"; exit "$?"'; printf '  inner exit 7 -> %s\n' "$?"
"$FAKE" -c 'bash -c "kill -TERM \$\$"; exit "$?"'; printf '  inner SIGTERM -> %s\n\n' "$?"

echo '== case D (informational): a real symlink named cursor-agent, guarded =='
if MSYS=winsymlinks:nativestrict ln -s "$(command -v bash)" "$TMP/linkbin/cursor-agent" 2>/dev/null \
   && [ -L "$TMP/linkbin/cursor-agent" ]; then
  ls -l "$TMP/linkbin/cursor-agent"
  : > "$TMP/state/.lock"
  "$TMP/linkbin/cursor-agent" -c "printf '%s\n' \"\$\$\" > '$TMP/state/.lock'; '$TMP/child.sh'; exit \"\$?\""
  printf '  fake harness exit status=%s\n' "$?"
else
  echo "  could not create a real symlink here (needs Developer Mode or SeCreateSymbolicLinkPrivilege); skipped"
fi
