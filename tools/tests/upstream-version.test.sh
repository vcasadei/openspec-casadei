#!/usr/bin/env bash
# Tests for tools/upstream-version.sh.
#
#   ./tools/tests/upstream-version.test.sh
#
# Each case builds a throwaway repo holding a copy of the script, its template,
# and a README with the upstream-version markers, plus an "upstream" commit
# with a package.json. No network access; exits non-zero if any case fails.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BEGIN_MARK="<!-- BEGIN upstream-version: generated from tools/readme-header.md, do not edit -->"
END_MARK="<!-- END upstream-version -->"

passed=0
failed=0
case_failed=0
out=""
status=0

fail() {
  echo "    FAIL: $*"
  case_failed=1
}

assert_eq()       { [ "$1" = "$2" ] || fail "expected '$2', got '$1'${3:+ ($3)}"; }
assert_output()   { grep -qF -- "$1" <<< "$out" || fail "expected output to contain: $1"; }
assert_readme()   { grep -qF -- "$1" "$REPO/README.md" || fail "expected README.md to contain: $1"; }

# A repo with the script, the template, a README with markers between other
# content, and an upstream commit ($UPSTREAM) whose package.json says $1.
make_repo() {
  REPO="$SANDBOX/repo"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.name "Test Author"
  git -C "$REPO" config user.email "test@example.com"
  mkdir -p "$REPO/tools"
  cp "$REPO_ROOT/tools/upstream-version.sh" "$REPO_ROOT/tools/readme-header.md" "$REPO/tools/"
  printf '# Title\n\n%s\n%s\n\nbody stays\n' "$BEGIN_MARK" "$END_MARK" > "$REPO/README.md"
  set_upstream_version "$1"
}

# Commit a package.json with version $1 and remember that commit as $UPSTREAM.
set_upstream_version() {
  printf '{\n  "name": "@fission-ai/openspec",\n  "version": "%s",\n  "dependencies": {\n    "x": {\n      "version": "9.9.9"\n    }\n  }\n}\n' "$1" > "$REPO/package.json"
  git -C "$REPO" add package.json
  git -C "$REPO" commit -q -m "upstream $1"
  UPSTREAM="$(git -C "$REPO" rev-parse HEAD)"
}

run_script() {
  out="$("$REPO/tools/upstream-version.sh" "$@" 2>&1)"
  status=$?
}

run_case() {
  local name="$1"
  case_failed=0
  out=""
  SANDBOX="$(mktemp -d)"
  make_repo 1.13.2
  "$name"
  if [ "$case_failed" -eq 0 ]; then
    echo "  ok   $name"
    passed=$((passed + 1))
  else
    echo "  FAIL $name"
    while IFS= read -r line; do echo "       | $line"; done <<< "$out"
    failed=$((failed + 1))
  fi
  rm -rf "$SANDBOX"
}

test_writes_version_and_commit_between_the_markers() {
  run_script "$UPSTREAM"
  assert_eq "$status" "0" "exit status"
  assert_readme "synced_to_OpenSpec-v1.13.2-blue"
  assert_readme "to **v1.13.2** (upstream commit"
  assert_readme "[\`${UPSTREAM:0:7}\`](https://github.com/Fission-AI/OpenSpec/commit/$UPSTREAM)"
  assert_output "README.md now says v1.13.2 (${UPSTREAM:0:7})."
}

test_keeps_everything_outside_the_markers() {
  run_script "$UPSTREAM"
  assert_eq "$(head -3 "$REPO/README.md")" "$(printf '# Title\n\n%s' "$BEGIN_MARK")" "lines before the block"
  assert_eq "$(tail -3 "$REPO/README.md")" "$(printf '%s\n\nbody stays' "$END_MARK")" "lines after the block"
}

test_is_idempotent() {
  local before
  run_script "$UPSTREAM"
  before="$(cat "$REPO/README.md")"
  run_script "$UPSTREAM"
  assert_eq "$status" "0" "exit status on re-run"
  assert_eq "$(cat "$REPO/README.md")" "$before" "README.md after re-run"
  assert_output "already says v1.13.2"
}

test_moves_to_a_newer_version() {
  run_script "$UPSTREAM"
  set_upstream_version 1.14.0
  run_script "$UPSTREAM"
  assert_eq "$status" "0" "exit status"
  assert_readme "to **v1.14.0**"
  grep -qF "1.13.2" "$REPO/README.md" && fail "old version still in README.md"
  assert_eq "$(grep -cF "$BEGIN_MARK" "$REPO/README.md")" "1" "begin markers"
}

test_check_fails_when_stale_and_leaves_readme_alone() {
  local before; before="$(cat "$REPO/README.md")"
  run_script --check "$UPSTREAM"
  assert_eq "$status" "1" "exit status"
  assert_output "Run: ./tools/upstream-version.sh ${UPSTREAM:0:7}"
  assert_eq "$(cat "$REPO/README.md")" "$before" "README.md"
}

test_check_passes_when_current() {
  run_script "$UPSTREAM"
  run_script --check "$UPSTREAM"
  assert_eq "$status" "0" "exit status"
}

test_escapes_dashes_in_the_badge_only() {
  set_upstream_version 2.0.0-beta.1
  run_script "$UPSTREAM"
  assert_eq "$status" "0" "exit status"
  assert_readme "synced_to_OpenSpec-v2.0.0--beta.1-blue"
  assert_readme "to **v2.0.0-beta.1**"
}

test_rejects_a_version_that_is_not_semver() {
  local before; before="$(cat "$REPO/README.md")"
  set_upstream_version '1.0](https://evil.example'
  run_script "$UPSTREAM"
  assert_eq "$status" "1" "exit status"
  assert_output "no usable version"
  assert_eq "$(cat "$REPO/README.md")" "$before" "README.md"
}

test_rejects_a_commit_without_package_json() {
  git -C "$REPO" rm -q package.json
  git -C "$REPO" commit -q -m "no package.json"
  run_script HEAD
  assert_eq "$status" "1" "exit status"
  assert_output "has no package.json"
}

test_rejects_a_readme_without_markers() {
  printf '# Title\n' > "$REPO/README.md"
  run_script "$UPSTREAM"
  assert_eq "$status" "1" "exit status"
  assert_output "no upstream-version markers"
  assert_eq "$(cat "$REPO/README.md")" "# Title" "README.md"
}

test_rejects_an_unknown_commit() {
  run_script no-such-commit
  assert_eq "$status" "1" "exit status"
  assert_output "is not a commit"
}

test_requires_a_commit() {
  run_script
  assert_eq "$status" "1" "exit status"
  assert_output "Usage:"
}

echo "tools/upstream-version.sh"
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  run_case "$t"
done

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
