#!/usr/bin/env bash
# fm-private-lib.sh - one owner of "this path must be private": the mode-700
# directory, the mode-600 file, and the check that a path really is that.
#
# Thirty-two scripts under bin/ create or assert private state, and every one
# of them spelled the same three steps inline: a `chmod 0600` or a
# `mkdir -m 700`, then a `stat` readback compared against that literal, then a
# refusal. That is correct wherever the filesystem can carry a POSIX mode. It
# is not a check at all where the filesystem cannot, and one machine can have
# both kinds of mount at once. This file owns that question so the answer is
# decided once.
#
# This file is sourced by scripts, has no side effects on source, and is a
# LEAF: it sources nothing, so any caller may source it in any order. It is
# safe under `set -u`.
#
# WHAT THE CALLER GETS
#   fm_private_modes_enforcing <path>   is a restrictive mode representable on
#                                       the filesystem under <path>?
#   fm_private_chmod <mode> <path>...   set the mode; fails only when the chmod
#                                       itself fails
#   fm_private_mkdir <dir>              create <dir> private; FAILS if <dir>
#                                       already exists, so a caller using the
#                                       creation as a lock still has its lock
#   fm_private_mode_ok <path> <mode>    the mode half of the assertion, for the
#                                       sites that carry their own structure
#                                       checks around it
#   fm_private_file_valid <path> <mode> <device>
#   fm_private_dir_valid  <path> <mode> <device>
#                                       the whole assertion, stated once
#   FM_PRIVATE_MODE_UNENFORCEABLE       empty, or the first path whose mode
#                                       this process could not enforce
#
# ON EVERY FILESYSTEM, EVERY HELPER HERE IS THE EXPRESSION ITS CALLER WROTE
# BEFORE IT EXISTED, AT THE SAME COST. `fm_private_chmod` is
# `chmod "$mode" "$@"` and nothing else: it never probes, on either branch, so
# no setter anywhere pays for one. ONE PLACE DECIDES WHETHER A MODE IS
# ENFORCEABLE, and it is the ASSERTION: `fm_private_mode_ok` is
# `[ "$(stat ...)" = "$mode" ]` and consults the probe only when that
# comparison DISAGREES, which a POSIX host does not reach in the ordinary case.
# A genuinely group-readable file on a mode-carrying filesystem is therefore
# still refused exactly as before. Only the disagreeing branch is new.
#
# WHY THE RELAXATION EXISTS (measured on Windows 11 26200, Git Bash 5.2
# MINGW64; docs/windows/measurement.md rows 21 and 24). Every Git Bash mount is
# `noacl`. There, `chmod 0600` on a file exits 0 and `stat -c %a` still reads
# 644, and `mkdir -m 700` creates the directory, fails to set the mode and
# exits 1 with the directory made. An exact-mode requirement on such a mount is
# not protective, it is unsatisfiable: it refuses every path, including the
# ones the process just created itself. That is what made `fm-pr-merge.sh`
# answer `error: could not prepare PR poll` for every merge, and what left four
# suites red at a mode check.
#
# WHY A HELPER AND NOT AN `acl` MOUNT (decision D6). Git Bash can carry modes
# if `/etc/fstab` mounts the volume `acl`, and that mount stays available as
# optional extra hardening - where it is present the probe below measures 600,
# the strict branch is in force, and nothing here changes. It is not the fix,
# because requiring it would make every Windows install perform an
# administrator setup step or else have the tooling silently misbehave, and
# nothing in the tooling can rely on a step taken on someone else's machine. A
# helper makes the code correct everywhere with no install ritual.
#
# WHERE THE PRIVACY CLAIM GOES INSTEAD. It relocates rather than weakening: the
# firstmate home and the temp directory both live under the user's NTFS profile
# directory, which Windows already keeps private to that user by ACL, and the
# same mount that drops our mode also stops another account from widening one.
# This is the argument slice 3 settled for the presentation-lock namespace
# (ledger row 9), extended by D6 to the private-state sites through this owner.
#
# THE CAPABILITY IS MEASURED, NEVER INFERRED. Not from `uname`, not from the
# mount table, not from the shape of a path: this machine has both kinds of
# mount, so only the filesystem under the path in hand can answer. The probe
# makes a `mktemp` file in the target's own directory - an unpredictable name
# no entry planted in advance can answer for - and then WATCHES A MODE CHANGE:
# `chmod 0644`, read back, `chmod 0600`, read back. Modes are enforcing only
# when both readbacks are the mode that was just asked for.
#
# Two readings, not one, because ONE READING CANNOT TELL THE TWO MOUNTS APART.
# A `noacl` mount does not store a mode at all: `stat` synthesizes one from the
# READING process's umask, 0644 & ~umask for a file and 0755 & ~umask for a
# directory, whatever the file was created as and whatever chmod was asked for.
# Measured here: one file reads 644 under umask 022 and 600 under umask 077,
# and a directory reads 755 and 700 the same way. So a probe that only chmods
# 0600 and checks for 600 reports "modes are enforcing" on this mount for any
# caller that set `umask 077` first - which `fm_pr_poll_prepare` does, and
# which is exactly the code path this library exists for. Watching the mode
# MOVE cannot be fooled that way: no umask makes one file read 644 after a
# chmod 0644 and 600 after a chmod 0600 unless the chmod is real.
#
# The verdict is cached per DEVICE, so a process that touches two mounts
# measures each, and the cache lives in a plain shell variable that is
# deliberately not exported, so a child on a different mount measures its own.
# A probe that cannot run proves nothing, so it leaves the strict branch in
# force: an unwritable directory or an unreadable `stat` never relaxes a
# mode-carrying host.
#
# WHAT A WAIVER LEAVES BEHIND, AND WHO READS IT TODAY: NOBODY. Every waiver
# records the path in FM_PRIVATE_MODE_UNENFORCEABLE, and nothing here writes to
# stderr - these helpers run inside hooks whose stdout and stderr are a
# protocol, so a line of prose from a library is a defect. That variable and
# `fm_private_mode_unenforceable` are an OUTPUT for a caller that owns its own
# output, and no such caller exists yet: nothing under bin/ reads either one,
# and tests/fm-private-lib.test.sh is the only reader in the tree. So on a
# mount that cannot carry a mode, every mode check routed through this owner is
# waived with no operator-visible signal anywhere, and the privacy claim rests
# entirely on the filesystem's own access control rather than on the mode bits.
# That is what decision D6 settled for Git Bash, where the home and the temp
# directory sit under the user's NTFS profile directory and Windows keeps them
# private to that user by ACL. The capability is MEASURED and not
# platform-gated, so the same silence covers any other mount that cannot carry
# a mode - an exFAT, FAT or NFS FM_HOME or TMPDIR on a POSIX host - where the
# claim is that mount's to make and the NTFS argument does not carry it.

