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

ok()   { printf 'ok - %s\n' "$1"; }
bad()  { printf 'not ok - %s\n' "$1"; VERIFY_FAILURES=$((VERIFY_FAILURES + 1)); }

# verify_that <description> <command...>: run it, report, keep going.
verify_that() {
  local what=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi
}

verify_done() {
  if [ "$VERIFY_FAILURES" -eq 0 ]; then
    printf '# %s: all checks passed\n' "$VERIFY_NAME"
    exit 0
  fi
  printf '# %s: %d check(s) failed\n' "$VERIFY_NAME" "$VERIFY_FAILURES"
  exit 1
}

# verify_skip <reason>: this machine cannot answer the question. Not a failure.
verify_skip() { printf 'skip: %s\n' "$1"; exit 77; }
