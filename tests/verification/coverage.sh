#!/usr/bin/env bash
# Measure which bin/ scripts the verification suite really runs.
#
#   tests/verification/coverage.sh [<name>...]
#
# A claim that a feature is covered is only as good as the evidence that its
# code ran. This runs each verification script with a BASH_ENV hook that records
# every bash script the run starts, then reports, for every script under bin/:
#
#   real   yes when a verification script executed it (or, for a sourced
#          library, executed a script that sources it), and which ones did
#   test   how many suites under tests/ name it
#
# It writes coverage.tsv and a summary beside the other evidence. With no
# arguments it runs every script, which takes as long as the suite does.
#
# Exit status is 0 when the measurement completed. It reports; it does not
# judge. bin/fm-feature-coverage.sh is the gate that reads the result.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${VERIFY_ARTIFACT_DIR:-${TMPDIR:-/tmp}/fm-verification-artifacts}/coverage"
mkdir -p "$OUT/trace" || exit 1

if [ "$#" -gt 0 ]; then
  names=$(for n in "$@"; do printf '%s\n' "${n%.verify.sh}"; done)
else
  names=$(find "$HERE" -maxdepth 1 -name '*.verify.sh' | LC_ALL=C sort | sed 's|.*/||; s|\.verify\.sh$||')
fi

HOOK="$OUT/trace/hook.sh"
# shellcheck disable=SC2016 # the hook expands these in the traced shell, not here
printf '%s\n' '[ -z "${FM_VERIFY_TRACE:-}" ] || printf "%s\n" "$0" >> "$FM_VERIFY_TRACE"' > "$HOOK"

for name in $names; do
  : > "$OUT/trace/$name.raw"
  printf '=== %s\n' "$name"
  BASH_ENV="$HOOK" FM_VERIFY_TRACE="$OUT/trace/$name.raw" bash "$HERE/run.sh" "$name" | tail -3
  sed -n "s|^.*/bin/\(backends/\)\{0,1\}\(fm-[^/]*\.sh\)$|\1\2|p; s|^.*/bin/backends/\([^/]*\.sh\)$|backends/\1|p" \
    "$OUT/trace/$name.raw" | LC_ALL=C sort -u > "$OUT/trace/$name.ran"
done

# A library is never executed, only sourced. It counts as really run when a
# script that ran names it, followed until nothing new is added.
for name in $names; do
  ran="$OUT/trace/$name.ran"
  while :; do
    before=$(wc -l < "$ran")
    while IFS= read -r script; do
      [ -f "$ROOT/bin/$script" ] || continue
      grep -o 'fm-[a-z0-9-]*-lib\.sh' "$ROOT/bin/$script" 2>/dev/null
    done < "$ran" > "$ran.libs"
    LC_ALL=C sort -u "$ran" "$ran.libs" > "$ran.next"
    mv "$ran.next" "$ran"
    [ "$(wc -l < "$ran")" -gt "$before" ] || break
  done
done

# Report over every trace this evidence directory holds, not only the scripts
# measured just now, so one slow or opt-in script can be measured by itself
# and added to an earlier run.
names=$(find "$OUT/trace" -maxdepth 1 -name '*.ran' | LC_ALL=C sort | sed 's|.*/||; s|\.ran$||')

TSV="$OUT/coverage.tsv"
printf 'script\tkind\treal\trun_by\ttests_naming_it\n' > "$TSV"
total=0 real=0 tested=0 neither=0
for path in "$ROOT"/bin/*.sh "$ROOT"/bin/backends/*.sh; do
  script=${path#"$ROOT/bin/"}
  base=$(basename "$script")
  case "$base" in *-lib.sh) kind=library ;; *) kind=entry ;; esac
  by=$(for name in $names; do
    grep -qxF -e "$script" -e "$base" "$OUT/trace/$name.ran" 2>/dev/null && printf '%s ' "$name"
  done)
  tests=$(grep -lF -- "$base" "$ROOT"/tests/*.test.sh 2>/dev/null | wc -l | tr -d ' ')
  total=$((total + 1))
  if [ -n "$by" ]; then real=$((real + 1)); ran=yes; else ran=no; fi
  [ "$tests" -eq 0 ] || tested=$((tested + 1))
  if [ -z "$by" ] && [ "$tests" -eq 0 ]; then neither=$((neither + 1)); fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$script" "$kind" "$ran" "${by% }" "$tests" >> "$TSV"
done

{
  printf 'code %s\n' "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  printf 'verification scripts measured: %s\n' "$(printf '%s\n' "$names" | wc -l | tr -d ' ')"
  printf 'bin scripts: %d\n' "$total"
  printf 'really run by a verification script: %d\n' "$real"
  printf 'named by at least one suite under tests/: %d\n' "$tested"
  printf 'neither run for real nor named by any suite: %d\n' "$neither"
} | tee "$OUT/summary.txt"
printf '# evidence: %s\n' "$OUT"
