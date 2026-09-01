#!/usr/bin/env bash
# GitHub workflow lint gate owned by bin/fm-lint-workflows.sh.
#
# A malformed .github/workflows/*.yml, including a self-broken ci.yml, must fail
# in the local/no-mistakes lint path before merge. Regression origin: #2512 put
# a column-0 heredoc body inside a `run: |` block in ci.yml; there was no
# workflow YAML lint, and the broken workflow could not report its own breakage.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT_WF="$ROOT/bin/fm-lint-workflows.sh"
LINT="$ROOT/bin/fm-lint.sh"
INSTALLER="$ROOT/bin/fm-install-actionlint.sh"
REQUIRED=$("$LINT_WF" --required-version)

# Official sha256 values from actionlint_1.7.12_checksums.txt on the v1.7.12
# release (https://github.com/rhysd/actionlint/releases/tag/v1.7.12). Tests
# compare installer behavior against these published digests, not script source.
ACTIONLINT_SHA_LINUX_AMD64=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
ACTIONLINT_SHA_LINUX_ARM64=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
ACTIONLINT_SHA_DARWIN_AMD64=5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644
ACTIONLINT_SHA_DARWIN_ARM64=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f
ACTIONLINT_SHA_WINDOWS_AMD64=6e7241b51e6817ea6a047693d8e6fed13b31819c9a0dd6c5a726e1592d22f6e9

fm_install_stub_uname() {
  local fakebin=$1
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' "${FM_TEST_UNAME_S:-Linux}" ;;
  -m) printf '%s\n' "${FM_TEST_UNAME_M:-x86_64}" ;;
  *) printf '%s\n' "${FM_TEST_UNAME_S:-Linux}" ;;
esac
SH
  chmod +x "$fakebin/uname"
}

fm_install_stub_curl() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "${CURL_COUNT:-}" ] || count=$(cat "$CURL_COUNT")
count=$((count + 1))
[ -z "${CURL_COUNT:-}" ] || printf '%s\n' "$count" > "$CURL_COUNT"
url=
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out=$2
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url=$1
      shift
      ;;
  esac
done
[ -z "${CURL_URL_LOG:-}" ] || printf '%s\n' "$url" >> "$CURL_URL_LOG"
fail_until=${CURL_FAIL_UNTIL:-0}
[ "$count" -gt "$fail_until" ] || exit 22
: > "$out"
exit 0
SH
  chmod +x "$fakebin/curl"
}

fm_install_stub_hasher() {
  local fakebin=$1 name=$2
  cat > "$fakebin/$name" <<'SH'
#!/usr/bin/env bash
self=${0##*/}
if [ -n "${HASHER_LOG:-}" ]; then
  printf '%s\n' "$self $*" >> "$HASHER_LOG"
fi
file=$1
if [ "$self" = shasum ]; then
  algo=
  file=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -a)
        algo=$2
        shift 2
        ;;
      *)
        file=$1
        shift
        ;;
    esac
  done
  [ "$algo" = 256 ] || exit 1
fi
# GNU coreutils escapes a file operand containing a backslash and prefixes
# the whole line with one, which is what a Windows RUNNER_TEMP (D:\a\_temp)
# produces on a GitHub Actions runner.
case "$file" in
  *\\*)
    printf '\\%s  %s\n' "${SHA256_STUB_HASH:?}" "$(printf '%s' "$file" | sed 's/\\/\\\\/g')"
    ;;
  *)
    printf '%s  %s\n' "${SHA256_STUB_HASH:?}" "$file"
    ;;
esac
SH
  chmod +x "$fakebin/$name"
}

fm_install_stub_tar_actionlint() {
  local fakebin=$1
  cat > "$fakebin/tar" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-C" ]; then
    cat > "$2/actionlint" <<'EOF'
#!/usr/bin/env bash
printf '1.7.12\n'
EOF
    chmod +x "$2/actionlint"
    exit 0
  fi
  shift
done
exit 2
SH
  chmod +x "$fakebin/tar"
}

fm_install_stub_unzip_actionlint() {
  local fakebin=$1
  cat > "$fakebin/unzip" <<'SH'
#!/usr/bin/env bash
dest=
archive=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d)
      dest=$2
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      archive=$1
      shift
      ;;
  esac
