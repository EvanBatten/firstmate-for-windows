#!/usr/bin/env bash
# fm-repo-invariants.sh - spellings in this repository that belong to one owner.
#
# Usage:
#   bin/fm-repo-invariants.sh [--root <repo>]
#   bin/fm-repo-invariants.sh -h | --help
#
# bin/fm-lint.sh's default path runs this over the whole tree. It prints every
# finding and exits 1 when any invariant fails, and exits 0 when all hold.
# --root checks another tree, which is how tests/fm-repo-invariants.test.sh
# drives it against fixtures.
#
# Invariants, each scanning every *.sh file under one directory:
#   ps-o    bin/    the `ps -o` field form, owned by bin/fm-proc-lib.sh. MSYS
#                   `ps` has no -o, so every such spelling reads empty on
#                   Windows; the fm_proc_* helpers answer on both platforms.
#   digest  tests/  a SHA-256 digest tool, owned by tests/lib.sh. The
#                   windows-latest runner has sha256sum and no shasum, macOS has
#                   long shipped only shasum, and fm_test_sha256 owns the
#                   fallback and refuses to return an empty digest.
#
# Each invariant checks, in this order:
#  1. its owner yields at least one match, so a pattern that cannot match fails
#     here instead of passing over the whole tree;
#  2. no other file matches, except a line directly below a directive naming
#     the invariant, in ShellCheck's own convention:
#       # fm-invariant: allow <name> - <reason>
#     A directive whose next line does not match is dead and fails too, so an
#     exception cannot outlive its reason, and a directive naming anything but
#     the invariant that scans its directory is malformed.
# Full-line comments are never matched: a comment that names a spelling is
# documentation, not a call.
#
# Step 1 exists because an extractor in this repository once used `[^"]*`,
# which cannot cross the embedded quotes of the dominant spelling, so it matched
# nothing and passed for months.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { printf 'fm-repo-invariants.sh: --root requires a directory\n' >&2; exit 2; }
      ROOT=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'fm-repo-invariants.sh: unexpected argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

cd "$ROOT" 2>/dev/null || { printf 'fm-repo-invariants.sh: cannot enter %s\n' "$ROOT" >&2; exit 2; }

# The `ps -o` field form. Matched on the field keyword rather than on `ps`,
# because a spelling can name the binary through a variable
# (`"$ps_bin" -p "$pid" -o stat=`), and on any bundled flag ending in o (`-axo`,
# `-eo`). The keyword list is what keeps `--command=*)` and `grep -Eo 'corr=`
# out.
PS_FIELDS='comm|args|command|cmd|ucomm|ppid|pgid|tpgid|pid|sess|lstart|etimes?|time|stat|state|user|uid|tty|rss|vsz|nice|%cpu|%mem'
PS_FIELD_FORM="(^|[^-[:alnum:]_])-[A-Za-z]*o[[:space:]]*[\"']?($PS_FIELDS)([=,[:space:]\"']|\$)"

# A digest tool in command position, a `command -v` probe for one, or one
# assigned to a variable. A mention in a message, a stub's file name or an
# argument is not a digest, which is why the bare word is not the pattern.
DIGEST_CALL='(^|[;&|`{]|\$\(|(^|[[:space:]])(if|then|do|else|elif|while|until|exec|time|xargs|!|command[[:space:]]+-v)[[:space:]])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(shasum|sha256sum)([[:space:]]|$|\)|;)|=(shasum|sha256sum)([[:space:]]|$|;)'

# owner_matches <ere> <file>: the number of non-comment lines of <file> that
# match <ere>.
owner_matches() {
  grep -hE -- "$1" "$2" 2>/dev/null | awk '
    { sub(/\r$/, ""); sub(/^[ \t]+/, "") }
    substr($0, 1, 1) != "#" { n++ }
    END { print n + 0 }'
}

