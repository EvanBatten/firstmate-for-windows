#!/usr/bin/env bash
# shellcheck disable=SC2016 # The quoted scripts run in child shells, which expand them.
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1

T=$(mktemp -d /tmp/fm-win-privacy.XXXXXX)
trap 'rm -rf "$T"' EXIT
P=$T/private O=$T/open
mkdir -p "$P/state" "$O/state" "$T/fakebin"
MSYS2_ARG_CONV_EXCL='*' icacls "$(cygpath -w "$O")" /grant '*S-1-5-32-545:(OI)(CI)R' > /dev/null

fails=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
expect() {
  case $3 in *"$2"*) ok "$1" ;; *) not_ok "$1 (got: $3)" ;; esac
}

probe() {
  printf 'umask=%s bash_env=%s mode=%s fmx=' "$(umask)" "${BASH_ENV:+set}" "$(stat -c %a "$FM_HOME/state")"
  ( . bin/fm-x-lib.sh 2> /dev/null; mkdir -p "$FM_HOME/state/x"; fmx_private_artifact_dir_device "$FM_HOME/state/x" > /dev/null && echo pass || echo refuse )
}
export -f probe
clean() { env -u FM_WIN_PRIVATE_ROOTS -u BASH_ENV -u FM_WIN_PRIOR_BASH_ENV -u FM_PLATFORM_OVERLAY "$@"; }
export P O

expect "an open home keeps umask 022 and upstream refuses it" \
  "umask=0022 bash_env= mode=755 fmx=refuse" \
  "$(clean FM_HOME="$O" bash -c '. platform/windows/env.sh 2> /dev/null; probe')"
expect "a private home runs at 077 and upstream accepts it" \
  "umask=0077 bash_env=set mode=700 fmx=pass" \
  "$(clean FM_HOME="$P" bash -c '. platform/windows/env.sh; probe')"
expect "a private-home shell that re-sources for an open home drops to 022" \
  "umask=0022 bash_env= mode=755 fmx=refuse" \
  "$(clean FM_HOME="$P" bash -c '. platform/windows/env.sh; FM_HOME=$O bash -c ". platform/windows/env.sh 2> /dev/null; probe"')"
expect "a child bash for an open home under a private-home shell runs at 022" \
  "umask=0022" \
  "$(clean FM_HOME="$P" bash -c '. platform/windows/env.sh; FM_HOME=$O bash -c probe')"
expect "upstream refuses that open home in the child" \
  "fmx=refuse" \
  "$(clean FM_HOME="$P" bash -c '. platform/windows/env.sh; FM_HOME=$O bash -c probe')"
expect "a child bash for the private home still runs at 077" \
  "umask=0077 bash_env=set mode=700 fmx=pass" \
  "$(clean FM_HOME="$P" bash -c '. platform/windows/env.sh; bash -c probe')"
expect "a bash under a native parent keeps 077 for the private home" \
  "umask=0077" \
  "$(clean FM_HOME="$P" bash -c '. platform/windows/env.sh; MSYS2_ARG_CONV_EXCL="*" cmd.exe /c "bash -c umask"' | sed 's/^/umask=/')"
expect "a bash under a native parent gets 022 for an open home" \
  "umask=0022" \
  "$(clean FM_HOME="$P" bash -c '. platform/windows/env.sh; FM_HOME=$O MSYS2_ARG_CONV_EXCL="*" cmd.exe /c "bash -c umask"' | sed 's/^/umask=/')"

rc_of() { clean PATH="$1" bash platform/windows/private-root.sh check "$2" > /dev/null 2>&1; echo "rc=$?"; }
expect "without icacls an open root is open" "rc=1" "$(rc_of /usr/bin "$O")"
expect "without icacls a private root is open" "rc=1" "$(rc_of /usr/bin "$P")"
printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/icacls"
expect "icacls with no output reads open" "rc=1" "$(rc_of "$T/fakebin:/usr/bin" "$P")"
printf '#!/bin/sh\necho "$1 NT AUTHORITY\\\\SYSTEM:(F)"\nexit 5\n' > "$T/fakebin/icacls"
expect "icacls that fails reads open" "rc=1" "$(rc_of "$T/fakebin:/usr/bin" "$P")"
expect "a private root with icacls present is private" "rc=0" "$(rc_of "$PATH" "$P")"

[ "$fails" -eq 0 ]
