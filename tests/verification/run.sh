#!/usr/bin/env bash
# Run every verification script and summarize.
#
#   tests/verification/run.sh [<name>...]
#
# With no arguments it runs them all. Each script is independent, builds its own
# throwaway home, and cleans up after itself, so a failure in one says nothing
# about the others. Exit status is the number of scripts that failed, capped at
# 125; a script that skipped is not a failure.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -gt 0 ]; then
  scripts=$(for n in "$@"; do printf '%s\n' "$HERE/${n%.verify.sh}.verify.sh"; done)
else
  scripts=$(find "$HERE" -maxdepth 1 -name '*.verify.sh' | LC_ALL=C sort)
fi

failed=0 passed=0 skipped=0
for s in $scripts; do
  name=$(basename "$s" .verify.sh)
  printf '\n=== %s\n' "$name"
  bash "$s"
  case "$?" in
    0)  passed=$((passed + 1)) ;;
    77) skipped=$((skipped + 1)) ;;
    *)  failed=$((failed + 1)) ;;
  esac
done

printf '\n%s\n' "-----------------------------------------"
printf 'verification: %d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
[ "$failed" -eq 0 ] || exit $(( failed > 125 ? 125 : failed ))