# findings <name> <dir> <ere> <file>...: "<path>:<line>: <message>" for every
# match with no directive directly above it, and for every directive that is
# dead or malformed, sorted by path and line.
findings() {
  local name=$1 dir=$2 ere=$3
  shift 3
  {
    grep -nHE -- "$ere" "$@" 2>/dev/null | sed 's/^/M:/'
    grep -nHE -- '^[[:space:]]*#[[:space:]]*fm-invariant:' "$@" 2>/dev/null | sed 's/^/D:/'
  } | awk -v name="$name" -v dir="$dir" '
    {
      kind = substr($0, 1, 1)
      rest = substr($0, 3)
      i = index(rest, ":"); path = substr(rest, 1, i - 1); rest = substr(rest, i + 1)
      i = index(rest, ":"); line = substr(rest, 1, i - 1) + 0; content = substr(rest, i + 1)
      sub(/\r$/, "", content); sub(/^[ \t]+/, "", content); sub(/[ \t]+$/, "", content)
      key = path ":" line
      if (kind == "D") {
        directive[++nd] = key; directive_path[key] = path; directive_line[key] = line
        directive_text[key] = content
      } else if (substr(content, 1, 1) != "#") {
        found[++nm] = key; found_text[key] = content
      }
    }
    END {
      lead = "# fm-invariant: allow "
      for (k = 1; k <= nd; k++) {
        key = directive[k]; text = directive_text[key]
        rest = substr(text, length(lead) + 1)
        tag = rest; sub(/ .*/, "", tag)
        if (index(text, lead) != 1 || index(rest, tag " - ") != 1 || length(rest) <= length(tag " - ")) {
          print key ": malformed directive, expected \"" lead "<name> - <reason>\": " text
        } else if (tag != name) {
          print key ": directive names \"" tag "\", but " dir " is checked by \"" name "\": " text
        } else if ((directive_path[key] ":" (directive_line[key] + 1)) in found_text) {
          allowed[directive_path[key] ":" (directive_line[key] + 1)] = 1
        } else {
          print key ": dead directive, the next line is not a spelling it could allow: " text
        }
      }
      for (k = 1; k <= nm; k++) {
        key = found[k]
        if (!(key in allowed)) print key ": " found_text[key]
      }
    }' | LC_ALL=C sort -t: -k1,1 -k2,2n
}

# check <name> <dir> <owner> <ere> <remedy>: run one invariant, printing its
# findings under one explanatory line. Returns 1 when it fails.
check() {
  local name=$1 dir=$2 owner=$3 ere=$4 remedy=$5 path out
  local -a files=()
  if [ ! -f "$owner" ]; then
    printf 'fm-repo-invariants.sh: %s: its owner %s does not exist\n' "$name" "$owner"
    return 1
  fi
  if [ "$(owner_matches "$ere" "$owner")" -eq 0 ]; then
    printf 'fm-repo-invariants.sh: %s: the pattern finds nothing in its owner %s; the invariant is broken, not the tree\n' \
      "$name" "$owner"
    return 1
  fi
  while IFS= read -r path; do
    [ "$path" = "$owner" ] || files+=("$path")
  done < <(find "$dir" -type f -name '*.sh' 2>/dev/null | LC_ALL=C sort)
  [ "${#files[@]}" -gt 0 ] || return 0
  out=$(findings "$name" "$dir" "$ere" "${files[@]}")
  [ -n "$out" ] || return 0
  printf 'fm-repo-invariants.sh: %s: %s\n' "$name" "$remedy"
  printf '%s\n' "$out" | sed 's/^/  /'
  return 1
}

rc=0
check ps-o bin bin/fm-proc-lib.sh "$PS_FIELD_FORM" \
  "these lines spell the ps field form outside bin/fm-proc-lib.sh, where MSYS ps reads empty; use fm_proc_* or put a directive with its reason on the line above" \
  || rc=1
check digest tests tests/lib.sh "$DIGEST_CALL" \
  "these lines take a digest outside tests/lib.sh; use fm_test_sha256 or fm_test_sha256_stdin, or put a directive with its reason on the line above" \
  || rc=1

[ "$rc" -ne 0 ] || printf 'fm-repo-invariants.sh: ps-o and digest hold\n'
exit "$rc"
