#!/usr/bin/env bash
# shellcheck disable=SC2016
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1

T=$(mktemp -d /tmp/fm-win-env.XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/state"

fails=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
expect() {
  if [ "$3" = "$2" ]; then ok "$1"; else not_ok "$1 (want: $2, got: $3)"; fi
}
clean() { env -u FM_WIN_PRIVATE_ROOTS -u BASH_ENV -u FM_WIN_PRIOR_BASH_ENV -u FM_PLATFORM_OVERLAY "$@"; }

probe='[ -f "$FM_PLATFORM_OVERLAY" ] && [ "$FM_PLATFORM_OVERLAY" -ef platform/windows/overrides.sh ] && o=on || o=off
[ "${PATH%%:*}" -ef platform/windows/bin ] && p=first || p=missing
[ -n "${BASH_ENV:-}" ] && [ "$BASH_ENV" -ef platform/windows/bash-env.sh ] && b=set || b=unset
echo "overlay=$o bin=$p bash_env=$b umask=$(umask)"'
want='overlay=on bin=first bash_env=set umask=0077 stderr='
export T probe

for spelling in posix mixed windows; do
  case $spelling in
    posix) src=$ROOT/platform/windows/env.sh ;;
    mixed) src=$(cygpath -m "$ROOT/platform/windows/env.sh") ;;
    windows) src=$(cygpath -w "$ROOT/platform/windows/env.sh") ;;
  esac
  got=$(clean FM_HOME="$T/home" bash -c '. "$1" 2> "$T/err"; eval "$probe"; echo "stderr=$(cat "$T/err")"' _ "$src" | tr '\n' ' ')
  expect "env.sh sourced by its $spelling path turns the overlay on for a private home" "$want" "${got% }"
done

src=$(cygpath -m "$ROOT/platform/windows/env.sh")
roots=$(cygpath -m "$T/home")
got=$(clean FM_HOME="$T/home" FM_WIN_PRIVATE_ROOTS="$roots" bash -c '. "$1" 2> "$T/err"; eval "$probe"; echo "stderr=$(cat "$T/err")"' _ "$src" | tr '\n' ' ')
expect "a drive-path re-source of a home already recorded private exports the real bash-env.sh" "$want" "${got% }"
got=$(clean FM_HOME="$T/home" FM_WIN_PRIVATE_ROOTS="$roots" bash -c '. "$1"; MSYS2_ARG_CONV_EXCL="*" cmd.exe /c "bash -c umask"' _ "$src" | tr -d '\r')
expect "a bash under a native parent then runs at 077" "0077" "$got"

[ "$fails" -eq 0 ]
