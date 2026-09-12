#!/usr/bin/env bash
# E2E: run the real bin/fm-pr-merge.sh from a given code root against a real
# FM_HOME on this host's Git Bash noacl mount (no stat fixture), with only the
# forge CLIs (gh, gh-axi) faked. Prints a transcript of what an operator sees.
# usage: e2e-pr-merge-noacl.sh <code-root> <label>
set -u
root=$1 label=$2
work=$(mktemp -d "${TMPDIR:-/tmp}/fm-e2e-merge-$label.XXXXXX")
home="$work/home"
mkdir -p "$home/state" "$work/fakebin" "$work/wt"
printf '%s\n' "window=fm-task-x1" "worktree=$work/wt" "project=$work/project" \
  "kind=ship" "mode=no-mistakes" > "$home/state/task-x1.meta"
cat > "$work/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$E2E_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view") printf 'pull_request:\n  number: %s\n  state: merged\n' "$3" ;;
esac
exit 0
SH
cat > "$work/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") case " $* " in *headRefOid*) echo 7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c ;; esac ;;
  "api graphql") printf '%s\n' state=MERGED merged=true queued=false base=main ;;
  api\ *) : ;;
esac
exit 0
SH
chmod +x "$work/fakebin/gh-axi" "$work/fakebin/gh"
: > "$work/gh-axi.log"

echo "## $label: code root $(cd "$root" && git rev-parse --short HEAD 2>/dev/null || echo "$root")"
echo "\$ mount | grep ' on /tmp '"
mount | grep ' on /tmp '
echo "\$ FM_HOME=$home bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/24"
E2E_GH_AXI_LOG="$work/gh-axi.log" FM_HOME="$home" PATH="$work/fakebin:$PATH" \
  "$root/bin/fm-pr-merge.sh" task-x1 https://github.com/example/repo/pull/24 \
  > "$work/stdout" 2> "$work/stderr"
rc=$?
echo "exit code: $rc"
echo "--- stdout"; cat "$work/stdout"
echo "--- stderr"; cat "$work/stderr"
echo "--- forge calls (gh-axi)"; cat "$work/gh-axi.log"
echo "--- state/task-x1.meta"; cat "$home/state/task-x1.meta"
echo "--- state/ listing (stat mode as this mount reports it)"
for f in "$home"/state/*; do printf '%s %s\n' "$(stat -c %a "$f")" "${f##*/}"; done
rm -rf "$work"