if [ -n "${FM_PRIVATE_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_PRIVATE_LIB_SOURCED=1

# The first path whose mode this process could not enforce, or empty. An
# OUTPUT: a caller reads it, nothing sets it, and it is neither exported nor
# seeded from the environment, so it always describes the waivers THIS process
# made and an inherited value can never pass one off as its own.
FM_PRIVATE_MODE_UNENFORCEABLE=

# " <device>=0 <device>=1 " - 0 enforcing, 1 not representable. Not exported.
_FM_PRIVATE_PROBE_CACHE=

# BSD `stat` and GNU `stat` spell the same three questions differently, and the
# answer cannot change inside one process, so it is decided once, here, and the
# readers below only read it. It comes from `$OSTYPE`, which bash sets at its
# own startup, so this costs no process at all - sourcing this file still runs
# nothing, and neither does any later call.
#
# A `uname` resolved on first use could not have been memoized at all: every
# caller of these readers is a command substitution, so the assignment would
# land in a subshell and be discarded, and each of the four would fork `uname`
# again on every call - three per fm_private_file_valid, five of those per
# guarded merge, on the platform whose fork price is the expensive one.
case ${OSTYPE:-} in
  darwin*) _FM_PRIVATE_STAT_BSD=yes ;;
  *) _FM_PRIVATE_STAT_BSD=no ;;
esac

# This user's numeric id, resolved on the probe's first run and only there, so
# a caller that never reaches the probe never pays for it. An `id` that cannot
# answer leaves this empty and the ownership check stands down; on such a host
# the probe's own regular-file and link-count checks are all that is left.
_FM_PRIVATE_UID=

