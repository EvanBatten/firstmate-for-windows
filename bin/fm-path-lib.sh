#!/usr/bin/env bash
# fm-path-lib.sh - fork-free pathname helpers with no source-time side effects,
# so read-only callers can load them without any library's state setup.
#
# Each assigns <output-variable> exactly what `$(dirname -- <path>)` or
# `$(basename -- <path>)` would: POSIX component rules, and the command
# substitution's removal of trailing newlines.
# The helpers keep their work in positional parameters, not locals, so no
# output-variable name is shadowed.

fm_dirname_to() {  # <output-variable> <path>
  case "$2" in
    '') set -- "$1" . ;;
    *[!/]*)
      set -- "$1" "${2%"${2##*[!/]}"}"
      case "$2" in
        */*)
          set -- "$1" "${2%/*}"
          set -- "$1" "${2%"${2##*[!/]}"}"
          [ -n "$2" ] || set -- "$1" /
          ;;
        *) set -- "$1" . ;;
      esac
      ;;
    *) set -- "$1" / ;;
  esac
  while [ "${2%$'\n'}" != "$2" ]; do set -- "$1" "${2%$'\n'}"; done
  printf -v "$1" '%s' "$2"
}

fm_basename_to() {  # <output-variable> <path>
  case "$2" in
    '') ;;
    *[!/]*) set -- "$1" "${2%"${2##*[!/]}"}"; set -- "$1" "${2##*/}" ;;
    *) set -- "$1" / ;;
  esac
  while [ "${2%$'\n'}" != "$2" ]; do set -- "$1" "${2%$'\n'}"; done
  printf -v "$1" '%s' "$2"
}

# Assigns <output-variable> what `$(cat <file> 2>/dev/null || true)` would,
# without forking unless the file holds a NUL byte, which `read` stops at.
# MSYS bash also drops a trailing CR before each newline it removes.
fm_file_contents_to() {  # <output-variable> <file>
  printf -v "$1" '%s' ''
  if { IFS= read -r -d '' "$1" < "$2"; } 2>/dev/null; then
    printf -v "$1" '%s' "$(cat "$2" 2>/dev/null || true)"
    return 0
  fi
  set -- "$1" "${!1}"
  while :; do
    case $OSTYPE:$2 in
      msys*:*$'\r\n') set -- "$1" "${2%$'\r\n'}" ;;
      *:*$'\n') set -- "$1" "${2%$'\n'}" ;;
      *) break ;;
    esac
  done
  printf -v "$1" '%s' "$2"
}
