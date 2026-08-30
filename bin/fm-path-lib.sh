#!/usr/bin/env bash
# fm-path-lib.sh - one owner of "is this path absolute, and do these two paths
# name the same place".
#
# bin/fm-fleet-sync.sh, bin/fm-config-inherit-lib.sh, bin/fm-control.sh,
# bin/fm-spawn.sh and bin/fm-teardown.sh each spell the same two questions
# inline: `(cd "$p" && pwd -P)` to reduce a directory to one form, then `=` or a
# `case "$p" in "$top"/*)` prefix match to decide whether two paths are the same
# place. That is correct wherever the shell and every tool it calls address the
# filesystem through ONE namespace, and it is wrong on Windows, where they do
# not. This file owns that question so the answer is decided once.
#
# This file is sourced by scripts, has no side effects on source, and is a LEAF:
# it sources nothing, so any caller may source it in any order.
#
# ON macOS AND LINUX EVERY HELPER IS THE EXPRESSION ITS CALLER WROTE BEFORE.
# fm_path_canon_dir is `(cd "$dir" 2>/dev/null && pwd -P)` and returns from that
# subshell directly, fm_path_dirs_equal is `[ "$a" = "$b" ]`,
# fm_path_strip_dir_prefix is the `case "$path" in "$dir"/*) ${path#"$dir"/}` it
# replaces, and fm_path_is_absolute is `case "$p" in /*)`. Nothing else runs
# there: every widening below is gated on fm_path_windows_userland, which is
# false on any host that has no cygpath.
#
# THE ONE DELIBERATE EXCEPTION, on every platform: an EMPTY argument is refused.
# `cd ""` SUCCEEDS in bash and leaves the shell where it was, so the expression
# this replaces answered an empty argument with the CALLER'S current directory -
# a plausible path naming the wrong place. bin/fm-spawn.sh's isolation guard
# reached that case whenever `git rev-parse --show-toplevel` failed. Refusing is
# a behavior change on macOS and Linux too, and it only ever refuses more.
#
# WHY WINDOWS NEEDS A BRANCH (measured on Windows 11 26200, Git Bash 5.2
# MINGW64; docs/windows/measurement.md rows 23 and 31):
#   - `git rev-parse --show-toplevel` answers `C:/Users/ebatt/x` while `pwd -P`
#     in that same directory answers `/c/Users/ebatt/x`. Six sites compare the
#     two forms to each other, so on Windows every one of them decides "these
#     are different directories" about one directory.
#   - `git rev-parse --git-path index.lock` answers a RELATIVE path in a plain
#     clone and an absolute `C:/...` one in a linked worktree, so a
#     `case "$lock" in /*)` guard misfiles the absolute answer as relative and
#     prepends a directory to it.
#   - The filesystem underneath is case-insensitive, and the two producers
#     disagree about case as well as about namespace: git reports the path the
#     filesystem records (`C:/Users/...`) while `pwd -P` echoes the case the
#     caller typed (`cd /c/users/ebatt` stays `/c/users/ebatt`). Two spellings
#     of one directory must not read as two directories.
#   - `pwd -P` picks the MOST SPECIFIC mount, and the mount table overlaps:
#     `C:/Users/<u>/AppData/Local/Temp` is mounted at `/tmp` and `C:` at `/c`,
#     so `cd C:/Users/<u>/AppData/Local/Temp/x` lands on `/tmp/x` while
#     `cd /c/Users/<u>/AppData/Local/Temp/x` stays `/c/Users/.../Temp/x`. One
#     directory, two `pwd -P` answers, decided by which spelling was handed in.
#     A round trip through `cygpath -m` and back is what collapses them, because
#     Win32 has exactly one name for the directory and `cygpath -u` re-enters
#     the shell namespace through the same most-specific-mount rule.
#
# WHY cygpath IS THE MARKER. It exists on Cygwin, MSYS2 and Git Bash and
# nowhere else, it is the same marker bin/backends/herdr.sh already uses for the
# same question about socket paths, and it is a property of the USERLAND rather
# than of `uname`, which is what actually decides whether `C:/x` is an absolute
# path or a relative one that happens to contain a colon. It is probed per call
# rather than resolved once at source time: `command -v` is a builtin, it costs
# no fork, and a test can then install or remove the marker on PATH.

# fm_path_windows_userland: does this shell address the filesystem through Win32
# paths as well as through its own?
fm_path_windows_userland() {
  command -v cygpath >/dev/null 2>&1
}

