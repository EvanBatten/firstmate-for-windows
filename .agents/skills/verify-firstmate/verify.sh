#!/usr/bin/env bash
# Entry point for the verify-firstmate skill.
#
#   verify.sh doctor              read-only: is this checkout worth driving?
#   verify.sh list                names of the features that can be driven
#   verify.sh run [<feature>...]  drive them and keep the evidence (default: all)
#
# The suite it drives is tests/verification/, whose README owns the contract
# every script keeps. This wrapper adds what an agent in one of several parallel
# worktrees needs on top of it: a doctor that writes nothing, and an evidence
# directory derived from the worktree and the run, so two worktrees, or a
# baseline and a treatment run in the same worktree, never share a transcript.
#
# Everything is resolved from the worktree that holds THIS file, not from the
# caller's working directory, so the code that is driven is the code beside it.
#
# Environment:
#   VERIFY_EVIDENCE_ROOT  where evidence is kept. Default:
#                         ${TMPDIR:-/tmp}/fm-verification-artifacts, which is
#                         outside every worktree and so survives their cleanup.
#
# Exit status: doctor 0 worth driving, 1 not. run passes through the suite's own
# status (the number of failed scripts), or 2 when nothing was driven.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)" || ROOT=
SUITE="$ROOT/tests/verification"

die() { printf 'verify: %s\n' "$*" >&2; exit 2; }

[ -n "$ROOT" ] || die "$HERE is not inside a git checkout"

# One directory per worktree: the name keeps it readable, the checksum of the
# full path keeps two worktrees with the same basename apart.
evidence_root() {
  local key
  key="$(basename "$ROOT")-$(printf '%s' "$ROOT" | cksum | cut -d' ' -f1)"
  printf '%s/%s' "${VERIFY_EVIDENCE_ROOT:-${TMPDIR:-/tmp}/fm-verification-artifacts}" "$key"
}

