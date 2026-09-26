#!/usr/bin/env bash
# Tests for tools/sync-upstream.sh.
#
#   ./tools/tests/sync-upstream.test.sh
#
# Each case builds a throwaway "upstream" repo and a "fork" of it that prunes
# upstream's tree the way this repo does, then runs the sync script inside the
# fork. No network access; exits non-zero if any case fails.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYNC_SCRIPT="$REPO_ROOT/tools/sync-upstream.sh"

passed=0
failed=0
case_failed=0
out=""
status=0

fail() {
  echo "    FAIL: $*"
  case_failed=1
}

assert_eq()      { [ "$1" = "$2" ] || fail "expected '$2', got '$1'${3:+ ($3)}"; }
assert_absent()  { [ ! -e "$FORK/$1" ] || fail "expected $1 to be absent from the fork"; }
assert_output()  { grep -qF -- "$1" <<< "$out" || fail "expected output to contain: $1"; }
fork_file()      { cat "$FORK/$1"; }
not_in_head()    { ! git -C "$FORK" cat-file -e "HEAD:$1" 2>/dev/null || fail "expected $1 to be absent from HEAD"; }

git_id() { git -C "$1" config user.name "Test Author"; git -C "$1" config user.email "test@example.com"; }

# Upstream: a README, CLI source, a workflow, the baseline schema, and docs.
# Fork: a clone that drops src/ and .github/, rewrites line 1 of the README,
# and adds its own tools/ and NOTICE.md - the shape of this repository.
make_repos() {
  UPSTREAM="$SANDBOX/upstream"
  FORK="$SANDBOX/fork"
  git init -q -b main "$UPSTREAM"
  git_id "$UPSTREAM"
  (
    cd "$UPSTREAM" || exit 1
    printf 'upstream readme\nb\nc\nd\ne\n' > README.md
    mkdir -p src .github/workflows schemas/spec-driven docs
    echo 'export const cli = 1' > src/cli.ts
    echo 'name: ci' > .github/workflows/ci.yml
    printf 'name: spec-driven\nversion: 1\n' > schemas/spec-driven/schema.yaml
    printf 'guide line 1\nguide line 2\n' > docs/guide.md
    echo 'old doc' > docs/old.md
    git add -A && git commit -q -m "upstream: initial"
  )

  git clone -q "$UPSTREAM" "$FORK"
  git_id "$FORK"
  (
    cd "$FORK" || exit 1
    git remote rename origin upstream
    git rm -q -r src .github
    printf 'fork readme\nb\nc\nd\ne\n' > README.md
    echo 'fork notice' > NOTICE.md
    mkdir -p tools
    cp "$SYNC_SCRIPT" tools/sync-upstream.sh
    git add -A && git commit -q -m "fork: prune"
  )
}

# Make a commit in upstream by running "$@" there.
upstream_commit() {
  local msg="$1"; shift
  (cd "$UPSTREAM" && "$@" && git add -A && git commit -q -m "$msg")
}

run_sync() {
  out="$(cd "$FORK" && ./tools/sync-upstream.sh 2>&1)"
  status=$?
}

