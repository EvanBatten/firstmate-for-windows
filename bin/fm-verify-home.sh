#!/usr/bin/env bash
# Public command for throwaway / verify-home safe auto-answers.
# Usage:
#   fm-verify-home.sh seed [--home DIR]
#   fm-verify-home.sh active [--home DIR]
#   fm-verify-home.sh classify
#
# `seed` writes the marker, Claude trust/skip-permissions flags, and
# captain.md (pre-grant land) when that file is absent.
# `active` exits 0 when this home is a verify home and 1 otherwise.
# `classify` reads pane text from stdin and prints one class:
#   trust-yes, background-work-enter, ask-user, blocked, or none.
# --home overrides FM_HOME for one invocation. bin/fm-verify-home-lib.sh
# owns detection, artifact bytes, and the classifier.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-verify-home-lib.sh
. "$SCRIPT_DIR/fm-verify-home-lib.sh"

usage() {
  sed -n '2,15{s/^# \{0,1\}//;p;}' "$0"
}

HOME_ARG=
CMD=
while [ "$#" -gt 0 ]; do
  case "$1" in
    seed|active|classify)
      if [ -n "$CMD" ]; then
        printf 'fm-verify-home: unexpected extra command: %s\n' "$1" >&2
        exit 2
      fi
      CMD=$1
      shift
      ;;
    --home)
      HOME_ARG=${2:-}
      if [ "$#" -ge 2 ]; then shift 2; else shift; fi
      ;;
    --home=*)
      HOME_ARG=${1#--home=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'fm-verify-home: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$CMD" ]; then
  usage >&2
  exit 2
fi

if [ -z "$HOME_ARG" ]; then
  HOME_ARG=${FM_HOME:-}
fi

case "$CMD" in
  seed)
    fm_verify_home_seed "$HOME_ARG"
    ;;
  active)
    fm_verify_home_active "$HOME_ARG"
    ;;
  classify)
    fm_verify_home_classify "$(cat)"
    ;;
esac
