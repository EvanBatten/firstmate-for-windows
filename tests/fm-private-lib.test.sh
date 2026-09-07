#!/usr/bin/env bash
# tests/fm-private-lib.test.sh - unit tests for bin/fm-private-lib.sh, the one
# owner of "this path must be private".
#
# The library has two branches and BOTH are covered from any host, because the
# thing that picks the branch is a MEASUREMENT of the filesystem and the two
# filesystems the fleet meets do not both exist on any one machine: a Linux or
# macOS runner has no mount that drops a mode, and a Git Bash host has no mount
# that keeps one. Letting the host pick would give two sets of cases that each
# only ever run in one place, and the branch that matters most - the strict one
# - would then never run where the relaxation was written.
#
# So each case names its filesystem, and the fixture supplies it by shadowing
# the two commands that carry a mode: `chmod`, which sets it, and `stat`, which
# reads it back. Both fixtures are faithful to a real mount rather than to the
# library's internals:
#
#   noacl_fs     `chmod` is left alone, because on such a mount it exits 0 and
#                does nothing; `stat` stores no mode and synthesizes one from
#                the READING process's umask, which is what was measured on
#                this machine's Git Bash mounts (measurement.md row 21).
#                tests/lib.sh owns that stub - tests/fm-pr-merge.test.sh puts
#                the same mount under the guarded merge path.
#   enforcing_fs `chmod` runs the real chmod AND records the mode it set
#                against the file's device and inode; `stat` answers %a from
#                that record. On a host that really carries modes the record
#                and the inode agree at every step, so the fixture is a
#                pass-through; on one that does not, it supplies the mode the
#                filesystem dropped. Recording against the INODE rather than
#                the path is what keeps a mode attached to a file across the
#                `mv` that publishes it.
#
# Everything else - the temp file the probe makes, the directories, the links,
# the devices - is the real filesystem, so the structural half of the assertion
# is never simulated at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-private-lib)
LIB="$ROOT/bin/fm-private-lib.sh"

# --- fixtures ---------------------------------------------------------------

case_dir() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# The header the enforcing `stat` stub needs: where the real stat is, which
# spelling it answers to, and which format and path this call is asking about.
fixture_stat_header() {  # <real-stat>
  printf 'REAL_STAT=%s\n' "$(printf '%q' "$1")"
  cat <<'SH'
if [ "$(uname 2>/dev/null)" = Darwin ]; then KEY_FMT=%d:%i; FMT_FLAG=-f
else KEY_FMT=%d:%i; FMT_FLAG=-c; fi
ARG_FMT=
for a in "$@"; do case "$a" in %*) ARG_FMT=$a ;; esac; done
ARG_PATH=${*: -1}
SH
}

# A mount that cannot carry a restrictive mode. `chmod` is left alone, because
# on such a mount it exits 0 and simply does nothing; only the readback moves.
# tests/lib.sh owns that stub, because tests/fm-pr-merge.test.sh puts the same
# mount under the guarded merge path.
noacl_fs() {  # <dir> -> a directory to prepend to PATH
  local dir=$1 fakebin
  fakebin="$dir/fs-noacl"
  mkdir -p "$fakebin"
  fm_fake_noacl_stat "$fakebin"
  printf '%s\n' "$fakebin"
}