# fm_path_is_absolute <path>: is this path already rooted, so that a caller must
# NOT join it onto a directory? On macOS and Linux exactly `case "$p" in /*)`.
# On a Windows userland a drive-rooted path (`C:/x`, `C:\x`) is rooted too.
# Anywhere else `C:/x` is a relative path that happens to contain a colon and is
# still reported relative, which is what it is there.
fm_path_is_absolute() {  # <path>
  case "${1-}" in
    /*) return 0 ;;
    [A-Za-z]:[/\\]*) fm_path_windows_userland && return 0; return 1 ;;
    *) return 1 ;;
  esac
}

# fm_path_fold_case <string>: the case-insensitive comparison key. Byte-wise and
# ASCII-only, so it preserves length - fm_path_strip_dir_prefix relies on that
# to strip a folded prefix off the UNFOLDED path.
fm_path_fold_case() {  # <string>
  printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]'
}

# fm_path_canon_dir <dir>: reduce an existing directory to one spelling in THIS
# shell's own namespace, resolving symlinks. Fails when the argument is empty or
# the directory cannot be entered; callers keep whatever they did with that.
#
# It does NOT fold case: the answer is a real path a caller may hand to another
# tool, and lowercasing it would be a lie about a directory that is recorded
# with capitals. Comparison is where case stops mattering, which is why
# fm_path_dirs_equal and fm_path_strip_dir_prefix own the fold instead.
#
# On a Windows userland the answer is additionally pinned to ONE mount spelling.
# `cd` accepts a drive-rooted path and `pwd -P` answers in the shell namespace,
# so no branch is needed to fold `C:/x` in - but `pwd -P` picks the most
# specific mount, and which mount that is depends on the spelling it was given,
# so the same directory reached two ways yields two answers. Reducing through
# Win32 and back collapses them. Either cygpath call failing leaves the plain
# answer in place rather than failing the lookup, because a mount spelling that
# cannot be normalized is still a usable path.
fm_path_canon_dir() {  # <dir>
  local out win norm
  [ -n "${1-}" ] || return 1
  if ! fm_path_windows_userland; then
    ( cd "$1" 2>/dev/null && pwd -P ) || return 1
    return 0
  fi
  out=$( cd "$1" 2>/dev/null && pwd -P ) || return 1
  if win=$(cygpath -m "$out" 2>/dev/null) && [ -n "$win" ] &&
    norm=$(cygpath -u "$win" 2>/dev/null) && [ -n "$norm" ]; then
    out=$norm
  fi
  printf '%s\n' "$out"
}

# fm_path_dirs_equal <a> <b>: do two paths name the same place? A byte
# comparison everywhere; on a Windows userland also a case-folded one, because
# the filesystem there is case-insensitive and `C:/Users/x` and `c:/users/x` are
# one directory. The fold only ever runs after the byte comparison has already
# failed, so a filesystem that does distinguish case is unaffected.
#
# This is a comparison and nothing else. It does not canonicalize, because a
# caller that has NOT canonicalized both sides is asking the wrong question and
# should not be given a plausible answer, and it does not reject empty strings,
# because every caller already guards those and this must stay `=`.
fm_path_dirs_equal() {  # <a> <b>
  [ "${1-}" = "${2-}" ] && return 0
  fm_path_windows_userland || return 1
  [ "$(fm_path_fold_case "${1-}")" = "$(fm_path_fold_case "${2-}")" ]
}

# fm_path_strip_dir_prefix <dir> <path>: print <path> relative to <dir> when
# <path> is strictly under it, or fail. `<dir>` itself is not under itself and
# fails, matching the `case "$path" in "$dir"/*)` this replaces.
#
# The printed answer keeps the ORIGINAL case of <path>, because it is a real
# relative path a caller hands to another tool (`git check-ignore` is the one
# caller today). Only the prefix TEST folds case, and only on a Windows
# userland, and only after the exact test has failed.
fm_path_strip_dir_prefix() {  # <dir> <path>
  local dir=${1-} path=${2-} folded_dir folded_path
  [ -n "$dir" ] && [ -n "$path" ] || return 1
  case "$path" in
    "$dir"/*) printf '%s' "${path#"$dir"/}"; return 0 ;;
  esac
  fm_path_windows_userland || return 1
  folded_dir=$(fm_path_fold_case "$dir")
  folded_path=$(fm_path_fold_case "$path")
  case "$folded_path" in
    "$folded_dir"/*) printf '%s' "${path:$((${#dir} + 1))}"; return 0 ;;
  esac
  return 1
}
