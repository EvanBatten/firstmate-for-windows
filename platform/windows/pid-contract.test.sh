#!/usr/bin/env bash
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1

pid_checks() {
  grep -HE 'kill[[:space:]]+(-0|-s[[:space:]]+0)|(^|[^[:alnum:]_./-])ps[[:space:]]|"\$[[:alnum:]_]*"[[:space:]]+-(p|axo|ax|eo|Ao)[[:space:]]|/proc/|proc_root/|fm_pid_alive|fm_pid_identity|fm_harness_pid_alive' \
    bin/*.sh bin/backends/*.sh |
    awk '{
      f = $0; sub(/:.*/, "", f); c = $0; sub(/^[^:]*:/, "", c)
      sub(/^[[:space:]]+/, "", c); gsub(/\t/, " ", c)
      if (c ~ /^#/ || c ~ /^[[:alnum:]_]+[[:space:]]*\(\)/) next
      if (c !~ /kill[[:space:]]+(-0|-s[[:space:]]+0)|-p([[:space:]]|$)|-(axo|ax|eo|Ao)([[:space:]]|$)|-[Ae][[:space:]]+-o|\/proc\/|proc_root\/|fm_pid_alive|fm_pid_identity|fm_harness_pid_alive/) next
      print f "\t" c
    }' | sort
}

registry=platform/windows/pid-sites.tsv
fails=0
bad=$(awk -F'\t' 'NR > 1 && $2 !~ /^(live|recorded|native-(claude|herdr|pi|tasks-axi))$/ {print NR": "$0}' "$registry")
[ -z "$bad" ] || { printf 'not ok - unknown kind in %s:\n%s\n' "$registry" "$bad"; fails=1; }
diff=$(diff <(awk -F'\t' 'NR > 1 {print $1 "\t" $3}' "$registry" | sort) <(pid_checks))
if [ -n "$diff" ]; then
  printf 'not ok - pid checks in bin/ differ from %s (> is new upstream, < is gone):\n%s\n' "$registry" "$diff"
  printf '%s\n' "Classify each new check by the pid it reads: live (this process, or a walk it is doing now)," \
    "recorded (firstmate wrote it from \$\$, \$!, BASHPID or the harness walk, so it is an MSYS pid)," \
    "or native-<writer> (a native program wrote a Win32 pid, which fm_win_msys_pid must translate first)."
  fails=1
else
  printf 'ok - every pid check in bin/ is classified (%s)\n' "$(($(wc -l < "$registry") - 1))"
fi
[ "$fails" -eq 0 ]
