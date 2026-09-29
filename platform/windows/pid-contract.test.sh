#!/usr/bin/env bash
# The overlay keeps one pid space: every pid firstmate records is an MSYS pid,
# which upstream's kill -0, /proc and ps checks read correctly (see proc.sh).
# That holds only while each upstream check reads a pid of a known kind, so
# every check in bin/ is listed in pid-sites.tsv with the kind of pid it reads:
#   live      a pid of this process or a walk it is doing now
#   recorded  a pid firstmate wrote from $$, $!, BASHPID or its harness walk
#   native-*  a pid a native program wrote, which is Win32 and must be
#             translated with fm_win_msys_pid before an MSYS check reads it
# A check upstream adds, moves or rewrites fails here until it is classified.
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
  fails=1
else
  printf 'ok - every pid check in bin/ is classified (%s)\n' "$(($(wc -l < "$registry") - 1))"
fi
[ "$fails" -eq 0 ]
