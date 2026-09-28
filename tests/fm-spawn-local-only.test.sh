#!/usr/bin/env bash
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-local-only)

make_case() {
  local name=$1 id=$2 case_dir home project pool fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  printf 'landed after the pool was allocated\n' > "$project/advanced-main.txt"
  git -C "$project" add advanced-main.txt
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-main

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR INITIAL_SHA <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" "$@"
}

test_no_origin_spawns_from_local_default_branch() {
  local rec id out status local_main
  id='local-only-no-origin-r1'
  rec=$(make_case no-origin "$id")
  read_case_record "$rec"
  local_main=$(git -C "$PROJECT_DIR" rev-parse refs/heads/main)

  out=$(run_spawn "$id" --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should launch for a project with no origin remote"
  assert_contains "$out" "spawned $id" "spawn did not report success for a project with no origin remote"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$local_main" ] \
    || fail "spawn did not start the pooled worktree at the local main tip"
  [ "$local_main" != "$INITIAL_SHA" ] || fail "fixture did not prove local main advanced past the pool base"
  assert_grep 'landed after the pool was allocated' "$POOL_DIR/advanced-main.txt" \
    "the pooled worktree omitted the commit that landed on local main"
  pass "a project with no origin remote spawns from its current local main"
}

test_unfetchable_origin_still_refuses() {
  local rec id out status before
  id='local-only-unfetchable-origin-r2'
  rec=$(make_case unfetchable-origin "$id")
  read_case_record "$rec"
  git -C "$PROJECT_DIR" remote add origin "file://$CASE_DIR/missing-origin.git"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode local-only --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an origin that cannot be fetched"
  assert_contains "$out" "could not fetch origin" \
    "spawn did not clearly refuse an origin that cannot be fetched"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved the pooled worktree after failing to fetch origin"
  pass "a project whose origin cannot be fetched is still refused"
}

test_no_origin_spawns_from_local_default_branch
test_unfetchable_origin_still_refuses

echo "# all fm-spawn-local-only tests passed"
