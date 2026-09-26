#!/usr/bin/env bash
# Tests for tools/install.sh.
#
#   ./tools/tests/install.test.sh
#
# Every case runs against a throwaway directory with HOME and XDG_DATA_HOME
# redirected into it, so the real ~/.claude/CLAUDE.md and user schema dir are
# never touched. Exits non-zero if any case fails.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$REPO_ROOT/tools/install.sh"
SCHEMA_SRC="$REPO_ROOT/schemas/casadei"
RULE_FILE="$REPO_ROOT/tools/authorship.md"
BLOCK_BEGIN="<!-- BEGIN openspec-casadei: authorship -->"
BLOCK_END="<!-- END openspec-casadei: authorship -->"

passed=0
failed=0
current=""
case_failed=0

fail() {
  echo "    FAIL: $*"
  case_failed=1
}

assert_file()     { [ -f "$1" ] || fail "expected file $1"; }
assert_no_file()  { [ ! -e "$1" ] || fail "expected no file at $1"; }
assert_contains() { grep -qF -- "$2" "$1" 2>/dev/null || fail "expected $1 to contain: $2"; }
assert_eq()       { [ "$1" = "$2" ] || fail "expected '$2', got '$1'${3:+ ($3)}"; }

# Lines strictly between the authorship markers.
block_body() {
  awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
    index($0, e) { inside = 0 }
    inside       { print }
    index($0, b) { inside = 1 }
  ' "$1" 2>/dev/null
}

assert_block_matches_rule() {
  assert_eq "$(block_body "$1")" "$(cat "$RULE_FILE")" "authorship block in $1"
  assert_eq "$(grep -cF "$BLOCK_BEGIN" "$1")" "1" "begin markers in $1"
}

# Run the installer with an isolated HOME. Sets $out and $status.
run_install() {
  out="$(HOME="$SANDBOX/home" XDG_DATA_HOME="$SANDBOX/xdg" "$INSTALLER" "$@" 2>&1)"
  status=$?
}

# A project with an openspec/config.yaml selecting the stock schema.
new_project() {
  local dir="$SANDBOX/$1"
  mkdir -p "$dir/openspec"
  printf 'schema: spec-driven\n\n# keep this comment\n' > "$dir/openspec/config.yaml"
  echo "$dir"
}

run_case() {
  current="$1"
  case_failed=0
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/home"
  "$1"
  rm -rf "$SANDBOX"
  if [ "$case_failed" -eq 0 ]; then
    echo "  ok   $current"
    passed=$((passed + 1))
  else
    echo "  FAIL $current"
    while IFS= read -r line; do echo "       | $line"; done <<< "$out"
    failed=$((failed + 1))
  fi
}

# --- --project ---------------------------------------------------------------

test_project_installs_and_selects_schema() {
  local p; p="$(new_project p)"
  run_install --project "$p"
  assert_eq "$status" "0" "exit status"
  diff -rq "$SCHEMA_SRC" "$p/openspec/schemas/casadei" >/dev/null || fail "schema copy differs from source"
  assert_eq "$(head -1 "$p/openspec/config.yaml")" "schema: casadei"
  assert_contains "$p/openspec/config.yaml" "# keep this comment"
}

test_project_without_claude_writes_no_claude_md() {
  local p; p="$(new_project p)"
  run_install --project "$p"
  assert_no_file "$p/CLAUDE.md"
  assert_no_file "$SANDBOX/home/.claude/CLAUDE.md"
}

test_project_claude_creates_claude_md() {
  local p; p="$(new_project p)"
  run_install --project "$p" --claude
  assert_eq "$status" "0" "exit status"
  assert_file "$p/CLAUDE.md"
  assert_block_matches_rule "$p/CLAUDE.md"
  assert_no_file "$SANDBOX/home/.claude/CLAUDE.md"
}

test_project_claude_flag_order_does_not_matter() {
  local p; p="$(new_project p)"
  run_install --claude --project "$p"
  assert_eq "$status" "0" "exit status"
  assert_block_matches_rule "$p/CLAUDE.md"
}

test_project_claude_is_idempotent() {
  local p before; p="$(new_project p)"
  run_install --project "$p" --claude
  before="$(cat "$p/CLAUDE.md")"
  run_install --project "$p" --claude
  assert_eq "$status" "0" "exit status on re-run"
  assert_eq "$(cat "$p/CLAUDE.md")" "$before" "CLAUDE.md after re-run"
  assert_contains <(echo "$out") "Refreshed the authorship rule"
}