done
[ -n "$dest" ] || exit 2
# Refuse an archive the installer never downloaded, so a wrong operand cannot
# still produce a working install.
[ -f "$archive" ] || exit 3
mkdir -p "$dest"
cat > "$dest/actionlint.exe" <<'EOF'
#!/usr/bin/env bash
printf '1.7.12\n'
EOF
chmod +x "$dest/actionlint.exe"
exit 0
SH
  chmod +x "$fakebin/unzip"
}

fm_install_stub_sleep() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
}

write_valid_workflow() {
  local path=$1
  cat > "$path" <<'YAML'
name: CI
on: push
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - run: |
          set -eu
          echo ok
YAML
}

# #2512-class breakage: a heredoc body at column 0 inside a `run: |` block.
write_col0_heredoc_workflow() {
  local path=$1
  cat > "$path" <<'YAML'
name: CI
on: push
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - name: Compatibility pointers must stay intact
        run: |
          set -eu
          cmp -s CLAUDE.md - <<'EOF' || exit 1
<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->
@AGENTS.md
EOF
          echo ok
YAML
}

test_current_workflows_pass() {
  local out rc
  rc=0
  out=$("$LINT_WF" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "current workflows must parse, got $rc"$'\n'"$out"
  assert_contains "$out" "workflow files valid" \
    "current-workflow lint did not report a valid count"
  pass "current .github/workflows YAML files parse"
}

test_col0_heredoc_fails_with_clear_error() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-wf-col0)
  mkdir -p "$tmp/.github/workflows"
  write_col0_heredoc_workflow "$tmp/.github/workflows/ci.yml"
  rc=0
  out=$("$LINT_WF" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "column-0 heredoc workflow unexpectedly passed"$'\n'"$out"
  assert_contains "$out" "could not parse as YAML" \
    "column-0 heredoc failure did not report actionlint's YAML syntax error"
  assert_contains "$out" "ci.yml" \
    "column-0 heredoc failure did not name the workflow file"
  pass "column-0 heredoc workflow fails validation with a clear error"
}

test_valid_fixture_passes() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-wf-ok)
  mkdir -p "$tmp/.github/workflows"
  write_valid_workflow "$tmp/.github/workflows/ci.yml"
  rc=0
  out=$("$LINT_WF" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "valid fixture workflow failed"$'\n'"$out"
  assert_contains "$out" "1 workflow files valid" \
    "valid fixture did not report one valid file"
  pass "valid fixture workflow passes"
}

test_empty_workflows_dir_fails() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-wf-empty)
  mkdir -p "$tmp/.github/workflows"
  rc=0
  out=$("$LINT_WF" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "empty workflows dir unexpectedly passed"$'\n'"$out"
  assert_contains "$out" "no GitHub workflow files found" \
    "empty workflows dir did not report the missing files"
  pass "empty workflows directory fails closed"
}

test_explicit_broken_path_fails() {
  local tmp broken out rc
  tmp=$(fm_test_tmproot fm-lint-wf-path)
  broken="$tmp/broken.yml"
  write_col0_heredoc_workflow "$broken"
  rc=0
  out=$("$LINT_WF" "$broken" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "explicit broken path unexpectedly passed"$'\n'"$out"
  assert_contains "$out" "could not parse as YAML" \
    "explicit broken path did not report actionlint's YAML syntax error"
  pass "explicit malformed workflow path fails validation"
}

test_non_mapping_root_fails() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-lint-wf-scalar)
  mkdir -p "$tmp/.github/workflows"
  printf 'just-a-string\n' > "$tmp/.github/workflows/ci.yml"
  rc=0
  out=$("$LINT_WF" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "scalar YAML root unexpectedly passed"$'\n'"$out"
  assert_contains "$out" "mapping node is expected" \
    "scalar YAML root did not report actionlint's mapping-node error"
  pass "non-mapping workflow YAML root fails"
}

