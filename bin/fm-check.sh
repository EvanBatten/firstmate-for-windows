#!/usr/bin/env bash
# fm-check.sh - the one command that says whether this tree breaks a rule.
#
# Everything here can be known without running firstmate. Driving the real
# scripts against a real home is the verify-firstmate skill's job, not this
# one's. CI and the tracked pre-push hook both call this command, so a rule
# cannot hold in one place and not the other.
#
# Usage:
#   fm-check.sh                 run every static layer
#   fm-check.sh --tests         also run the suites the branch's changes map to
#   fm-check.sh --list          print the layers in order, run nothing
#   fm-check.sh --install-hook  point this clone's hooks at .githooks/
#   fm-check.sh --help          print this usage
#
# Layers run cheapest first and the run stops at the first one that fails,
# naming it. Each layer is an existing single owner; this script adds the
# order and the stop, not a second definition of any rule.
#
#   syntax  bash -n over the shell files the lint layer will cover
#   docs    bin/fm-doc-audience-check.sh: every prose file classified, links resolve
#   lint    bin/fm-lint.sh: pinned ShellCheck, workflow lint, repository invariants
#   tests   bin/fm-test-run.sh --changed, only with --tests
#
# The lint layer decides the file set: the files a branch changed against the
# repository's default branch locally, the full canonical set in CI and on the
# default branch. The syntax layer follows it, so both cover the same files.
#
# Exit status: 0 every layer passed, 1 a layer failed, 2 bad usage.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
cd "$ROOT" || exit 1

usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

WITH_TESTS=0
case "${1:-}" in
  '') ;;
  --tests) WITH_TESTS=1 ;;
  --list) printf '%s\n' syntax docs lint; printf '%s\n' 'tests (with --tests)'; exit 0 ;;
  --install-hook)
    git config core.hooksPath .githooks || exit 1
    printf 'fm-check: this clone now runs .githooks/pre-push before every push\n'
    exit 0 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

layer_syntax() {
  local script failed=0
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    bash -n "$script" || failed=1
  done < <(bin/fm-lint.sh --list-files)
  return "$failed"
}

layer_docs() { bin/fm-doc-audience-check.sh; }
layer_lint() { bin/fm-lint.sh; }
layer_tests() { bin/fm-test-run.sh --changed; }

layers=(syntax docs lint)
[ "$WITH_TESTS" -eq 0 ] || layers+=(tests)

for layer in "${layers[@]}"; do
  printf '== %s\n' "$layer"
  if ! "layer_$layer"; then
    printf 'fm-check: FAILED at the %s layer; later layers were not run\n' "$layer" >&2
    exit 1
  fi
done
printf 'fm-check: ok (%s)\n' "${layers[*]}"
