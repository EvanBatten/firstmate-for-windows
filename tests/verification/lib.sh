# shellcheck shell=bash
# Shared helpers for the verification suite.
#
# These scripts are a different class from tests/*.test.sh. A test there pins a
# contract with fakes and must pass on any machine. A script here answers "does
# this feature actually work on THIS installation", by running the real bin/
# scripts against a real throwaway home. That is why they live in their own
# directory with their own entry point instead of joining the portable lanes:
# they are meant to be run by hand on a machine someone is about to trust.
#
# Each script covers exactly one feature, builds its own home, and cleans up.

set -u

VERIFY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY_NAME=$(basename "${BASH_SOURCE[1]:-verification}" .verify.sh)
VERIFY_FAILURES=0
VERIFY_TMP=

verify_cleanup() {
  [ -z "$VERIFY_TMP" ] || rm -rf -- "$VERIFY_TMP"
}
trap verify_cleanup EXIT

# verify_home: build a throwaway firstmate home with the backlog config a real
# one has. It SETS VERIFY_TMP and VERIFY_HOME rather than printing the path,
# because a caller writing `h=$(verify_home)` would run it in a subshell and
# lose VERIFY_TMP - which then silently resolves every path built from it to
# the filesystem root, and takes the cleanup trap with it.
VERIFY_HOME=
verify_home() {
  VERIFY_TMP=${VERIFY_TMP:-$(mktemp -d "${TMPDIR:-/tmp}/fm-verify-$VERIFY_NAME.XXXXXX")}
  VERIFY_HOME="$VERIFY_TMP/home"
  mkdir -p "$VERIFY_HOME/data" "$VERIFY_HOME/state" "$VERIFY_HOME/config" "$VERIFY_HOME/projects"
  cp "$VERIFY_ROOT/.tasks.toml" "$VERIFY_HOME/.tasks.toml"
}

# Artifacts. A run that only prints to a terminal leaves nothing to inspect an
# hour later, so every script keeps its evidence on disk: a transcript of what
# it checked, plus any files it was told to keep. VERIFY_ARTIFACT_DIR moves
# where they land.
VERIFY_ARTIFACTS=${VERIFY_ARTIFACT_DIR:-${TMPDIR:-/tmp}/fm-verification-artifacts}
VERIFY_ARTIFACT_RUN="$VERIFY_ARTIFACTS/$VERIFY_NAME"
mkdir -p "$VERIFY_ARTIFACT_RUN" 2>/dev/null || true
VERIFY_TRANSCRIPT="$VERIFY_ARTIFACT_RUN/transcript.txt"
: > "$VERIFY_TRANSCRIPT" 2>/dev/null || VERIFY_TRANSCRIPT=/dev/null
{
  printf '# %s
' "$VERIFY_NAME"
  printf '# run %s
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '# code %s

' "$(git -C "$VERIFY_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
} >> "$VERIFY_TRANSCRIPT"

# verify_keep <label> <file>: keep a copy of evidence beside the transcript.
verify_keep() {
  [ -e "$2" ] || return 0
  cp -f "$2" "$VERIFY_ARTIFACT_RUN/$1" 2>/dev/null || true
  printf 'kept %s
' "$1" >> "$VERIFY_TRANSCRIPT"
}

# verify_note <text>: context for the transcript, neither pass nor failure.
verify_note() { printf '     %s
' "$*" >> "$VERIFY_TRANSCRIPT"; }

ok()   { printf 'ok - %s
' "$1"; printf 'ok   %s
' "$1" >> "$VERIFY_TRANSCRIPT"; }
bad()  { printf 'not ok - %s
' "$1"; printf 'FAIL %s
' "$1" >> "$VERIFY_TRANSCRIPT"; VERIFY_FAILURES=$((VERIFY_FAILURES + 1)); }

# verify_that <description> <command...>: run it, report, keep going.
verify_that() {
  local what=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi
}

verify_done() {
  if [ "$VERIFY_FAILURES" -eq 0 ]; then
    printf '# %s: all checks passed\n' "$VERIFY_NAME"
    printf '# evidence: %s
' "$VERIFY_ARTIFACT_RUN"
    exit 0
  fi
  printf '# %s: %d check(s) failed\n' "$VERIFY_NAME" "$VERIFY_FAILURES"
  printf '# evidence: %s
' "$VERIFY_ARTIFACT_RUN"
  exit 1
}

# verify_skip <reason>: this machine cannot answer the question. Not a failure.
verify_skip() { printf 'skip: %s\n' "$1"; exit 77; }
