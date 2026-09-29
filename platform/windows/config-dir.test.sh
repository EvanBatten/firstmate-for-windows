#!/usr/bin/env bash
# A CLAUDE_CONFIG_DIR that a native parent such as claude.exe hands down arrives
# in drive spelling. Every bash the overlay starts must read it as an absolute
# path, and a native child must still get a path it can open.
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1
T=$(mktemp -d /tmp/fm-win-config-dir.XXXXXX)
trap 'rm -rf "$T"' EXIT

fails=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
expect() {
  case $3 in *"$2"*) ok "$1" ;; *) not_ok "$1 (got: $3)" ;; esac
}

git init -q -b main "$T/project"
git -C "$T/project" -c user.email=t@x.invalid -c user.name=t commit -q --allow-empty -m start
git -C "$T/project" worktree add -q "$T/wt" -b task
mkdir -p "$T/config"
drive=$(cygpath -w "$T/config")

expect "a bash under a native parent registers trust with a drive-spelled config dir" \
  "trusted: $T/wt" \
  "$(. platform/windows/env.sh; CLAUDE_CONFIG_DIR=$drive bash bin/fm-claude-trust.sh "$T/wt" "$T/project" 2>&1)"
expect "a pane shell reads the config dir as a POSIX path" \
  "$T/config" \
  "$(CLAUDE_CONFIG_DIR=$drive bash -c '. platform/windows/env.sh; printf %s "$CLAUDE_CONFIG_DIR"')"
expect "a native child still gets a Windows path" \
  "$(cygpath -m "$T/config")" \
  "$(CLAUDE_CONFIG_DIR=$drive bash -c '. platform/windows/env.sh; cmd //c "echo %CLAUDE_CONFIG_DIR%"')"

[ "$fails" -eq 0 ]
