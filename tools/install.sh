#!/usr/bin/env bash
# Install the Casadei OpenSpec schema so the upstream `openspec` CLI can find it.
#
#   ./tools/install.sh --project /path/to/repo   # project-local (priority 1)
#   ./tools/install.sh --user                    # per-machine    (priority 2)
#
# --project also selects the schema in that project's openspec/config.yaml.
# --user also installs the authorship rule into ~/.claude/CLAUDE.md, so it
# applies to every session rather than only to an /opsx:apply run.
#
# Options:
#   --no-claude-md   (with --user) skip writing ~/.claude/CLAUDE.md
#   --claude         (with --project) also write the authorship rule into
#                    <project>/CLAUDE.md. Warns if that path is git-ignored,
#                    which keeps the rule local to your working copy
#   --secrets LEVEL  (with --project) also set up secret protection:
#                      medium - .gitignore rules, a gitleaks pre-commit hook,
#                               and a GitHub Actions secret scan
#                      high   - medium, plus openspec/secrets-policy.md
#                    The schema's own secret rules apply at every level.
#
# See README.md for the resolution order.
set -euo pipefail

SCHEMA_NAME="casadei"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$REPO_ROOT/schemas/$SCHEMA_NAME"
BLOCK_BEGIN="<!-- BEGIN openspec-casadei: authorship -->"
BLOCK_END="<!-- END openspec-casadei: authorship -->"
RULE_FILE="$REPO_ROOT/tools/authorship.md"
SECRETS_DIR="$REPO_ROOT/tools/secrets"
SECRETS_BEGIN="# BEGIN openspec-casadei: secrets"
SECRETS_END="# END openspec-casadei: secrets"

