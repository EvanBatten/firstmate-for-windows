#!/usr/bin/env bash
# Re-measure tests/fm-claude-stop-autoarm.test.sh on WSL Ubuntu at the SHIPPING
# head of fm/issue-10 (405cb84, after the two review commits touched the same
# fixture) and at the base commit 5ed6c5e, for the ledger's Issue #10 section.
#
# The shipping head is delivered as a git bundle rather than fetched from the
# pipeline worktree: that worktree's .git is a pointer file naming a Windows
# drive path, which git inside WSL cannot resolve.
set -u

EV=/mnt/c/Users/ebatt/.no-mistakes/evidence/01M1TQZ57PW7VZT8WP5W02S5G1
BUNDLE="$EV/i10-head.bundle"
BASE=5ed6c5e

cd ~/fm || { echo "NO ~/fm"; exit 1; }
echo "== repo:   $(pwd)"
echo "== distro: $(. /etc/os-release; echo "$PRETTY_NAME")"
echo "== kernel: $(uname -sr)"
echo "== bash:   $BASH_VERSION"
echo "== start state: $(git log --oneline -1) / dirty: $(git status --porcelain | wc -l)"

git fetch -q "$BUNDLE" refs/heads/fm/issue-10 || { echo "FETCH FAILED"; exit 1; }
echo "== FETCH_HEAD: $(git log --oneline -1 FETCH_HEAD)"
HEADREV=$(git rev-parse FETCH_HEAD)

run_at() {
  local rev=$1 label=$2 log start end rc ok notok
  git checkout -q --detach "$rev" || { echo "CHECKOUT $rev FAILED"; return 1; }
  log="$EV/wsl-$label.log"
  start=$(date +%s)
  timeout 900 bash tests/fm-claude-stop-autoarm.test.sh >"$log" 2>&1
  rc=$?
  end=$(date +%s)
  ok=$(grep -c '^ok - ' "$log")
  notok=$(grep -c '^not ok - ' "$log")
  echo "RESULT $label rev=$(git rev-parse --short HEAD) rc=$rc ok=$ok not_ok=$notok elapsed=$((end - start))s log=$log"
}

run_at "$HEADREV" branch-head
run_at "$BASE" base

git checkout -q --detach "$BASE"
echo "== final state: $(git log --oneline -1) / dirty: $(git status --porcelain | wc -l)"
