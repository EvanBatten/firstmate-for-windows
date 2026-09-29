# shellcheck shell=bash
# Sourced by the hook at the end of tests/lib.sh, after it pins the fixture
# umask to 022. On a noacl drive the mode stat reports comes from the reading
# process's umask, and the overlay runs firstmate at 077 (env.sh), so a test
# that checks a mode must read it at 077 too or it sees 755 where firstmate
# sees 700 on the same directory.
umask 077
