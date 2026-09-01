#!/usr/bin/env bash
# fm-jq-lib.sh - the single owner of `jq -r` reads whose answer can carry a
# newline that is not its last byte.
#
# Sourced, never executed. No dependencies beyond jq itself, so any caller can
# source it standalone.
#
#   fm_jq_rows <json> <jq-argument>...
#       Reads such an answer out of one JSON document, whether it arrives as many
#       rows or as one multi-line value. Byte-identical to the
#       `printf '%s' "$json" | jq -r "$@" 2>/dev/null` its call sites ran before -
#       same filter, same stdout, same exit status - except on a Windows
#       userland, where every CR text mode inserted ahead of a newline is removed.
#
# jq there is a native binary that opens stdout in TEXT mode, so it ends every
# record `\r\n` (measured on both builds present on the port machine, mingw-w64
# jq-1.6 and WinGet jq-1.8.2, so it is the platform and not a package; no mount
# option or shell flag suppresses it).
#
# Only an answer holding an interior newline needs this, which is why this is a
# funnel for those rather than for every jq call: command substitution drops the
# FINAL CRLF, so a single-line value is already exact on Windows and pays
# nothing. A multi-row read keeps the CR on every record but the last, and those
# records are ids that go straight back to a tool - `herdr tab close "w1:t2<CR>"`
# is not a tab id, `gh pr list --repo "acme/one<CR>"` is not a repository - or
# paths a shell then tests, where `[ -d "/tmp/a<CR>" ]` is false and the row
# silently disappears, or an operator-facing refusal that renders as `w1<CR> w7`.
# One multi-line VALUE is the same defect inside a single string: `.text` read
# from a cmux surface arrives with a CR ending every captured line but the last.
#
# Keyed on the userland rather than on jq being a native binary because unlike
# argument conversion this branch cannot change a correct answer: it is the exact
# inverse of the text mode translation, so against any jq that emits plain LF -
# every POSIX host, and any shell-script fake - it is a no-op on the byte stream.
#
# The `&& printf X` sentinel is what makes that exactness true rather than nearly
# true. Command substitution strips trailing newlines (and on MSYS the CR that
# comes with them), which would leave the last record's terminator unrecoverable
# and, worse, indistinguishable from a CR that is part of a VALUE - a jq answer
# of "1<CR>" arrives as the same bytes as a terminator a shell half-ate, and
# guessing wrong there silently rewrites data. With the sentinel the capture is
# jq's byte stream exactly, terminator included, and `\r\n` -> `\n` is all that
# is needed. jq -r always terminates its last record, so the byte before the
# sentinel is always the newline jq wrote. `&&` rather than a status variable so
# a failing jq still returns ITS status; the partial rows it may have printed are
# dropped, which every caller that checks the status treats as fatal anyway.
set -u

fm_jq_rows() {  # <json> <jq-argument>...
  local json=${1-} rows
  shift
  case "${OSTYPE:-}" in
    msys*|mingw*|cygwin*) ;;
    *)
      printf '%s' "$json" | jq -r "$@" 2>/dev/null
      return
      ;;
  esac
  rows=$(printf '%s' "$json" | jq -r "$@" 2>/dev/null && printf X) || return
  rows=${rows%X}
  printf '%s' "${rows//$'\r'$'\n'/$'\n'}"
}