usage() {
  sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

user_schemas_dir() {
  if [ -n "${XDG_DATA_HOME:-}" ]; then
    echo "$XDG_DATA_HOME/openspec/schemas"
  else
    echo "$HOME/.local/share/openspec/schemas"
  fi
}

# Point a project's openspec/config.yaml at this schema.
#
# Only rewrites a top-level `schema:` line that still holds the stock
# `spec-driven` value. A project that deliberately pins some other schema is
# left alone and reported - silently retargeting someone's chosen workflow
# would be worse than making them type one line.
set_project_schema() {
  local root="$1"
  local cfg="$root/openspec/config.yaml"

  if [ ! -f "$cfg" ]; then
    echo "!  No openspec/config.yaml in $root - schema installed but NOT selected."
    echo "   Run 'openspec init' there, then re-run this installer (or set"
    echo "   'schema: $SCHEMA_NAME' by hand)."
    return 0
  fi

  local current
  current="$(awk '/^schema:[[:space:]]*/ { sub(/^schema:[[:space:]]*/, ""); sub(/[[:space:]]*(#.*)?$/, ""); print; exit }' "$cfg")"

  if [ -z "$current" ]; then
    # No top-level schema: key at all (hand-edited config). Add one at the top.
    printf 'schema: %s\n' "$SCHEMA_NAME" | cat - "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
    echo "   Added 'schema: $SCHEMA_NAME' to openspec/config.yaml (no schema key was set)."
    return 0
  fi

  if [ "$current" = "$SCHEMA_NAME" ]; then
    echo "   openspec/config.yaml already selects 'schema: $SCHEMA_NAME'."
    return 0
  fi

  if [ "$current" != "spec-driven" ]; then
    echo "!  openspec/config.yaml pins 'schema: $current' - left unchanged."
    echo "   Change it to '$SCHEMA_NAME' by hand if that is what you meant."
    return 0
  fi

  # Replace only the first top-level schema: line.
  awk -v name="$SCHEMA_NAME" '
    !done && /^schema:[[:space:]]*/ { print "schema: " name; done = 1; next }
    { print }
  ' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  echo "   Set 'schema: $SCHEMA_NAME' in openspec/config.yaml (was 'spec-driven')."
}

# Write a delimited block into a file, idempotently: create the file if it is
# missing, append the block if the file has none, otherwise rewrite only what
# is between the markers. Everything outside the block is left untouched.
#
#   $1 - target file
#   $2 - opening marker line
#   $3 - closing marker line
#   $4 - block body
#   $5 - what the block is, for messages ("the authorship rule")
install_block() {
  local file="$1" begin="$2" end="$3" body="$4" what="$5"

  mkdir -p "$(dirname "$file")"

  if [ ! -f "$file" ]; then
    { echo "$begin"; echo "$body"; echo "$end"; } > "$file"
    echo "   Created $file with $what."
    return 0
  fi

  if grep -qF "$begin" "$file"; then
    if grep -qF "$end" "$file"; then
      # The body goes through ENVIRON, not -v: BSD awk (macOS) rejects a -v
      # value containing a newline.
      if ! BLOCK_BODY="$body" awk -v b="$begin" -v e="$end" '
        index($0, b) { print; print ENVIRON["BLOCK_BODY"]; skip = 1; next }
        skip && index($0, e) { print; skip = 0; next }
        !skip { print }
      ' "$file" > "$file.tmp"; then
        rm -f "$file.tmp"
        echo "Error: could not refresh $what in $file" >&2
        return 1
      fi
      mv "$file.tmp" "$file"
      echo "   Refreshed $what in $file."
    else
      echo "!  $file has an opening marker but no closing one - left unchanged."
      echo "   Repair it by hand, then re-run."
    fi
    return 0
  fi

  { echo; echo "$begin"; echo "$body"; echo "$end"; } >> "$file"
  echo "   Appended $what to $file (existing content kept)."
}

# Install the authorship rule into a CLAUDE.md.
#
# It lives here rather than only in the schema's apply instruction because the
# apply instruction is only in context during an /opsx:apply run - a plain
# "commit this" would never see it.
#
#   $1 - target file: ~/.claude/CLAUDE.md (--user) or <project>/CLAUDE.md
#        (--project --claude)
install_claude_md() {
  # Single source shared with install.ps1, so the two installers cannot drift.
  if [ ! -f "$RULE_FILE" ]; then
    echo "Error: authorship rule not found at $RULE_FILE" >&2
    return 1
  fi
  install_block "$1" "$BLOCK_BEGIN" "$BLOCK_END" "$(cat "$RULE_FILE")" "the authorship rule"
}

# Say so when a CLAUDE.md we just wrote is ignored by that project's git setup.
#
# --claude exists so the rule can travel with the repo. Upstream OpenSpec's
# .gitignore lists CLAUDE.md, and every project the fork touches inherits it,
# so the common case is that the file is written, reported, and then quietly
# skipped by `git add`. Keeping it local is a fine choice - this only makes it
# a visible one.
#
#   $1 - the file just written
#   $2 - the project root to ask git from
warn_if_gitignored() {
  local file="$1" root="$2" rule
  command -v git >/dev/null 2>&1 || return 0
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 0
  git -C "$root" check-ignore -q "$file" 2>/dev/null || return 0
  rule="$(git -C "$root" check-ignore -v "$file" 2>/dev/null | cut -f1)"
  echo "!  $file is git-ignored${rule:+ (by $rule)}, so it will NOT be committed."
  echo "   The rule still applies in this working copy, but a fresh clone will"
  echo "   not carry it. To commit it anyway, add an exception to .gitignore:"
  echo "       echo '!CLAUDE.md' >> \"$root/.gitignore\""
}

# Copy a file into the project unless one is already there. An existing file
# is never overwritten: the project may have edited it, and a policy or
# workflow it has made its own is not ours to replace.
#
#   $1 - source file under tools/secrets/
#   $2 - destination
#   $3 - what the file is, for messages
install_file() {
  local src="$1" dest="$2" what="$3"
  if [ ! -e "$dest" ]; then
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    echo "   Created $dest ($what)."
  elif cmp -s "$src" "$dest"; then
    echo "   $dest is already up to date."
  else
    echo "!  $dest already exists and differs from this repo's copy - left unchanged."
    echo "   Compare it with $src by hand."
  fi
}

# Set up secret protection in a project. The schema's rules already apply;
# these add the tooling that enforces them.
#
#   $1 - project root
#   $2 - level: medium or high
install_secrets() {
  local root="$1" level="$2"
  local precommit="$root/.pre-commit-config.yaml"

  echo
  echo "Secret protection ($level):"

  install_block "$root/.gitignore" "$SECRETS_BEGIN" "$SECRETS_END" \
    "$(cat "$SECRETS_DIR/gitignore")" "the secret ignore rules"

  if [ ! -e "$precommit" ]; then
    cp "$SECRETS_DIR/pre-commit-config.yaml" "$precommit"
    echo "   Created $precommit (gitleaks pre-commit hook)."
  elif grep -q 'gitleaks' "$precommit"; then
    echo "   $precommit already runs gitleaks."
  else
    echo "!  $precommit exists without a gitleaks hook - left unchanged."
    echo "   Add the 'repos:' entry from $SECRETS_DIR/pre-commit-config.yaml by hand."
  fi

  install_file "$SECRETS_DIR/secret-scan.yml" "$root/.github/workflows/secret-scan.yml" \
    "GitHub Actions secret scan"

  if [ "$level" = "high" ]; then
    install_file "$SECRETS_DIR/secrets-policy.md" "$root/openspec/secrets-policy.md" \
      "secrets policy - fill in its 'Where secrets live' table"
  fi

  # The ignore rules do nothing for a file that is already committed.
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local tracked
    tracked="$(git -C "$root" ls-files -ci --exclude-standard)"
    if [ -n "$tracked" ]; then
      echo "!  These committed files match the secret ignore rules and are still tracked:"
      while IFS= read -r f; do echo "     $f"; done <<< "$tracked"
      echo "   If one holds a real secret, rotate it first - it is in git history."
      echo "   Then untrack it with: git rm --cached <file>"
    fi
  fi

  echo
  echo "   Next steps:"
  echo "   1. In every clone: pre-commit install"
  echo "   2. Turn on GitHub secret scanning and push protection (repo admin;"
  echo "      private repos need GitHub Advanced Security) under Settings >"
  echo "      Code security, or:"
  echo "        gh api -X PATCH repos/<owner>/<repo> \\"
  echo "          -f 'security_and_analysis[secret_scanning][status]=enabled' \\"
  echo "          -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled'"
  if [ "$level" = "high" ]; then
    echo "   3. Fill in the 'Where secrets live' table in openspec/secrets-policy.md."
  fi
}

mode=""
project_path=""
write_claude_md=1
project_claude_md=0
secrets_level=""
secrets_given=0

while [ $# -gt 0 ]; do
  case "$1" in
    --user)          mode="user"; shift ;;
    --project)       mode="project"; project_path="${2:-.}"; shift 2 ;;
    --no-claude-md)  write_claude_md=0; shift ;;
    --claude)        project_claude_md=1; shift ;;
    --secrets)       secrets_given=1; secrets_level="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
    -h|--help)       usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$mode" ] || { echo "Error: pass --user or --project <path>" >&2; usage; }
