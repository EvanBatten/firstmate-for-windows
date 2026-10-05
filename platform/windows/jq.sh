# shellcheck shell=bash
# Sourced by env.sh and bash-env.sh with the overlay's bin directory.
#
# bin/jq adds -b to every jq call, but it is a script, so each call starts one
# more bash, and a spawn makes over a hundred jq calls. A bash that finds a
# real jq on PATH gets this function instead, which adds the same -b without
# that bash. With no real jq on PATH no function is defined, so `command -v jq`
# still answers as it would. Scanning PATH costs about 18 ms here, so the
# answer and the PATH it came from are exported for every child with the same
# PATH to reuse.

_FM_WIN_JQ_SELF=$1

_fm_win_jq_resolve() {
  local d dirs
  FM_WIN_JQ_BIN=
  FM_WIN_JQ_PATH=$PATH
  IFS=: read -r -a dirs <<< "$PATH"
  for d in "${dirs[@]}"; do
    [ -n "$d" ] && [ -x "$d/jq" ] && [ ! "$d" -ef "$_FM_WIN_JQ_SELF" ] && FM_WIN_JQ_BIN=$d/jq && break
  done
  export FM_WIN_JQ_BIN FM_WIN_JQ_PATH
}

[ "$PATH" = "${FM_WIN_JQ_PATH-}" ] || _fm_win_jq_resolve
if [ -n "$FM_WIN_JQ_BIN" ]; then
  jq() {
    [ "$PATH" = "$FM_WIN_JQ_PATH" ] || _fm_win_jq_resolve
    [ -n "$FM_WIN_JQ_BIN" ] || { echo "jq: not found on PATH" >&2; return 127; }
    "$FM_WIN_JQ_BIN" -b "$@"
  }
fi