features() {
  local f
  for f in "$SUITE"/*.verify.sh; do
    [ -e "$f" ] || continue
    basename "$f" .verify.sh
  done
}

DOCTOR_BAD=0
d_ok()   { printf 'ok - %s\n' "$1"; }
d_warn() { printf 'warn - %s\n' "$1"; }
d_bad()  { printf 'not ok - %s\n' "$1"; DOCTOR_BAD=$((DOCTOR_BAD + 1)); }

cmd_doctor() {
  local tool dirty tmp var f b leaked=
  DOCTOR_BAD=0

  if [ -f "$SUITE/run.sh" ] && [ -f "$SUITE/lib.sh" ] && [ -d "$ROOT/bin" ]; then
    d_ok "the suite and the scripts it drives are here: $ROOT"
  else
    d_bad "no tests/verification/ suite in $ROOT, so there is nothing to drive from this checkout"
  fi

  if [ "$(git -C "$ROOT" rev-parse --git-dir)" = "$(git -C "$ROOT" rev-parse --git-common-dir)" ]; then
    d_warn "this is the primary checkout: driving it is safe, changing code in it is not"
  else
    d_ok "this is a linked worktree"
  fi

  # The feature map is the recipe for every drive, so a script with no feature
  # file, or a feature file with no script, is a hole in the proof.
  local mapped scripted unmapped
  mapped=$(for f in "$HERE"/features/*.md; do b=$(basename "$f" .md); [ "$b" = README ] || printf '%s
' "$b"; done | LC_ALL=C sort)
  scripted=$(features | LC_ALL=C sort)
  if [ "$mapped" = "$scripted" ]; then
    d_ok "every verification script has a feature file, and every feature file a script"
  else
    unmapped=$(printf '%s
%s
' "$mapped" "$scripted" | LC_ALL=C sort | uniq -u | tr '
' ' ')
    d_bad "the feature map and the scripts disagree about: $unmapped"
  fi

  # The inventory is the unit of truth this doctor enforces: a bin/ script,
  # a feature file, or a README bullet with no row is a hole in the proof,
  # and it refuses the checkout the same way a missing feature file does.
  local inv_out inv_line
  if [ -x "$HERE/inventory.sh" ]; then
    inv_out=$(bash "$HERE/inventory.sh" check 2>&1)
    while IFS= read -r inv_line; do
      case "$inv_line" in
        'ok - '*)     d_ok "${inv_line#ok - }" ;;
        'not ok - '*) d_bad "${inv_line#not ok - }" ;;
      esac
    done <<< "$inv_out"
  else
    d_bad "no inventory.sh beside this doctor, so the behavior table cannot be checked"
  fi

  dirty=$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$dirty" -eq 0 ]; then
    d_ok "code under test: $(git -C "$ROOT" rev-parse --short HEAD) ($(git -C "$ROOT" rev-parse --abbrev-ref HEAD)), clean"
  else
    d_warn "code under test: $(git -C "$ROOT" rev-parse --short HEAD) plus $dirty uncommitted path(s); run records them in code.txt because the commit alone does not describe this code"
  fi

  if [ -L "$ROOT/.claude/skills" ] && [ -d "$ROOT/.claude/skills" ]; then
    d_ok "the harness skill link resolves"
  else
    d_warn "the harness skill link does not resolve to a directory, so a Claude session here has no skills; clone with core.symlinks=true"
  fi

  for tool in git mktemp awk sed grep; do
    command -v "$tool" >/dev/null 2>&1 || d_bad "$tool is missing, and every script needs it"
  done
  command -v tasks-axi >/dev/null 2>&1 \
    || d_warn "tasks-axi is missing: captain-decision will skip, and a skip proves nothing"
  for tool in herdr jq timeout; do
    command -v "$tool" >/dev/null 2>&1 \
      || d_warn "$tool is missing: herdr-lab-pane will skip, and a skip proves nothing"
  done

  tmp=${TMPDIR:-/tmp}
  if [ -d "$tmp" ] && [ -w "$tmp" ]; then
    d_ok "throwaway homes can be built under $tmp"
  else
    d_bad "$tmp is not a writable directory, so no throwaway home can be built"
  fi

  if [ -n "${FM_HOME:-}" ]; then
    d_ok "the caller's home ($FM_HOME) is not driven: every script replaces it with its own throwaway home"
  fi
  for var in $(compgen -v | grep -E '^FM_[A-Z0-9_]*_OVERRIDE$'); do
    leaked="$leaked $var"
  done
  [ -z "$leaked" ] \
    || d_ok "the caller sets$leaked, which would win over a throwaway home; tests/verification/lib.sh clears them before a script drives anything"
  [ -z "${HERDR_ENV:-}" ] \
    || d_ok "inside a live herdr session: herdr-lab-pane drives its own fm-lab-* session through bin/fm-herdr-lab.sh and never this one"

  if [ "$DOCTOR_BAD" -eq 0 ]; then
    printf '# doctor: worth driving\n'
    return 0
  fi
  printf '# doctor: not worth driving, %d problem(s)\n' "$DOCTOR_BAD"
  return 1
}

cmd_run() {
  local name run_dir sha status
  for name in "$@"; do
    [ -f "$SUITE/${name%.verify.sh}.verify.sh" ] \
      || die "no feature named '$name'. Known: $(features | tr '\n' ' ')"
  done

  sha=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
  run_dir="$(evidence_root)/$(date -u +%Y%m%dT%H%M%SZ)-$sha-$$"
  mkdir -p "$run_dir" || die "cannot create $run_dir"

  if ! cmd_doctor > "$run_dir/doctor.txt" 2>&1; then
    cat "$run_dir/doctor.txt"
    die "doctor refused this checkout, so nothing was driven. Evidence: $run_dir"
  fi

  {
    printf 'root    %s\n' "$ROOT"
    printf 'branch  %s\n' "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    printf 'commit  %s\n' "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"
    printf '\n# uncommitted paths\n'
    git -C "$ROOT" status --porcelain 2>/dev/null
    printf '\n# uncommitted diff\n'
    git -C "$ROOT" diff HEAD 2>/dev/null
  } > "$run_dir/code.txt"

  VERIFY_ARTIFACT_DIR="$run_dir" bash "$SUITE/run.sh" "$@" 2>&1 | tee "$run_dir/run.log"
  status=${PIPESTATUS[0]}
  bash "$HERE/inventory.sh" verdict "$run_dir/run.log" | tee -a "$run_dir/run.log"
  printf '# evidence: %s\n' "$run_dir"
  return "$status"
}

case "${1:-}" in
  doctor) shift; cmd_doctor ;;
  list)   features ;;
  run)    shift; cmd_run "$@" ;;
  *)      sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 2 ;;
esac