test_missing_actionlint_fails_closed() {
  local tmp fakebin out rc tool
  tmp=$(fm_test_tmproot fm-lint-wf-noactionlint)
  fakebin=$(fm_fakebin "$tmp")
  mkdir -p "$tmp/.github/workflows"
  write_valid_workflow "$tmp/.github/workflows/ci.yml"
  fm_fakebin_link "$fakebin" bash dirname find sort awk
  rc=0
  out=$(PATH="$fakebin" "$LINT_WF" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "missing actionlint expected exit 1, got $rc"$'\n'"$out"
  assert_contains "$out" "actionlint not found" \
    "missing actionlint did not name the required linter"
  assert_contains "$out" "$REQUIRED" \
    "missing actionlint did not name the pinned version"
  assert_contains "$out" "fm-install-actionlint.sh" \
    "missing actionlint did not name the pinned installer"
  pass "missing actionlint fails closed"
}

test_pins_an_explicit_version() {
  [ -n "$REQUIRED" ] || fail "fm-lint-workflows.sh --required-version printed nothing"
  assert_contains "$REQUIRED" "1.7.12" "fm-lint-workflows.sh must pin actionlint 1.7.12"
  pass "fm-lint-workflows.sh pins an explicit actionlint version ($REQUIRED)"
}

test_rejects_wrong_actionlint_version() {
  local tmp fakebin out rc
  tmp=$(fm_test_tmproot fm-lint-wf-ver)
  fakebin=$(fm_fakebin "$tmp")
  mkdir -p "$tmp/.github/workflows"
  write_valid_workflow "$tmp/.github/workflows/ci.yml"
  cat > "$fakebin/actionlint" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-version" ]; then
  printf '0.0.0\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/actionlint"
  rc=0
  out=$(PATH="$fakebin:$PATH" "$LINT_WF" --root "$tmp" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint-workflows.sh accepted an actionlint version other than the pin"$'\n'"$out"
  assert_contains "$out" "$REQUIRED" "fm-lint-workflows.sh did not name the required version on mismatch"
  assert_contains "$out" "0.0.0" "fm-lint-workflows.sh did not report the resolved (wrong) version"
  pass "fm-lint-workflows.sh refuses to lint under a non-pinned actionlint version"
}

test_installer_retries_transient_download_failure() {
  local tmp fakebin destination out
  tmp=$(fm_test_tmproot fm-actionlint-download)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" sha256sum
  fm_install_stub_tar_actionlint "$fakebin"
  fm_install_stub_sleep "$fakebin"

  out=$(CURL_COUNT="$tmp/curl-count" CURL_FAIL_UNTIL=3 \
    SHA256_STUB_HASH="$ACTIONLINT_SHA_LINUX_AMD64" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer did not recover from a transient download failure"$'\n'"$out"
  [ "$(cat "$tmp/curl-count")" -eq 4 ] || fail "installer did not recover after three failed downloads"
  assert_contains "$out" "download attempt 3 failed; retrying" "installer did not disclose its third retry"
  [ -x "$destination/actionlint" ] || fail "installer did not install actionlint after retrying"
  pass "actionlint installer retries a transient download failure"
}

test_installer_selects_platform_archive_url_and_checksum() {
  local tmp fakebin destination out url_log uname_s uname_m archive sha binary
  tmp=$(fm_test_tmproot fm-actionlint-platform)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  url_log="$tmp/curl-url.log"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" sha256sum
  fm_install_stub_tar_actionlint "$fakebin"
  fm_install_stub_unzip_actionlint "$fakebin"
  fm_install_stub_sleep "$fakebin"

  while IFS=$'\t' read -r uname_s uname_m archive sha binary; do
    [ -n "$uname_s" ] || continue
    rm -rf "$destination"
    : > "$url_log"
    out=$(CURL_URL_LOG="$url_log" SHA256_STUB_HASH="$sha" \
      FM_TEST_UNAME_S="$uname_s" FM_TEST_UNAME_M="$uname_m" \
      PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
      || fail "installer failed for ${uname_s}/${uname_m}"$'\n'"$out"
    assert_contains "$(cat "$url_log")" "$archive" \
      "installer did not download $archive for ${uname_s}/${uname_m}"
    assert_contains "$(cat "$url_log")" \
      "https://github.com/rhysd/actionlint/releases/download/v${REQUIRED}/${archive}" \
      "installer used the wrong URL for ${uname_s}/${uname_m}"
    [ -x "$destination/$binary" ] \
      || fail "installer did not install $binary for ${uname_s}/${uname_m}"
  done <<EOF
Linux	x86_64	actionlint_${REQUIRED}_linux_amd64.tar.gz	$ACTIONLINT_SHA_LINUX_AMD64	actionlint
Linux	amd64	actionlint_${REQUIRED}_linux_amd64.tar.gz	$ACTIONLINT_SHA_LINUX_AMD64	actionlint
Linux	aarch64	actionlint_${REQUIRED}_linux_arm64.tar.gz	$ACTIONLINT_SHA_LINUX_ARM64	actionlint
Linux	arm64	actionlint_${REQUIRED}_linux_arm64.tar.gz	$ACTIONLINT_SHA_LINUX_ARM64	actionlint
Darwin	x86_64	actionlint_${REQUIRED}_darwin_amd64.tar.gz	$ACTIONLINT_SHA_DARWIN_AMD64	actionlint
Darwin	amd64	actionlint_${REQUIRED}_darwin_amd64.tar.gz	$ACTIONLINT_SHA_DARWIN_AMD64	actionlint
Darwin	arm64	actionlint_${REQUIRED}_darwin_arm64.tar.gz	$ACTIONLINT_SHA_DARWIN_ARM64	actionlint
Darwin	aarch64	actionlint_${REQUIRED}_darwin_arm64.tar.gz	$ACTIONLINT_SHA_DARWIN_ARM64	actionlint
MINGW64_NT-10.0-26200	x86_64	actionlint_${REQUIRED}_windows_amd64.zip	$ACTIONLINT_SHA_WINDOWS_AMD64	actionlint.exe
MSYS_NT-10.0-26200	x86_64	actionlint_${REQUIRED}_windows_amd64.zip	$ACTIONLINT_SHA_WINDOWS_AMD64	actionlint.exe
EOF
  pass "actionlint installer selects the official archive, URL, and checksum per OS/arch"
}

test_installer_rejects_wrong_checksum() {
  local tmp fakebin destination out rc
  tmp=$(fm_test_tmproot fm-actionlint-badsum)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" sha256sum
  fm_install_stub_tar_actionlint "$fakebin"
  fm_install_stub_sleep "$fakebin"

  rc=0
  out=$(SHA256_STUB_HASH=0000000000000000000000000000000000000000000000000000000000000000 \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted a wrong checksum"$'\n'"$out"
  assert_contains "$out" "checksum mismatch" "installer did not report a checksum mismatch"
  assert_contains "$out" "actionlint_${REQUIRED}_linux_amd64.tar.gz" \
    "mismatch did not name the selected archive"
  assert_contains "$out" "$ACTIONLINT_SHA_LINUX_AMD64" \
    "mismatch did not name the pinned linux/amd64 checksum"
  [ ! -e "$destination/actionlint" ] || fail "installer installed actionlint after a checksum mismatch"
  pass "actionlint installer rejects a wrong checksum"
}

test_installer_falls_back_to_shasum() {
  local tmp fakebin destination out hasher_log tool
  tmp=$(fm_test_tmproot fm-actionlint-shasum)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  hasher_log="$tmp/hasher.log"

  fm_fakebin_link "$fakebin" bash dirname mktemp rm awk mkdir install cat chmod
  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" shasum
  fm_install_stub_tar_actionlint "$fakebin"
  fm_install_stub_sleep "$fakebin"

  : > "$hasher_log"
  out=$(CURL_URL_LOG="$tmp/curl-url.log" HASHER_LOG="$hasher_log" \
    SHA256_STUB_HASH="$ACTIONLINT_SHA_LINUX_AMD64" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer did not fall back to shasum -a 256"$'\n'"$out"
  assert_grep 'shasum -a 256' "$hasher_log" "installer did not invoke shasum -a 256"
  [ -x "$destination/actionlint" ] || fail "installer did not install actionlint via shasum"
  pass "actionlint installer falls back to shasum -a 256 when sha256sum is absent"
}

test_installer_prefers_sha256sum_over_shasum() {
  local tmp fakebin destination hasher_log
  tmp=$(fm_test_tmproot fm-actionlint-sha256sum-pref)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  hasher_log="$tmp/hasher.log"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" sha256sum
  fm_install_stub_hasher "$fakebin" shasum
  fm_install_stub_tar_actionlint "$fakebin"
  fm_install_stub_sleep "$fakebin"

  : > "$hasher_log"
  PATH="$fakebin:$PATH" HASHER_LOG="$hasher_log" \
    SHA256_STUB_HASH="$ACTIONLINT_SHA_LINUX_AMD64" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    "$INSTALLER" "$destination" >/dev/null \
    || fail "installer failed when both hashers were present"
  assert_grep 'sha256sum' "$hasher_log" "installer did not prefer sha256sum"
  if grep -q 'shasum' "$hasher_log"; then
    fail "installer invoked shasum even though sha256sum was present"$'\n'"$(cat "$hasher_log")"
  fi
  pass "actionlint installer prefers sha256sum when both hashers are present"
}

# A Windows CI runner hands the installer a RUNNER_TEMP such as D:\a\_temp, so the
# archive path holds backslashes. GNU coreutils then escapes the checksum line
# and prefixes it with one, and awk '{print $1}' reads a digest with a leading
# backslash. Hashing on stdin keeps the file name out of the output entirely.
test_installer_verifies_a_checksum_under_a_backslash_temp_root() {
  local tmp fakebin destination out runner_temp
  tmp=$(fm_test_tmproot fm-actionlint-backslash)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"
  runner_temp="$tmp/win\temp"
  mkdir -p "$runner_temp"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin" sha256sum
  fm_install_stub_tar_actionlint "$fakebin"
  fm_install_stub_sleep "$fakebin"

  out=$(RUNNER_TEMP="$runner_temp" SHA256_STUB_HASH="$ACTIONLINT_SHA_LINUX_AMD64" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer rejected a correct checksum under a backslash temp root"$'\n'"$out"
  [ -x "$destination/actionlint" ] \
    || fail "installer did not install actionlint under a backslash temp root"
  pass "actionlint installer verifies a checksum when the temp root holds backslashes"
}

test_installer_rejects_unsupported_platform() {
  local tmp fakebin destination out rc
  tmp=$(fm_test_tmproot fm-actionlint-unsupported)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"

  rc=0
  out=$(FM_TEST_UNAME_S=FreeBSD FM_TEST_UNAME_M=amd64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted an unsupported OS"$'\n'"$out"
  assert_contains "$out" "unsupported platform" "installer did not name the unsupported platform"
  assert_contains "$out" "FreeBSD-amd64" "installer did not report the detected OS/arch"

  rc=0
  out=$(FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=ppc64le \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer accepted an unsupported architecture"$'\n'"$out"
  assert_contains "$out" "unsupported platform" "installer did not reject linux/ppc64le"
  pass "actionlint installer rejects an unsupported OS or architecture"
}

# Prove the no-mistakes/local owner (bin/fm-lint.sh with no paths) catches a
# self-broken ci.yml. Copy the lint scripts into a fake repo so the default
# workflow root is the fixture, not this worktree.
test_fm_lint_default_path_catches_broken_ci_yml() {
  local tmp fakebin log diff_file out rc
  tmp=$(fm_test_tmproot fm-lint-wf-default)
  mkdir -p "$tmp/bin" "$tmp/.github/workflows"
  cp "$LINT" "$tmp/bin/fm-lint.sh"
  cp "$LINT_WF" "$tmp/bin/fm-lint-workflows.sh"
  chmod +x "$tmp/bin/fm-lint.sh" "$tmp/bin/fm-lint-workflows.sh"
  write_col0_heredoc_workflow "$tmp/.github/workflows/ci.yml"

  fakebin=$(fm_fakebin "$tmp")
  log="$tmp/shellcheck.log"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "rev-parse --is-inside-work-tree") printf 'true\n'; exit 0 ;;
  "rev-parse --abbrev-ref HEAD") printf 'feature\n'; exit 0 ;;
  "rev-parse --verify -q origin/main") exit 0 ;;
  "merge-base "*) printf 'fakebase123\n'; exit 0 ;;
  "diff --name-only --diff-filter=ACMR -z fakebase123 --")
    [ -n "${FM_TEST_GIT_DIFF_FILE:-}" ] && cat "${FM_TEST_GIT_DIFF_FILE}"
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/git"
  : > "$log"
  cat > "$fakebin/shellcheck" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
shift 3
printf '%s\n' "\$@" >> "$log"
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  diff_file="$tmp/diff.nul"
  : > "$diff_file"

  rc=0
  out=$(PATH="$fakebin:$PATH" GITHUB_ACTIONS='' CI='' FM_LINT_JOBS=1 \
    FM_TEST_GIT_DIFF_FILE="$diff_file" "$tmp/bin/fm-lint.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-lint.sh default path missed a broken ci.yml"$'\n'"$out"
  assert_contains "$out" "could not parse as YAML" \
    "fm-lint.sh default path did not surface the workflow YAML error"
  assert_contains "$out" "ci.yml" \
    "fm-lint.sh default path did not name the broken workflow"
  pass "fm-lint.sh default path catches a self-broken ci.yml"
}

test_windows_branch_in_ci_and_required_workflows() {
  local tmp out err rc skip_line ok_line
  skip_line='skip: python3 with yaml not found for the workflow trigger check'
  ok_line='windows: present in ci.yml push, ci.yml pull_request, no-mistakes-required.yml pull_request'
  # The workflow paths travel as argv: the heredoc is quoted so the shell leaves
  # the python alone, which also means $ROOT would never be expanded inside it.
  # A missing python3 is a skip, the same way a missing yaml module is; a
  # traceback of any other kind is a failure, never a skip.
  if ! command -v python3 >/dev/null 2>&1; then
    echo "skip: python3 not found for the workflow trigger check"
    return 0
  fi
  tmp=$(fm_test_tmproot fm-lint-wf-windows)
  # Both states the python can reach announce themselves on stdout, and stderr
  # is kept in its own file so nothing an interpreter writes there can be
  # mistaken for either: a DeprecationWarning ahead of the skip line no longer
  # hides the skip, and only the positive marker passes the case, so an
  # interpreter that dies before parsing a single workflow fails loudly instead
  # of reporting an assertion that never ran.
  #
  # The substitution closes after the terminator: a heredoc opened on the same
  # line as `$(...)` closes never reaches the command, which then runs an empty
  # script and exits 0, and the case passes without testing anything.
  rc=0
  out=$(python3 - "$ROOT/.github/workflows/ci.yml" "$ROOT/.github/workflows/no-mistakes-required.yml" 2>"$tmp/stderr" << 'PYEOF'
import sys

try:
  import yaml
except ImportError:
  print('skip: python3 with yaml not found for the workflow trigger check')
  sys.exit(0)

with open(sys.argv[1]) as f:
  ci = yaml.safe_load(f)
with open(sys.argv[2]) as f:
  nm = yaml.safe_load(f)

# PyYAML reads the bare key `on` as the boolean True, so look under both.
ci_trigger = ci.get('on') or ci.get(True) or {}
nm_trigger = nm.get('on') or nm.get(True) or {}

ci_push = (ci_trigger.get('push') or {}).get('branches') or []
ci_pr = (ci_trigger.get('pull_request') or {}).get('branches') or []
nm_pr = (nm_trigger.get('pull_request') or {}).get('branches') or []

errors = []
if 'windows' not in ci_push:
  errors.append('ci.yml push.branches missing windows')
if 'windows' not in ci_pr:
  errors.append('ci.yml pull_request.branches missing windows')
if 'windows' not in nm_pr:
  errors.append('no-mistakes-required.yml pull_request.branches missing windows')

if errors:
  for e in errors:
    print(e)
  sys.exit(1)

print('windows: present in ci.yml push, ci.yml pull_request, no-mistakes-required.yml pull_request')
PYEOF
) || rc=$?
  err=$(cat "$tmp/stderr" 2>/dev/null) || err=

  case $'\n'"$out"$'\n' in
    *$'\n'"$skip_line"$'\n'*)
      echo "$skip_line"
      return 0
      ;;
  esac
  case $'\n'"$out"$'\n' in
    *$'\n'"$ok_line"$'\n'*) ;;
    *)
      fail "workflow branch filters: no verdict line, exit $rc"$'\n'"stdout: $out"$'\n'"stderr: $err"
      ;;
  esac
  [ "$rc" -eq 0 ] ||
    fail "workflow branch filters: exit $rc"$'\n'"stdout: $out"$'\n'"stderr: $err"
  pass "both ci.yml and no-mistakes-required.yml have windows in branch filters"
}

test_pins_an_explicit_version
test_current_workflows_pass
test_col0_heredoc_fails_with_clear_error
test_valid_fixture_passes
test_empty_workflows_dir_fails
test_explicit_broken_path_fails
test_non_mapping_root_fails
test_missing_actionlint_fails_closed
test_rejects_wrong_actionlint_version
test_installer_retries_transient_download_failure
test_installer_selects_platform_archive_url_and_checksum
test_installer_rejects_wrong_checksum
test_installer_falls_back_to_shasum
test_installer_prefers_sha256sum_over_shasum
test_installer_verifies_a_checksum_under_a_backslash_temp_root
test_installer_rejects_unsupported_platform
test_fm_lint_default_path_catches_broken_ci_yml
test_windows_branch_in_ci_and_required_workflows