# A mount that carries modes, on any host: the mode `chmod` sets is the mode
# `stat` reads back, keyed by inode so it survives a rename.
enforcing_fs() {  # <dir> -> a directory to prepend to PATH
  local dir=$1 fakebin db
  fakebin="$dir/fs-enforcing"
  db="$dir/fs-enforcing-modes"
  mkdir -p "$fakebin" "$db"
  {
    printf '#!/usr/bin/env bash\n'
    fixture_stat_header "$(command -v stat)"
    printf 'DB=%s\n' "$(printf '%q' "$db")"
    cat <<'SH'
case "$ARG_FMT" in
  %a|%Lp)
    key=$("$REAL_STAT" "$FMT_FLAG" "$KEY_FMT" "$ARG_PATH" 2>/dev/null) || exit 1
    [ -f "$DB/$key" ] && exec cat "$DB/$key"
    ;;
esac
exec "$REAL_STAT" "$@"
SH
  } > "$fakebin/stat"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'REAL_STAT=%s\n' "$(printf '%q' "$(command -v stat)")"
    printf 'REAL_CHMOD=%s\n' "$(printf '%q' "$(command -v chmod)")"
    printf 'DB=%s\n' "$(printf '%q' "$db")"
    cat <<'SH'
if [ "$(uname 2>/dev/null)" = Darwin ]; then KEY_FMT=%d:%i; FMT_FLAG=-f
else KEY_FMT=%d:%i; FMT_FLAG=-c; fi
mode=$1
shift
"$REAL_CHMOD" "$mode" "$@" 2>/dev/null || true
# A real filesystem keeps the mode in the inode, where a leading zero has
# nowhere to live, so the record drops it the way stat would.
while :; do case "$mode" in 0?*) mode=${mode#0} ;; *) break ;; esac; done
rc=0
for p in "$@"; do
  key=$("$REAL_STAT" "$FMT_FLAG" "$KEY_FMT" "$p" 2>/dev/null) || { rc=1; continue; }
  printf '%s\n' "$mode" > "$DB/$key" || rc=1
done
exit "$rc"
SH
  } > "$fakebin/chmod"
  chmod +x "$fakebin/stat" "$fakebin/chmod"
  printf '%s\n' "$fakebin"
}

# Run <script> against the library on the filesystem <fakebin> describes. The
# fixture is PREPENDED to PATH rather than replacing it, so the only commands
# the library sees differently are the two the fixture defines.
#
# A library that will not source exits here with no output rather than letting
# the script run. Several cases below expect a REFUSAL, and an undefined
# function refuses too, so without this every one of them would pass against a
# tree that has no library at all.
fs_eval() {  # <fakebin> <script>
  local fakebin=$1 script=$2
  PATH="$fakebin:$PATH" "${BASH:-/bin/bash}" -c "
    set -u
    . \"\$0\" || exit 97
    $script
  " "$LIB"
}

# --- the probe --------------------------------------------------------------