run_case() {
  local name="$1"
  case_failed=0
  out=""
  SANDBOX="$(mktemp -d)"
  make_repos
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

# --- tracked paths -----------------------------------------------------------

test_already_up_to_date_is_a_no_op() {
  local before; before="$(git -C "$FORK" rev-parse HEAD)"
  run_sync
  assert_eq "$status" "0" "exit status"
  assert_output "Already up to date"
  assert_eq "$(git -C "$FORK" rev-parse HEAD)" "$before" "HEAD"
}

test_merges_tracked_changes() {
  upstream_commit "schema v2" sh -c 'printf "name: spec-driven\nversion: 2\n" > schemas/spec-driven/schema.yaml'
  run_sync
  assert_eq "$status" "0" "exit status"
  assert_eq "$(fork_file schemas/spec-driven/schema.yaml)" "$(printf 'name: spec-driven\nversion: 2')"
  assert_eq "$(git -C "$FORK" log -1 --format=%p HEAD | wc -w | tr -d ' ')" "2" "merge commit parents"
  assert_output "Upstream changed the baseline schema"
}

test_propagates_tracked_deletions() {
  upstream_commit "drop old doc" git rm -q docs/old.md
  run_sync
  assert_eq "$status" "0" "exit status"
  assert_absent docs/old.md
}

test_tracked_conflict_is_left_for_a_human() {
  (cd "$FORK" && printf 'fork guide\nguide line 2\n' > docs/guide.md && git commit -q -am "fork: edit guide")
  upstream_commit "upstream guide" sh -c 'printf "upstream guide\nguide line 2\n" > docs/guide.md'
  upstream_commit "upstream readme" sh -c 'printf "new upstream readme\nb\nc\nd\ne\n" > README.md'
  run_sync
  assert_eq "$status" "1" "exit status"
  assert_output "Conflicts needing your attention:"
  assert_output "  docs/guide.md"
  git -C "$FORK" rev-parse -q --verify MERGE_HEAD >/dev/null || fail "expected the merge to be left in progress"
  # Only the tracked conflict remains; the README was already put back.
  assert_eq "$(git -C "$FORK" diff --name-only --diff-filter=U)" "docs/guide.md" "unmerged paths"
  assert_eq "$(fork_file README.md | head -1)" "fork readme"
}

# --- fork-owned paths --------------------------------------------------------

test_keeps_fork_readme_when_upstream_edits_the_same_lines() {
  upstream_commit "upstream readme" sh -c 'printf "new upstream readme\nb\nc\nd\ne\n" > README.md'
  run_sync
  assert_eq "$status" "0" "exit status"
  assert_eq "$(fork_file README.md)" "$(printf 'fork readme\nb\nc\nd\ne')"
}

test_keeps_fork_readme_when_upstream_edit_would_merge_cleanly() {
  # A line the fork never touched: git would merge this without a conflict.
  upstream_commit "upstream readme tail" sh -c 'printf "upstream readme\nb\nc\nd\nUPSTREAM\n" > README.md'
  run_sync
  assert_eq "$status" "0" "exit status"
  assert_eq "$(fork_file README.md)" "$(printf 'fork readme\nb\nc\nd\ne')"
}

test_keeps_fork_readme_when_upstream_deletes_it() {
  upstream_commit "upstream drops readme" git rm -q README.md
  run_sync
  assert_eq "$status" "0" "exit status"
  assert_eq "$(fork_file README.md | head -1)" "fork readme"
}

test_ignores_upstream_files_under_fork_owned_dirs() {
  upstream_commit "upstream tools" sh -c 'mkdir -p tools && echo x > tools/extra.sh && echo y > NOTICE.md'
  run_sync
  assert_eq "$status" "0" "exit status"
  assert_absent tools/extra.sh
  assert_eq "$(fork_file NOTICE.md)" "fork notice"
  cmp -s "$SYNC_SCRIPT" "$FORK/tools/sync-upstream.sh" || fail "tools/sync-upstream.sh changed"
}

# --- upstream-only paths -----------------------------------------------------

test_keeps_dropped_files_out_when_upstream_modifies_them() {
  upstream_commit "cli v2" sh -c 'echo "export const cli = 2" > src/cli.ts && echo "name: ci2" > .github/workflows/ci.yml'
  run_sync
  assert_eq "$status" "0" "exit status"
  assert_absent src/cli.ts
  assert_absent .github/workflows/ci.yml
  not_in_head src/cli.ts
  assert_eq "$(git -C "$FORK" status --porcelain)" "" "working tree after sync"
}

test_keeps_new_upstream_files_out() {
  upstream_commit "new files" sh -c 'mkdir -p src website && echo n > src/new.ts && echo w > website/index.html'
  run_sync
  assert_eq "$status" "0" "exit status"
  assert_absent src/new.ts
  assert_absent website/index.html
  not_in_head website/index.html
}

test_non_tracked_tree_is_unchanged_by_the_merge() {
  upstream_commit "mixed" sh -c 'echo z >> README.md && echo n > src/new.ts && echo 3 >> src/cli.ts && echo more >> docs/guide.md'
  run_sync
  assert_eq "$status" "0" "exit status"
  assert_eq "$(git -C "$FORK" diff --name-only HEAD~1 HEAD)" "docs/guide.md" "paths changed by the merge"
}

# --- general -----------------------------------------------------------------

test_merges_more_than_thirty_commits() {
  # Regression: `git log | head -30` under pipefail aborted before merging.
  local i
  for i in $(seq 1 35); do
    upstream_commit "doc $i" sh -c "echo $i >> docs/guide.md"
  done
  run_sync
  assert_eq "$status" "0" "exit status"
  assert_output "Upstream commits not yet merged: 35"
  assert_eq "$(fork_file docs/guide.md | tail -1)" "35"
}

test_next_sync_starts_from_the_last_merge() {
  upstream_commit "one" sh -c 'echo 1 >> docs/guide.md'
  run_sync
  run_sync
  assert_output "Already up to date"
  upstream_commit "two" sh -c 'echo 2 >> docs/guide.md'
  run_sync
  assert_eq "$status" "0" "exit status"
  assert_output "Upstream commits not yet merged: 1"
}

test_refuses_a_dirty_tree() {
  upstream_commit "doc" sh -c 'echo 1 >> docs/guide.md'
  echo dirty >> "$FORK/README.md"
  run_sync
  assert_eq "$status" "1" "exit status"
  assert_output "working tree is dirty"
}

echo "tools/sync-upstream.sh"
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  run_case "$t"
done

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