if [ "$project_claude_md" -eq 1 ] && [ "$mode" != "project" ]; then
  echo "Error: --claude only applies to --project (--user already writes ~/.claude/CLAUDE.md)" >&2
  exit 1
fi
if [ "$secrets_given" -eq 1 ] && [ "$mode" != "project" ]; then
  echo "Error: --secrets only applies to --project" >&2
  exit 1
fi
case "$secrets_given:$secrets_level" in
  0:|1:medium|1:high) ;;
  *) echo "Error: --secrets takes 'medium' or 'high', got '$secrets_level'" >&2; exit 1 ;;
esac
[ -d "$SOURCE_DIR" ] || { echo "Error: schema not found at $SOURCE_DIR" >&2; exit 1; }

if [ "$mode" = "user" ]; then
  dest_parent="$(user_schemas_dir)"
  project_root=""
else
  [ -d "$project_path" ] || { echo "Error: not a directory: $project_path" >&2; exit 1; }
  project_root="$(cd "$project_path" && pwd)"
  dest_parent="$project_root/openspec/schemas"
fi

dest="$dest_parent/$SCHEMA_NAME"

# Refuse to clobber a schema that has diverged locally; the user may have edited
# it in place and we must not silently discard that.
if [ -d "$dest" ] && ! diff -rq "$SOURCE_DIR" "$dest" >/dev/null 2>&1; then
  echo "Error: $dest already exists and differs from this repo's copy." >&2
  echo "Inspect it, then remove it if you want to overwrite:" >&2
  echo "  diff -ru \"$SOURCE_DIR\" \"$dest\"" >&2
  exit 1
fi

mkdir -p "$dest_parent"
rm -rf "$dest"
cp -R "$SOURCE_DIR" "$dest"

echo "Installed schema '$SCHEMA_NAME' -> $dest"

if [ "$mode" = "project" ]; then
  set_project_schema "$project_root"
  if [ "$project_claude_md" -eq 1 ]; then
    install_claude_md "$project_root/CLAUDE.md"
    warn_if_gitignored "$project_root/CLAUDE.md" "$project_root"
  fi
  if [ -n "$secrets_level" ]; then
    install_secrets "$project_root" "$secrets_level"
  fi
  echo
  echo "Verify with: openspec schema which $SCHEMA_NAME"
else
  if [ "$write_claude_md" -eq 1 ]; then
    install_claude_md "$HOME/.claude/CLAUDE.md"
  else
    echo "   Skipped ~/.claude/CLAUDE.md (--no-claude-md)."
  fi
  echo
  echo "!  A user-level schema is installed but not selected anywhere."
  echo "   Each project still needs 'schema: $SCHEMA_NAME' in openspec/config.yaml."
  echo "   Run this installer with --project <path> to set that automatically."
  echo
  echo "Verify with: openspec schema which $SCHEMA_NAME"
fi
