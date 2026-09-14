# Drive the wake library's process identity on Git Bash with live processes.
W=$1
FIX=$(mktemp -d "${TMPDIR:-/tmp}/nm-identity.XXXXXX")
export FM_STATE_OVERRIDE="$FIX/state" FM_DATA_OVERRIDE="$FIX/data" FM_CONFIG_OVERRIDE="$FIX/config"
mkdir -p "$FM_STATE_OVERRIDE"
. "$W/bin/fm-wake-lib.sh"
say() { printf '$ %s\n' "$*"; }
say "uname -s   ->  $(uname -s)"
sleep 60 & a=$!
say "sleep 60 &   # process A, MSYS pid $a"
say "ps -p $a -o lstart= -o command=   # the spelling bin/fm-pending-reply-lib.sh and bin/fm-remote-job-lib.sh used before this branch"
ps -p "$a" -o lstart= -o command= 2>&1; printf '[exit=%s]\n' "$?"
say "fm_pid_identity $a"
id_a1=$(fm_pid_identity "$a"); rc=$?; printf '%s\n[exit=%s]\n' "$id_a1" "$rc"
sleep 1
id_a2=$(fm_pid_identity "$a")
say "fm_pid_identity_equal <A re-read a second later> <A recorded>"
fm_pid_identity_equal "$id_a2" "$id_a1"; printf '[exit=%s]  (0 = same process)\n' "$?"
sleep 60 & b=$!
id_b=$(fm_pid_identity "$b")
say "sleep 60 &   # process B, MSYS pid $b; fm_pid_identity $b"
printf '%s\n' "$id_b"
say "fm_pid_identity_equal <B> <A recorded>   # a different live process must not match"
fm_pid_identity_equal "$id_b" "$id_a1"; printf '[exit=%s]  (1 = different process)\n' "$?"
say "fm_pid_start_identity $a ; fm_pid_start_identity_equal <A start re-read> <A start>"
sa1=$(fm_pid_start_identity "$a"); sa2=$(fm_pid_start_identity "$a"); printf '%s\n' "$sa1"
fm_pid_start_identity_equal "$sa2" "$sa1"; printf '[exit=%s]\n' "$?"
kill "$a" "$b"; wait "$a" "$b" 2>/dev/null
say "kill A B; fm_pid_identity $a   # a dead pid has no identity"
out=$(fm_pid_identity "$a" 2>&1); printf '%s[exit=%s]  (non-zero = gone)\n' "${out:+$out }" "$?"
rm -rf "$FIX"
