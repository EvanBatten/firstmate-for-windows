# shellcheck shell=bash
# On a noacl drive the mode stat reports comes from the reading process's
# umask, and the overlay runs firstmate at 077 (env.sh), so a test that checks
# a mode must read it at 077 too or it sees 755 where firstmate sees 700 on the
# same directory.
umask 077

# Every git lock counts as held here (overrides.sh), so no case can prove one stale.
fm_test_lock_staleness_provable() {
  printf 'skip: %s: no git lock is provably stale on Windows\n' "$1"
  return 1
}