test_probe_measures_a_mount_that_carries_modes() {
  local dir out
  dir=$(case_dir probe-enforcing)
  out=$(fs_eval "$(enforcing_fs "$dir")" "
    fm_private_modes_enforcing '$dir' && echo enforcing || echo relaxed
  ")
  [ "$out" = enforcing ] \
    || fail "a mount whose chmod 0600 reads back 600 must measure as enforcing, got '$out'"
  pass "private-lib: the probe measures a mode-carrying mount as enforcing"
}

test_probe_measures_a_mount_that_drops_modes() {
  local dir out
  dir=$(case_dir probe-noacl)
  out=$(fs_eval "$(noacl_fs "$dir")" "
    fm_private_modes_enforcing '$dir' && echo enforcing || echo relaxed
  ")
  [ "$out" = relaxed ] \
    || fail "a mount whose chmod 0600 reads back 644 must measure as not representable, got '$out'"
  pass "private-lib: the probe measures a mount that drops modes as not representable"
}

# A mount that stores no mode synthesizes one from the READER's umask, so under
# `umask 077` a plain file reads back 600 and a directory 700 while carrying
# nothing at all. bin/fm-pr-lib.sh's poll registration sets exactly that umask
# before it stages its private files, so a probe that asks one question - chmod
# 0600, is it 600? - answers "modes are enforcing here" on the very mount, and
# in the very code path, this library exists for. Only watching the mode MOVE
# tells the two mounts apart.
test_probe_is_not_fooled_by_a_umask_that_flatters_the_readback() {
  local dir out
  dir=$(case_dir probe-umask)
  mkdir -p "$dir/work"
  out=$(fs_eval "$(noacl_fs "$dir")" "
    umask 077
    : > '$dir/work/f'
    observed=\$(fm_private_stat_mode '$dir/work/f')
    fm_private_modes_enforcing '$dir/work/f' && verdict=enforcing || verdict=relaxed
    printf '%s %s\n' \"\$observed\" \"\$verdict\"
  ")
  [ "$out" = "600 relaxed" ] \
    || fail "a 600 readback that is only the caller's own umask must not be read as an enforced mode, got '$out'"
  pass "private-lib: a umask that flatters the readback does not fool the probe"
}

test_probe_leaves_nothing_behind() {
  local dir out residue
  dir=$(case_dir probe-residue)
  mkdir -p "$dir/target"
  # The verdict is asserted first, so an empty directory cannot be read as a
  # tidy probe when what actually happened is that no probe ran.
  out=$(fs_eval "$(noacl_fs "$dir")" "
    fm_private_modes_enforcing '$dir/target' && echo enforcing || echo relaxed
  ")
  [ "$out" = relaxed ] || fail "the probe must have run and measured this mount, got '$out'"
  residue=$(find "$dir/target" -mindepth 1 | wc -l)
  [ "$residue" -eq 0 ] \
    || fail "the probe must remove its own temp file, $residue entries left in the target directory"
  pass "private-lib: the probe removes the temp file it measures"
}

# The one directory the probe cannot avoid writing into is the directory whose
# mode is in question, and it only ever gets there because that mode was
# already found wrong - which on a mode-carrying host can mean the directory is
# genuinely group-writable. Another account can unlink the probe there and
# leave a 644 file of its own behind, and a probe that believed it would report
# "this mount cannot carry modes" and waive the check that was catching the
# directory. The swap is staged as what it actually leaves: a probe file this
# user does not own.
test_probe_refuses_to_conclude_from_a_file_it_does_not_own() {
  local dir fakebin out
  dir=$(case_dir probe-foreign)
  mkdir -p "$dir/work"
  fakebin="$dir/fs-foreign"
  mkdir -p "$fakebin"
  fm_fake_noacl_stat "$fakebin"
  # Wrap that stat so the probe's own file reads back as another account's,
  # exactly as it would after the swap. Every other path answers normally, so
  # the case still exercises the real probe against the real filesystem.
  mv "$fakebin/stat" "$fakebin/stat-noacl"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'NOACL_STAT=%s\n' "$(printf '%q' "$fakebin/stat-noacl")"
    cat <<'SH'
ARG_FMT=
for a in "$@"; do case "$a" in %*) ARG_FMT=$a ;; esac; done
ARG_PATH=${*: -1}
case "$ARG_FMT:$ARG_PATH" in
  %u:*/.fm-private-probe.*) echo 4294967294; exit 0 ;;
esac
exec "$NOACL_STAT" "$@"
SH
  } > "$fakebin/stat"
  chmod +x "$fakebin/stat"

  out=$(fs_eval "$fakebin" "
    : > '$dir/work/f'
    device=\$(fm_private_stat_device '$dir/work/f') || exit 1
    fm_private_file_valid '$dir/work/f' 600 \"\$device\" && echo accepted || echo refused
    echo \"[\$FM_PRIVATE_MODE_UNENFORCEABLE]\"
  ")
  [ "$out" = "refused
[]" ] || fail "a probe file this user does not own must not waive anything, got '$out'"
  pass "private-lib: the probe draws no conclusion from a file this user does not own"
}

# The swap above is staged as already done. The interesting one is staged HALF
# done: the probe is still ours when the ownership question is asked and another
# account's by the time the modes are read back, which is exactly the window an
# unlink-and-recreate in a group-writable directory opens. A defence that asks
# once, before the measurement, waives the check on the strength of a file it no
# longer owns; the answer has to be re-taken after the readbacks.
test_probe_refuses_to_conclude_from_a_probe_swapped_mid_measurement() {
  local dir fakebin out
  dir=$(case_dir probe-swapped)
  mkdir -p "$dir/work"
  fakebin="$dir/fs-swapped"
  mkdir -p "$fakebin"
  fm_fake_noacl_stat "$fakebin"
  mv "$fakebin/stat" "$fakebin/stat-noacl"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'NOACL_STAT=%s\n' "$(printf '%q' "$fakebin/stat-noacl")"
    printf 'FIRST_ASK=%s\n' "$(printf '%q' "$dir/owner-asked-once")"
    printf 'OUR_UID=%s\n' "$(printf '%q' "$(id -u)")"
    cat <<'SH'
ARG_FMT=
for a in "$@"; do case "$a" in %*) ARG_FMT=$a ;; esac; done
ARG_PATH=${*: -1}
case "$ARG_FMT:$ARG_PATH" in
  %u:*/.fm-private-probe.*)
    if [ -e "$FIRST_ASK" ]; then
      echo 4294967294
    else
      : > "$FIRST_ASK"
      echo "$OUR_UID"
    fi
    exit 0
    ;;
esac
exec "$NOACL_STAT" "$@"
SH
  } > "$fakebin/stat"
  chmod +x "$fakebin/stat"

  out=$(fs_eval "$fakebin" "
    : > '$dir/work/f'
    device=\$(fm_private_stat_device '$dir/work/f') || exit 1
    fm_private_file_valid '$dir/work/f' 600 \"\$device\" && echo accepted || echo refused
    echo \"[\$FM_PRIVATE_MODE_UNENFORCEABLE]\"
  ")
  [ "$out" = "refused
[]" ] || fail "a probe swapped after its ownership check must not waive anything, got '$out'"
  pass "private-lib: the probe draws no conclusion from a file swapped mid-measurement"
}

test_probe_cannot_relax_a_directory_it_cannot_write() {
  local dir out
  dir=$(case_dir probe-unwritable)
  # A directory the probe cannot make a file in proves nothing about the
  # filesystem, so the strict branch has to stand. Named through a path that
  # does not exist, which no mount lets anyone write.
  out=$(fs_eval "$(noacl_fs "$dir")" "
    fm_private_modes_enforcing '$dir/absent/deeper/file' && echo enforcing || echo relaxed
  ")
  [ "$out" = enforcing ] \
    || fail "a probe that cannot run must leave the strict branch in force, got '$out'"
  pass "private-lib: a probe that cannot run does not relax anything"
}

# --- creating private state -------------------------------------------------

test_creation_carries_700_and_600_where_modes_are_enforcing() {
  local dir out
  dir=$(case_dir create-enforcing)
  out=$(fs_eval "$(enforcing_fs "$dir")" "
    fm_private_mkdir '$dir/state' || { echo mkdir-failed; exit 0; }
    : > '$dir/state/f' || { echo touch-failed; exit 0; }
    fm_private_chmod 0600 '$dir/state/f' || { echo chmod-failed; exit 0; }
    printf '%s %s %s\n' \
      \"\$(fm_private_stat_mode '$dir/state')\" \
      \"\$(fm_private_stat_mode '$dir/state/f')\" \
      \"[\$FM_PRIVATE_MODE_UNENFORCEABLE]\"
  ")
  [ "$out" = "700 600 []" ] \
    || fail "a private directory and file must really carry 700 and 600 where modes are enforcing, got '$out'"
  pass "private-lib: creation carries 700 and 600 where modes are enforcing"
}

test_creation_succeeds_and_is_recorded_where_modes_are_not_representable() {
  local dir out
  dir=$(case_dir create-noacl)
  out=$(fs_eval "$(noacl_fs "$dir")" "
    fm_private_mkdir '$dir/state' || { echo mkdir-failed; exit 0; }
    : > '$dir/state/f' || { echo touch-failed; exit 0; }
    fm_private_chmod 0600 '$dir/state/f' || { echo chmod-failed; exit 0; }
    device=\$(fm_private_stat_device '$dir/state') || exit 1
    fm_private_dir_valid '$dir/state' 700 \"\$device\" || { echo dir-refused; exit 0; }
    fm_private_file_valid '$dir/state/f' 600 \"\$device\" || { echo file-refused; exit 0; }
    fm_private_mode_unenforceable && echo \"recorded \$FM_PRIVATE_MODE_UNENFORCEABLE\" || echo not-recorded
  ")
  case "$out" in
    "recorded $dir/state"*) ;;
    *) fail "creation must succeed and record the unenforceable mode where it cannot be represented, got '$out'" ;;
  esac
  pass "private-lib: creation succeeds and records the waiver where a mode is not representable"
}

test_the_directory_creator_still_refuses_a_directory_that_exists() {
  local dir out fs
  dir=$(case_dir create-lock)
  # Several callers hold a lock by racing to create the directory, so the
  # relaxation must not turn the second creator into a winner. Both mounts.
  for fs in "$(enforcing_fs "$dir")" "$(noacl_fs "$dir")"; do
    rm -rf "$dir/lock"
    out=$(fs_eval "$fs" "
      fm_private_mkdir '$dir/lock' || { echo first-failed; exit 0; }
      fm_private_mkdir '$dir/lock' && echo second-won || echo second-refused
    ")
    [ "$out" = second-refused ] \
      || fail "the private directory creator must still refuse an existing directory on $fs, got '$out'"
  done
  pass "private-lib: creating a private directory still refuses one that exists, on both mounts"
}

# --- the assertion ----------------------------------------------------------

# The structural half of the assertion is not about modes at all, so it has to
# hold identically on a mount that carries them and one that does not.
assert_structural_refusal_on_both_mounts() {  # <name> <script> <what>
  local name=$1 script=$2 what=$3 dir fs out label
  dir=$(case_dir "$name")
  for label in enforcing noacl; do
    case "$label" in
      enforcing) fs=$(enforcing_fs "$dir") ;;
      *) fs=$(noacl_fs "$dir") ;;
    esac
    rm -rf "$dir/work"
    mkdir -p "$dir/work"
    out=$(fs_eval "$fs" "$script")
    [ "$out" = refused ] \
      || fail "the private-path assertion must refuse $what where modes are $label, got '$out'"
  done
  pass "private-lib: the assertion refuses $what on both mounts"
}

test_assertion_refuses_a_symlink() {
  local dir
  dir=$(case_dir assert-symlink)
  assert_structural_refusal_on_both_mounts assert-symlink "
    : > '$dir/work/real'
    fm_private_chmod 0600 '$dir/work/real' || exit 1
    ln -s '$dir/work/real' '$dir/work/link' || exit 1
    device=\$(fm_private_stat_device '$dir/work') || exit 1
    fm_private_file_valid '$dir/work/link' 600 \"\$device\" && echo accepted || echo refused
  " "a symlink"
}

test_assertion_refuses_a_wrong_device() {
  local dir
  dir=$(case_dir assert-device)
  assert_structural_refusal_on_both_mounts assert-device "
    : > '$dir/work/f'
    fm_private_chmod 0600 '$dir/work/f' || exit 1
    device=\$(fm_private_stat_device '$dir/work/f') || exit 1
    fm_private_file_valid '$dir/work/f' 600 \"\${device}9\" && echo accepted || echo refused
  " "a file on another device"
}

test_assertion_refuses_a_second_link() {
  local dir
  dir=$(case_dir assert-links)
  assert_structural_refusal_on_both_mounts assert-links "
    : > '$dir/work/f'
    fm_private_chmod 0600 '$dir/work/f' || exit 1
    ln '$dir/work/f' '$dir/work/second' || exit 1
    device=\$(fm_private_stat_device '$dir/work/f') || exit 1
    fm_private_file_valid '$dir/work/f' 600 \"\$device\" && echo accepted || echo refused
  " "a file with a second hard link"
}

test_assertion_refuses_a_wrong_mode_where_modes_are_enforcing() {
  local dir out
  dir=$(case_dir assert-wrong-mode)
  mkdir -p "$dir/work"
  out=$(fs_eval "$(enforcing_fs "$dir")" "
    : > '$dir/work/f'
    fm_private_chmod 0644 '$dir/work/f' || exit 1
    device=\$(fm_private_stat_device '$dir/work/f') || exit 1
    if fm_private_file_valid '$dir/work/f' 600 \"\$device\"; then echo accepted; else echo refused; fi
    echo \"[\$FM_PRIVATE_MODE_UNENFORCEABLE]\"
  ")
  [ "$out" = "refused
[]" ] || fail "a genuinely group-readable file must still be refused where modes are enforcing, and no waiver recorded, got '$out'"
  pass "private-lib: a genuinely wrong mode is still refused where modes are enforcing"
}

test_assertion_accepts_the_same_wrong_mode_where_modes_are_not_representable() {
  local dir out
  dir=$(case_dir assert-relaxed-mode)
  mkdir -p "$dir/work"
  # The same file, the same expectation, the other mount: the mode check is the
  # only thing that gives way, and it says so.
  out=$(fs_eval "$(noacl_fs "$dir")" "
    : > '$dir/work/f'
    device=\$(fm_private_stat_device '$dir/work/f') || exit 1
    if fm_private_file_valid '$dir/work/f' 600 \"\$device\"; then echo accepted; else echo refused; fi
    echo \"[\$FM_PRIVATE_MODE_UNENFORCEABLE]\"
  ")
  [ "$out" = "accepted
[$dir/work/f]" ] || fail "the mode check must give way, and record that it did, where a mode is not representable, got '$out'"
  pass "private-lib: the mode check gives way and records the waiver where a mode is not representable"
}

test_a_setter_that_fails_for_a_real_reason_still_fails() {
  local dir out fs label
  dir=$(case_dir setter-real-failure)
  # The relaxation is for a mode a filesystem cannot take, not for a path that
  # is not there. Both mounts must still refuse this.
  for label in enforcing noacl; do
    case "$label" in
      enforcing) fs=$(enforcing_fs "$dir") ;;
      *) fs=$(noacl_fs "$dir") ;;
    esac
    out=$(fs_eval "$fs" "
      fm_private_chmod 0600 '$dir/not-there' && echo accepted || echo refused
    ")
    [ "$out" = refused ] \
      || fail "chmod of an absent path must still fail where modes are $label, got '$out'"
  done
  pass "private-lib: a setter that fails for a reason other than the mode still fails, on both mounts"
}

test_probe_measures_a_mount_that_carries_modes
test_probe_measures_a_mount_that_drops_modes
test_probe_is_not_fooled_by_a_umask_that_flatters_the_readback
test_probe_leaves_nothing_behind
test_probe_refuses_to_conclude_from_a_file_it_does_not_own
test_probe_refuses_to_conclude_from_a_probe_swapped_mid_measurement
test_probe_cannot_relax_a_directory_it_cannot_write
test_creation_carries_700_and_600_where_modes_are_enforcing
test_creation_succeeds_and_is_recorded_where_modes_are_not_representable
test_the_directory_creator_still_refuses_a_directory_that_exists
test_assertion_refuses_a_symlink
test_assertion_refuses_a_wrong_device
test_assertion_refuses_a_second_link
test_assertion_refuses_a_wrong_mode_where_modes_are_enforcing
test_assertion_accepts_the_same_wrong_mode_where_modes_are_not_representable
test_a_setter_that_fails_for_a_real_reason_still_fails
