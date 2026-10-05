#!/usr/bin/env bash
# inventory.sh - the behavior inventory: one row per behavior the product
# claims, and the fractional verdict a run actually proved.
#
# behaviors.tsv beside this script holds the table: id, source, behavior,
# status, ref, evidence. source names where the claim comes from (a README
# feature bullet, an AGENTS.md lifecycle step, a bin/ entry point coverage.tsv
# names, or a feature file under features/). status is one of proven,
# unproven, broken, or blocked-here; ref names the proof of a proven row,
# either a session script tests/verification/<ref>.verify.sh or a drive trace
# tools/fm-drive/traces/<ref>.json whose proves lists the row, which
# `node tools/fm-drive/drive.mjs record` writes from a run; any other row
# names an issue number.
#
# Usage:
#   inventory.sh check              exit 0 when every source above has a row
#                                    for every behavior it claims, otherwise
#                                    name each hole and exit 1
#   inventory.sh verdict <run.log>  read the log tests/verification/run.sh
#                                    printed and report the fraction of
#                                    behaviors that run actually proved
#
# check is what verify.sh doctor calls; a hole here is what makes a checkout
# not worth driving. verdict is what verify.sh run appends after the suite's
# own pass/fail/skip line: a proven row whose script did not pass this run
# counts against the behavior, never for it, so a skip can never read as
# proof.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)" || ROOT=
TSV="$HERE/behaviors.tsv"
COVERAGE="$ROOT/tests/verification/coverage.tsv"
FEATURES_DIR="$HERE/features"
README="$ROOT/README.md"
SUITE="$ROOT/tests/verification"
TRACES="$ROOT/tools/fm-drive/traces"

