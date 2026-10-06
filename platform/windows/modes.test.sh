#!/usr/bin/env bash
# shellcheck disable=SC2016
set -u
ROOT=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)
cd "$ROOT" || exit 1

T=$(mktemp -d /tmp/fm-win-modes.XXXXXX)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/state" "$T/home/data" "$T/home/config" "$T/wt" "$T/fakebin"

fails=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; fails=$((fails + 1)); }
expect() {
  if [ "$3" = "$2" ]; then ok "$1"; else not_ok "$1 (want: $2, got: $3)"; fi
}

export FM_HOME="$T/home"
# shellcheck source=platform/windows/env.sh
. platform/windows/env.sh
STATE=$FM_HOME/state

printf '#!/bin/sh\n' > "$T/shebang" && chmod 0600 "$T/shebang"
printf 'plain\n' > "$T/plain" && chmod 0700 "$T/plain"
expect "the drive derives the execute bit from content, not chmod" "700 600" \
  "$(stat -c %a "$T/shebang") $(stat -c %a "$T/plain")"

git -C "$T/wt" init -q && git -C "$T/wt" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
HEAD_SHA=$(git -C "$T/wt" rev-parse HEAD)
cat > "$T/fakebin/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" pr view "*statusCheckRollup*) printf '%s\n' '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$HEAD_SHA","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}' ;;
  *" --json isDraft "*) printf '%s\n' '{"isDraft":false}' ;;
  *headRefOid,reviewDecision*) printf '%s\n' '{"headRefOid":"$HEAD_SHA","reviewDecision":"APPROVED"}' ;;
  *" pr merge "*) : > "$T/merged" ;;
  *" api graphql "*) if [ -e "$T/merged" ]; then printf 'state=MERGED\nmerged=true\nqueued=false\nbase=main\n'; else printf 'state=OPEN\nmerged=false\nqueued=false\nbase=main\n'; fi ;;
  *" api --paginate repos/"*"/rules/branches/"*merge_queue*) ;;
  *" api --paginate repos/"*"/rules/branches/"*) printf '[]\n' ;;
  *" api repos/"*"/branches/"*) printf '{"name":"main","protected":false}\n' ;;
  *" api repos/"*"/pulls/"*) printf '{"state":"open","user":{"login":"author"},"head":{"sha":"$HEAD_SHA"},"draft":false,"mergeable":true,"merged_at":null}\n' ;;
  *" api repos/"*) printf '{"permissions":{"push":true}}\n' ;;
  *" headRefOid "*) printf '%s\n' "$HEAD_SHA" ;;
  *" state "*) if [ -e "$T/merged" ]; then echo MERGED; else echo OPEN; fi ;;
esac
SH
chmod +x "$T/fakebin/gh"
printf 'kind=ship\nworktree=%s\nproject=demo\n' "$T/wt" > "$STATE/demo-1.meta"
URL=https://github.com/example/demo/pull/7

out=$(PATH="$T/fakebin:$PATH" bin/fm-pr-check.sh demo-1 "$URL" 2>&1 | grep -v '^●')
expect "fm-pr-check.sh arms a merge poll" "armed: state/demo-1.check.sh" "${out##*$'\n'}"
expect "the armed check is the static poll program" "same" \
  "$(cmp -s bin/fm-pr-poll.sh "$STATE/demo-1.check.sh" && echo same || echo differs)"
expect "the watcher accepts the armed poll" "valid" "$(
  . bin/fm-pr-lib.sh
  fm_pr_poll_artifacts_valid "$STATE" demo-1 bin/fm-pr-poll.sh && echo valid || echo refused
)"

PATH="$T/fakebin:$PATH" bin/fm-pr-merge.sh demo-1 "$URL" > "$T/merge.out" 2>&1
expect "fm-pr-merge.sh merges a clean green PR" "rc=0 merged=yes" \
  "rc=$? merged=$([ -e "$T/merged" ] && echo yes || echo no)"

for kind in shebang plain; do
  if [ "$kind" = shebang ]; then
    printf '#!/usr/bin/env bash\necho custom-%s\n' "$kind"
  else
    printf 'echo custom-%s\n' "$kind"
  fi > "$STATE/c-$kind.check.sh"
  chmod 0700 "$STATE/c-$kind.check.sh"
  expect "a $kind custom check registers" "registered: state/c-$kind.check.sh" \
    "$(bin/fm-check-register.sh "c-$kind" 2>&1)"
  expect "the watcher runs a registered $kind custom check" "custom-$kind" "$(
    . bin/fm-pr-lib.sh
    . bin/fm-check-lib.sh
    fm_custom_check_snapshot_prepare "$STATE" "c-$kind" && bash "$FM_CUSTOM_CHECK_SNAPSHOT"
    fm_custom_check_snapshot_cleanup
  )"
done

device=$(stat -c %d "$STATE")
cp bin/fm-pr-poll.sh "$STATE/poll-copy" && cp bin/fm-pr-poll.sh "$STATE/linked" && ln "$STATE/linked" "$STATE/linked2"
expect "a private poll copy is accepted" "accepted" "$(
  . bin/fm-pr-lib.sh
  fm_pr_private_file_valid "$STATE/poll-copy" 600 "$device" && echo accepted || echo refused
)"
expect "a group-readable reading, a hard link and a symlink stay refused" "refused refused refused" "$(
  . bin/fm-pr-lib.sh
  for path in group linked link; do
    case $path in
      group) (umask 022; fm_pr_private_file_valid "$STATE/poll-copy" 600 "$device") ;;
      linked) fm_pr_private_file_valid "$STATE/linked" 600 "$device" ;;
      link) ln -s "$STATE/poll-copy" "$STATE/link" && fm_pr_private_file_valid "$STATE/link" 600 "$device" ;;
    esac && printf 'accepted ' || printf 'refused '
  done | sed 's/ $//'
)"

[ "$fails" -eq 0 ]
