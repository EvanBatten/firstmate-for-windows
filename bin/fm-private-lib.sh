#!/usr/bin/env bash
# fm-private-lib.sh - the single owner of "make this state private": mode-700
# directories, mode-600 files, and the check that a path really is that
# private, on filesystems that may not carry POSIX modes at all.
#
# Sourced, never executed. No dependencies beyond coreutils (stat, mktemp,
# chmod, uname), so any caller can source it standalone.
#
#   fm_private_modes_capable <path>  - 0 when the filesystem under <path> can
#       represent POSIX modes, 1 when it cannot; measured once per process
#   fm_private_mkdir <dir>           - create <dir> (with parents) as a
#       private mode-700 directory
#   fm_private_file_chmod <mode> <file>... - chmod each file and refuse a
#       wrong readback where modes are representable
#   fm_private_mode_ok <path> <mode> - "is this path private enough"
#
# On every Git Bash mount (all mounted noacl - ledger row 21) `mkdir -m 700`
# creates a 755 directory and exits 1, `chmod` is a no-op, and `stat` reads
# back 755/644 whatever was asked, so an exact-mode requirement there is
# unsatisfiable rather than protective. The privacy claim relocates instead of
# weakening: the firstmate home and /tmp both live under the user's NTFS
# profile directory, which Windows already makes private to the user by ACL,
# and the same noacl mount that drops OUR mode also stops an attacker from
# widening one. That is the argument for accepting the best effort there - the
# same principle the presentation-lock namespace settled in slice 3 (ledger
# row 9), extended by decision D6 to the private-state sites through this one
# owner.
#
# The capability is MEASURED, never inferred from the platform: a probe
# directory is made by mktemp -d under the target's own directory, chmod 700,
# and its mode read back. Only a filesystem that drops modes answers with
# anything but 700, so a genuinely group-readable path on a mode-capable
# filesystem still fails its check. The probe sits under the target's own
# directory because the answer has to describe the target's filesystem, and
# mktemp's unpredictable name is what removes the pre-created-entry squat that
# made the row 9 probe move beside its namespace: a $$-named probe can be
# planted in advance, a mktemp name cannot. The answer is cached once per
# process in a shell variable and deliberately not exported, so a child
# process on a different mount measures its own. A probe that cannot run
# proves nothing, so it leaves the strict branch in force: a transient failure
# never weakens a mode-capable host.
#
# The check only probes when a mode DISAGREES, so on a mode-capable filesystem
# every function here is byte-identical to the chmod / stat comparison its
# call sites ran before, at zero extra cost. When a mode is not representable,
# the first accepting operation records one warning line to stderr per
# process, so the relaxation is visible without any site drowning in repeats.

# Capability cache: empty = unmeasured, 0 = capable, 1 = not capable. The
# expansions keep an already-measured answer across a double source.
_FM_PRIVATE_MODES_CAPABLE=${_FM_PRIVATE_MODES_CAPABLE-}
_FM_PRIVATE_MODES_WARNED=${_FM_PRIVATE_MODES_WARNED-}

fm_private_stat_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

fm_private_modes_capable() {
  local target=$1 dir probe mode
  if [ -z "$_FM_PRIVATE_MODES_CAPABLE" ]; then
    if [ -d "$target" ]; then
      dir=$target
    else
      case "$target" in
        */*) dir=${target%/*} ;;
        *) dir=. ;;
      esac
      [ -n "$dir" ] || dir=/
    fi
    _FM_PRIVATE_MODES_CAPABLE=0
    probe=$(mktemp -d "$dir/.fm-private-probe.XXXXXX" 2>/dev/null) || probe=
    if [ -n "$probe" ]; then
      chmod 700 "$probe" 2>/dev/null || true
      mode=$(fm_private_stat_mode "$probe") || mode=
      rm -rf -- "$probe" 2>/dev/null || true
      [ "$mode" = 700 ] || _FM_PRIVATE_MODES_CAPABLE=1
    fi
  fi
  [ "$_FM_PRIVATE_MODES_CAPABLE" -eq 0 ]
}

_fm_private_warn_once() {
  [ -z "$_FM_PRIVATE_MODES_WARNED" ] || return 0
  _FM_PRIVATE_MODES_WARNED=1
  printf 'fm-private: the filesystem under %s drops POSIX modes; accepting its own access control as the privacy boundary\n' "$1" >&2
}

fm_private_mode_ok() {
  local path=$1 expected=$2 mode
  mode=$(fm_private_stat_mode "$path") || return 1
  [ -n "$mode" ] || return 1
  case "$mode" in *[!0-7]*) return 1 ;; esac
  case "$expected" in ''|*[!0-7]*) return 1 ;; esac
  if [ "$((8#$mode))" -eq "$((8#$expected))" ]; then
    return 0
  fi
  if fm_private_modes_capable "$path"; then
    return 1
  fi
  _fm_private_warn_once "$path"
  return 0
}

fm_private_mkdir() {
  local dir=$1
  (umask 077; mkdir -p -- "$dir" 2>/dev/null) || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  fm_private_mode_ok "$dir" 700
}

fm_private_file_chmod() {
  local mode=$1 file
  shift
  for file in "$@"; do
    chmod "$mode" "$file" 2>/dev/null || return 1
    fm_private_mode_ok "$file" "$mode" || return 1
  done
}
