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

# Git for Windows ships no C compiler, so the fake Cursor is a copy of bash.exe,
# which MSYS names by its own file. Bash execs the last command of a -c script in
# place of itself unless an EXIT trap is set, which would drop the Cursor parent,
# so BASH_ENV sets one in that copy alone.
fm_test_fake_cursor() {
  local bin=$1 scratch=$2
  cp /usr/bin/bash.exe "$bin/cursor-agent.exe" || fail "could not copy bash for the fake Cursor process"
  {
    printf '. %q\n' "$BASH_ENV"
    # shellcheck disable=SC2016 # Expanded by the fake Cursor bash.
    printf '%s\n' 'case $BASH in */cursor-agent*) trap "exit \$?" EXIT ;; esac'
  } > "$scratch/fake-cursor.rc"
  export BASH_ENV=$scratch/fake-cursor.rc
  # shellcheck disable=SC2034 # Read by the calling suite.
  FAKE_CURSOR=$bin/cursor-agent
}

# Git for Windows keeps git in /mingw64/bin, not /usr/bin, so a fixture's
# minimal PATH needs that directory to reach git at all.
FM_TEST_BASE_PATH=${FM_TEST_BASE_PATH:-/mingw64/bin:/usr/bin:/bin:/usr/sbin:/sbin}