test_project_claude_appends_to_existing_file() {
  local p; p="$(new_project p)"
  printf '# Project notes\n\nUse tabs.\n' > "$p/CLAUDE.md"
  run_install --project "$p" --claude
  assert_eq "$(head -3 "$p/CLAUDE.md")" "$(printf '# Project notes\n\nUse tabs.')" "existing content"
  assert_block_matches_rule "$p/CLAUDE.md"
}

test_project_claude_refreshes_stale_block_only() {
  local p; p="$(new_project p)"
  printf 'before\n%s\nstale rule\n%s\nafter\n' "$BLOCK_BEGIN" "$BLOCK_END" > "$p/CLAUDE.md"
  run_install --project "$p" --claude
  assert_block_matches_rule "$p/CLAUDE.md"
  assert_eq "$(head -1 "$p/CLAUDE.md")" "before"
  assert_eq "$(tail -1 "$p/CLAUDE.md")" "after"
  grep -qF "stale rule" "$p/CLAUDE.md" && fail "stale rule was not replaced"
}

test_project_claude_leaves_unterminated_block_alone() {
  local p before; p="$(new_project p)"
  printf '%s\nno end marker\n' "$BLOCK_BEGIN" > "$p/CLAUDE.md"
  before="$(cat "$p/CLAUDE.md")"
  run_install --project "$p" --claude
  assert_eq "$(cat "$p/CLAUDE.md")" "$before" "CLAUDE.md with no end marker"
  assert_contains <(echo "$out") "no closing one"
}

test_project_leaves_other_pinned_schema() {
  local p; p="$(new_project p)"
  printf 'schema: someone-elses\n' > "$p/openspec/config.yaml"
  run_install --project "$p"
  assert_eq "$status" "0" "exit status"
  assert_eq "$(cat "$p/openspec/config.yaml")" "schema: someone-elses"
}

test_project_adds_missing_schema_key() {
  local p; p="$(new_project p)"
  printf 'context: |\n  stuff\n' > "$p/openspec/config.yaml"
  run_install --project "$p"
  assert_eq "$(head -1 "$p/openspec/config.yaml")" "schema: casadei"
  assert_contains "$p/openspec/config.yaml" "context: |"
}

test_project_without_config_warns() {
  mkdir -p "$SANDBOX/bare"
  run_install --project "$SANDBOX/bare"
  assert_eq "$status" "0" "exit status"
  assert_file "$SANDBOX/bare/openspec/schemas/casadei/schema.yaml"
  assert_contains <(echo "$out") "NOT selected"
}

test_project_refuses_to_clobber_diverged_schema() {
  local p; p="$(new_project p)"
  run_install --project "$p"
  echo "# local edit" >> "$p/openspec/schemas/casadei/schema.yaml"
  run_install --project "$p"
  assert_eq "$status" "1" "exit status"
  assert_contains "$p/openspec/schemas/casadei/schema.yaml" "# local edit"
}

test_project_rejects_missing_directory() {
  run_install --project "$SANDBOX/nope"
  assert_eq "$status" "1" "exit status"
}

# --- --user ------------------------------------------------------------------

test_user_installs_schema_and_claude_md() {
  run_install --user
  assert_eq "$status" "0" "exit status"
  diff -rq "$SCHEMA_SRC" "$SANDBOX/xdg/openspec/schemas/casadei" >/dev/null || fail "schema copy differs from source"
  assert_block_matches_rule "$SANDBOX/home/.claude/CLAUDE.md"
}

test_user_no_claude_md_skips_it() {
  run_install --user --no-claude-md
  assert_eq "$status" "0" "exit status"
  assert_no_file "$SANDBOX/home/.claude/CLAUDE.md"
}

test_user_rejects_claude_flag() {
  run_install --user --claude
  assert_eq "$status" "1" "exit status"
  assert_contains <(echo "$out") "--claude only applies to --project"
  assert_no_file "$SANDBOX/xdg/openspec/schemas/casadei"
  assert_no_file "$SANDBOX/home/.claude/CLAUDE.md"
}

test_user_and_project_blocks_are_identical() {
  local p; p="$(new_project p)"
  run_install --user
  run_install --project "$p" --claude
  assert_eq "$(block_body "$p/CLAUDE.md")" "$(block_body "$SANDBOX/home/.claude/CLAUDE.md")" "blocks"
}

# --- arguments ---------------------------------------------------------------

test_requires_a_mode() {
  run_install
  assert_eq "$status" "1" "exit status"
}

test_rejects_unknown_argument() {
  run_install --bogus
  assert_eq "$status" "1" "exit status"
}

test_help_documents_claude_flag() {
  run_install --help
  assert_eq "$status" "0" "exit status"
  assert_contains <(echo "$out") "--claude"
}

echo "tools/install.sh"
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  run_case "$t"
done

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