die() { printf 'inventory: %s\n' "$*" >&2; exit 2; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

[ -n "$ROOT" ] || die "$HERE is not inside a git checkout"
[ -f "$TSV" ] || die "no behaviors table at $TSV"

BAD=0
n_ok()  { printf 'ok - %s\n' "$1"; }
n_bad() { printf 'not ok - %s\n' "$1"; BAD=$((BAD + 1)); }

# A JSON string cannot hold an unescaped quote, so the first "proves" key
# opens the trace's proves object, and its keys are row ids with no braces.
trace_proves() {
  case "$1" in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac
  [ -f "$TRACES/$1.json" ] || return 1
  awk -v want="$2" '
    { text = text $0 }
    END {
      if (!match(text, /"proves"[ \t\r]*:[ \t\r]*\{[^}]*\}/)) exit 1
      body = substr(text, RSTART, RLENGTH)
      sub(/^"proves"[ \t\r]*:[ \t\r]*\{/, "", body)
      n = split(body, pairs, ",")
      for (i = 1; i <= n; i++) {
        key = pairs[i]
        sub(/^[ \t\r]*"/, "", key)
        sub(/"[ \t\r]*:.*$/, "", key)
        if (key == want) exit 0
      }
      exit 1
    }' "$TRACES/$1.json"
}

# record writes "<sha> held through step <n>, ..." as a trace-proven row's
# evidence, so that row's ref names a trace even when a session script
# shares the name.
recorded_by_trace() {
  [[ $1 =~ ^[0-9a-f]{40}\ held\ through\ step\ [0-9]+, ]]
}

row_source_exists() {
  awk -F'\t' -v want="$1" 'NR>1 && $2==want{f=1} END{exit !f}' "$TSV"
}

cmd_check() {
  BAD=0
  [ -f "$COVERAGE" ] || die "no coverage table at $COVERAGE"
  [ -d "$FEATURES_DIR" ] || die "no features directory at $FEATURES_DIR"
  [ -f "$README" ] || die "no README.md at $README"

  local script kind
  while IFS=$'\t' read -r script kind _rest; do
    [ "$kind" = entry ] || continue
    row_source_exists "bin:$script" \
      || n_bad "coverage.tsv names '$script' (kind=entry) with no bin:$script row"
  done < <(tail -n +2 "$COVERAGE")

  local f name
  for f in "$FEATURES_DIR"/*.md; do
    [ -e "$f" ] || continue
    name=$(basename "$f" .md)
    [ "$name" = README ] && continue
    row_source_exists "feature:$name" \
      || n_bad "features/$name.md has no feature:$name row"
  done

  local rows rname
  rows=$(awk -F'\t' 'NR>1 && $2 ~ /^feature:/{s=$2; sub(/^feature:/,"",s); print s}' "$TSV")
  for rname in $rows; do
    [ -f "$FEATURES_DIR/$rname.md" ] \
      || n_bad "behaviors.tsv row source feature:$rname names no features/$rname.md"
  done

  local readme_bullets readme_rows
  readme_bullets=$(awk '
    /^## Features$/ { infeat=1; next }
    /^## / { infeat=0 }
    infeat && /^- / { n++ }
    END { print n+0 }
  ' "$README")
  readme_rows=$(awk -F'\t' 'NR>1 && $2=="readme:features"{n++} END{print n+0}' "$TSV")
  [ "$readme_bullets" -eq "$readme_rows" ] \
    || n_bad "README.md has $readme_bullets '## Features' bullets but behaviors.tsv has $readme_rows readme:features rows"

  local dup_ids id
  dup_ids=$(awk -F'\t' 'NR>1{print $1}' "$TSV" | LC_ALL=C sort | uniq -d)
  for id in $dup_ids; do
    n_bad "duplicate id '$id'"
  done

  local status ref evidence
  while IFS=$'\t' read -r id _source _behavior status ref evidence; do
    case "$status" in
      proven | unproven | broken | blocked-here) ;;
      *) n_bad "row '$id' has an unknown status '$status'" ;;
    esac
    case "$status" in
      proven)
        if ! recorded_by_trace "$evidence" && [ -f "$SUITE/$ref.verify.sh" ]; then
          # A drive plays firstmate; only a real session proves a behavior.
          grep -q "session-lib.sh" "$SUITE/$ref.verify.sh" \
            || n_bad "row '$id' is proven by '$ref', which drives scripts itself instead of running a session; only a session script proves a behavior"
        else
          trace_proves "$ref" "$id" \
            || n_bad "row '$id' is proven but ref '$ref' names no tests/verification/$ref.verify.sh and no tools/fm-drive/traces/$ref.json that proves it"
        fi
        ;;
      unproven | broken)
        case "$ref" in
          '#'[0-9]*) ;;
          *) n_bad "row '$id' is $status but ref '$ref' is not an issue number (#NN)" ;;
        esac
        ;;
      blocked-here)
        [ "$ref" = '#97' ] || n_bad "row '$id' is blocked-here but ref '$ref' is not #97"
        ;;
    esac
  done < <(tail -n +2 "$TSV")

  local total proven_n unproven_n broken_n blocked_n
  total=$(tail -n +2 "$TSV" | wc -l | tr -d ' ')
  proven_n=$(awk -F'\t' 'NR>1 && $4=="proven"{n++} END{print n+0}' "$TSV")
  unproven_n=$(awk -F'\t' 'NR>1 && $4=="unproven"{n++} END{print n+0}' "$TSV")
  broken_n=$(awk -F'\t' 'NR>1 && $4=="broken"{n++} END{print n+0}' "$TSV")
  blocked_n=$(awk -F'\t' 'NR>1 && $4=="blocked-here"{n++} END{print n+0}' "$TSV")
  n_ok "inventory: $total behaviors, $proven_n proven, $unproven_n unproven, $broken_n broken, $blocked_n blocked here"

  [ "$BAD" -eq 0 ]
}

cmd_verdict() {
  local log=${1:-}
  [ -n "$log" ] || die "verdict needs a run log path"
  [ -f "$log" ] || die "no run log at $log"

  local total proven=0 unproven=0 broken=0 blocked=0
  total=$(tail -n +2 "$TSV" | wc -l | tr -d ' ')

  local id status ref evidence outcome
  while IFS=$'\t' read -r id _source _behavior status ref evidence; do
    case "$status" in
      proven)
        if recorded_by_trace "$evidence" || [ ! -f "$SUITE/$ref.verify.sh" ]; then
          # A trace-proven row's proof is the run record wrote, not this log.
          proven=$((proven + 1))
          continue
        fi
        outcome=$(awk -v want="$ref" '$1=="result:" && $2==want{o=$3} END{print (o=="" ? "missing" : o)}' "$log")
        case "$outcome" in
          passed) proven=$((proven + 1)) ;;
          failed) broken=$((broken + 1)) ;;
          *)      unproven=$((unproven + 1)) ;;
        esac
        ;;
      unproven) unproven=$((unproven + 1)) ;;
      broken)   broken=$((broken + 1)) ;;
      blocked-here) blocked=$((blocked + 1)) ;;
    esac
  done < <(tail -n +2 "$TSV")

  printf 'proven %d of %d behaviors; %d unproven; %d broken; %d blocked here\n' \
    "$proven" "$total" "$unproven" "$broken" "$blocked"
}

case "${1:-}" in
  check)   shift; cmd_check ;;
  verdict) shift; cmd_verdict "${1:-}" ;;
  *)       usage >&2; exit 2 ;;
esac
