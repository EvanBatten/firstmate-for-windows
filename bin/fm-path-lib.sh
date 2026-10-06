#!/usr/bin/env bash
# fm-path-lib.sh - fork-free pathname helpers with no source-time side effects,
# so read-only callers can load them without any library's state setup.
#
# Each assigns <output-variable> exactly what `$(dirname -- <path>)` or
# `$(basename -- <path>)` would: POSIX component rules, and the command
# substitution's removal of trailing newlines.

fm_dirname_to() {  # <output-variable> <path>
  local fm_path=$2
  case "$fm_path" in
    '') fm_path=. ;;
    *[!/]*)
      fm_path=${fm_path%"${fm_path##*[!/]}"}
      case "$fm_path" in
        */*)
          fm_path=${fm_path%/*}
          fm_path=${fm_path%"${fm_path##*[!/]}"}
          [ -n "$fm_path" ] || fm_path=/
          ;;
        *) fm_path=. ;;
      esac
      ;;
    *) fm_path=/ ;;
  esac
  while [ "${fm_path%$'\n'}" != "$fm_path" ]; do fm_path=${fm_path%$'\n'}; done
  printf -v "$1" '%s' "$fm_path"
}

fm_basename_to() {  # <output-variable> <path>
  local fm_path=$2
  case "$fm_path" in
    '') ;;
    *[!/]*) fm_path=${fm_path%"${fm_path##*[!/]}"}; fm_path=${fm_path##*/} ;;
    *) fm_path=/ ;;
  esac
  while [ "${fm_path%$'\n'}" != "$fm_path" ]; do fm_path=${fm_path%$'\n'}; done
  printf -v "$1" '%s' "$fm_path"
}

# Assigns <output-variable> what `$(cat <file> 2>/dev/null || true)` would,
# without forking unless the file holds a NUL byte, which `read` stops at.
# MSYS bash also drops a trailing CR before each newline it removes.
fm_file_contents_to() {  # <output-variable> <file>
  local fm_contents=
  if { IFS= read -r -d '' fm_contents < "$2"; } 2>/dev/null; then
    fm_contents=$(cat "$2" 2>/dev/null || true)
  else
    while :; do
      case $OSTYPE:$fm_contents in
        msys*:*$'\r\n') fm_contents=${fm_contents%$'\r\n'} ;;
        *:*$'\n') fm_contents=${fm_contents%$'\n'} ;;
        *) break ;;
      esac
    done
  fi
  printf -v "$1" '%s' "$fm_contents"
}