_fm_private_resolve_uid() {
  [ -z "$_FM_PRIVATE_UID" ] || return 0
  _FM_PRIVATE_UID=$(id -u 2>/dev/null) || _FM_PRIVATE_UID=
}

fm_private_stat_mode() {  # <path>
  if [ "$_FM_PRIVATE_STAT_BSD" = yes ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

fm_private_stat_device() {  # <path>
  if [ "$_FM_PRIVATE_STAT_BSD" = yes ]; then
    stat -f %d "$1" 2>/dev/null
  else
    stat -c %d "$1" 2>/dev/null
  fi
}

fm_private_stat_link_count() {  # <path>
  if [ "$_FM_PRIVATE_STAT_BSD" = yes ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

fm_private_stat_owner() {  # <path>
  if [ "$_FM_PRIVATE_STAT_BSD" = yes ]; then
    stat -f %u "$1" 2>/dev/null
  else
    stat -c %u "$1" 2>/dev/null
  fi
}

# `chmod 0600 x` and `[ "$(stat -c %a x)" = 600 ]` are both idiomatic in the
# call sites, so 0600 and 600 have to name one mode here.
_fm_private_mode_canon() {  # <mode>
  local mode=${1-}
  case "$mode" in
    ''|*[!0-7]*) return 1 ;;
  esac
  while :; do
    case "$mode" in
      0?*) mode=${mode#0} ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$mode"
}

# The directory whose filesystem decides <path>'s modes. An existing directory
# answers for itself; anything else answers through its parent, which is what a
# not-yet-created file needs.
_fm_private_probe_dir() {  # <path>
  local path=${1-} dir
  if [ -d "$path" ] && [ ! -L "$path" ]; then
    printf '%s\n' "$path"
    return 0
  fi
  case "$path" in
    */*) dir=${path%/*}; [ -n "$dir" ] || dir=/ ;;
    *) dir=. ;;
  esac
  printf '%s\n' "$dir"
}

# The probe is only evidence about the filesystem if the file it reads is the
# file it made. The one directory the probe cannot avoid writing into is the
# very directory whose mode is in question, and the case that reaches the probe
# at all is the case where that mode has already been found wrong - so on a
# mode-carrying host the probe can be running inside a genuinely
# group-writable directory. There, another account can unlink the probe and
# leave a 644 file of the same name in its place, and a probe that believed it
# would report "modes are not representable here" and waive the very check that
# was catching the directory. It cannot forge OWNERSHIP, so that is what is
# checked: a probe that is not a plain, singly-linked file belonging to this
# user is not evidence, and the strict branch stands.
#
# This is asked BEFORE and AFTER the two readbacks, because a swap between the
# check and the reading is exactly the swap that matters, and the probe's own
# `chmod` calls have to succeed for the same reason: a chmod on a file this
# process made and owns cannot fail on any filesystem, so one that does has
# stopped describing our file. Nothing about a mount that merely drops modes
# fails any of that - measured there, chmod exits 0 and only the readback moves.
_fm_private_probe_is_ours() {  # <probe>
  local probe=$1
  _fm_private_resolve_uid
  [ -f "$probe" ] && [ ! -L "$probe" ] || return 1
  [ "$(fm_private_stat_link_count "$probe")" = 1 ] || return 1
  [ -z "$_FM_PRIVATE_UID" ] || [ "$(fm_private_stat_owner "$probe")" = "$_FM_PRIVATE_UID" ]
}

# Is a restrictive mode representable on the filesystem under <path>?
# 0 yes (the strict branch), 1 no. An unmeasurable answer is yes: a probe that
# could not run has not shown that anything is wrong with the host.
fm_private_modes_enforcing() {  # <path>
  local dir device probe wide narrow
  dir=$(_fm_private_probe_dir "${1-}")
  device=$(fm_private_stat_device "$dir") || device=
  [ -n "$device" ] || return 0
  case "$_FM_PRIVATE_PROBE_CACHE" in
    *" $device=0 "*) return 0 ;;
    *" $device=1 "*) return 1 ;;
  esac
  probe=$(mktemp "$dir/.fm-private-probe.XXXXXX" 2>/dev/null) || probe=
  [ -n "$probe" ] || return 0
  wide=
  narrow=
  if _fm_private_probe_is_ours "$probe" && chmod 0644 "$probe" 2>/dev/null; then
    wide=$(_fm_private_mode_canon "$(fm_private_stat_mode "$probe")") || wide=
    if chmod 0600 "$probe" 2>/dev/null; then
      narrow=$(_fm_private_mode_canon "$(fm_private_stat_mode "$probe")") || narrow=
    fi
    _fm_private_probe_is_ours "$probe" || { wide=; narrow=; }
  fi
  rm -f -- "$probe" 2>/dev/null || true
  [ -n "$wide" ] && [ -n "$narrow" ] || return 0
  if [ "$wide" = 644 ] && [ "$narrow" = 600 ]; then
    _FM_PRIVATE_PROBE_CACHE="$_FM_PRIVATE_PROBE_CACHE $device=0 "
    return 0
  fi
  _FM_PRIVATE_PROBE_CACHE="$_FM_PRIVATE_PROBE_CACHE $device=1 "
  return 1
}

_fm_private_note_unenforceable() {  # <path>
  [ -n "$FM_PRIVATE_MODE_UNENFORCEABLE" ] || FM_PRIVATE_MODE_UNENFORCEABLE=${1-}
}

# True when this process has waived at least one mode check.
fm_private_mode_unenforceable() {
  [ -n "$FM_PRIVATE_MODE_UNENFORCEABLE" ]
}

# Does <path> carry <mode>, or is <mode> not representable where <path> lives?
# This is the one place a mode check is waived, and every waiver is recorded.
fm_private_mode_ok() {  # <path> <mode>
  local path=${1-} want observed
  want=$(_fm_private_mode_canon "${2-}") || return 1
  observed=$(fm_private_stat_mode "$path") || return 1
  observed=$(_fm_private_mode_canon "$observed") || return 1
  [ "$observed" != "$want" ] || return 0
  fm_private_modes_enforcing "$path" && return 1
  _fm_private_note_unenforceable "$path"
  return 0
}

# Set <mode> on each <path>. This is `chmod` and nothing more, and it measures
# nothing: a filesystem that cannot carry the mode does not FAIL this call -
# measured on Git Bash, `chmod 0600` returns 0 and leaves 644 behind - so a
# probe here could only re-derive what fm_private_mode_ok already asks at the
# one moment the answer is needed, which is when a readback disagrees. The
# record of an unenforceable mode belongs to that assertion, so this setter
# costs no site a probe on any host.
#
# A chmod that FAILS is an error on every filesystem, and is not waived here.
# Waiving it would also waive a read-only mount, a file another user owns, and
# a caller that cannot set the mode for any other reason, making "the tool
# could not make this private" unobservable to the product that depends on it.
fm_private_chmod() {  # <mode> <path>...
  local mode=${1-}
  shift || return 1
  [ "$#" -gt 0 ] || return 1
  chmod "$mode" "$@" 2>/dev/null
}

# Create <dir> as a private directory. Creation is atomic and REFUSES an
# existing <dir>, because several callers use exactly that to hold a lock; the
# mode comes from the umask so there is no window in which the directory exists
# at a wider one, and the chmod that follows is what `mkdir -m 700` did, minus
# that command's failure on a mount which cannot take the mode.
fm_private_mkdir() {  # <dir>
  local dir=${1-}
  [ -n "$dir" ] || return 1
  (umask 077; mkdir -- "$dir") 2>/dev/null || return 1
  fm_private_chmod 700 "$dir"
}

# The whole assertion for a private FILE: a regular file, not a symlink, on the
# expected device, with exactly one link, at <mode>. <device> is compared
# literally, so an empty <device> refuses - a caller that could not determine
# the device has not shown the file is where it believes it is.
fm_private_file_valid() {  # <path> <mode> <device>
  local path=${1-} mode=${2-} device=${3-}
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  fm_private_mode_ok "$path" "$mode" || return 1
  [ "$(fm_private_stat_device "$path")" = "$device" ] || return 1
  [ "$(fm_private_stat_link_count "$path")" = 1 ]
}

# The same for a private DIRECTORY. Link count is not part of it: a directory's
# count is its subdirectory count, not a hard-link hazard.
fm_private_dir_valid() {  # <path> <mode> <device>
  local path=${1-} mode=${2-} device=${3-}
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  fm_private_mode_ok "$path" "$mode" || return 1
  [ "$(fm_private_stat_device "$path")" = "$device" ]
}
