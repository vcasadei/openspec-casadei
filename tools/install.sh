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
#                    <project>/CLAUDE.md, so it is committed with the repo
#
# See README.md for the resolution order.
set -euo pipefail

SCHEMA_NAME="casadei"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$REPO_ROOT/schemas/$SCHEMA_NAME"
BLOCK_BEGIN="<!-- BEGIN openspec-casadei: authorship -->"
BLOCK_END="<!-- END openspec-casadei: authorship -->"
RULE_FILE="$REPO_ROOT/tools/authorship.md"

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

# Install the authorship rule into a CLAUDE.md.
#
# It lives here rather than only in the schema's apply instruction because the
# apply instruction is only in context during an /opsx:apply run - a plain
# "commit this" would never see it. Written inside a delimited block so the
# file can be re-written idempotently without touching anything else in it.
#
#   $1 - target file: ~/.claude/CLAUDE.md (--user) or <project>/CLAUDE.md
#        (--project --claude)
install_claude_md() {
  local file="$1"
  local dir
  dir="$(dirname "$file")"
  local body
  # Single source shared with install.ps1, so the two installers cannot drift.
  if [ ! -f "$RULE_FILE" ]; then
    echo "Error: authorship rule not found at $RULE_FILE" >&2
    return 1
  fi
  body="$(cat "$RULE_FILE")"

  mkdir -p "$dir"

  if [ ! -f "$file" ]; then
    { echo "$BLOCK_BEGIN"; echo "$body"; echo "$BLOCK_END"; } > "$file"
    echo "   Created $file with the authorship rule."
    return 0
  fi

  if grep -qF "$BLOCK_BEGIN" "$file"; then
    if grep -qF "$BLOCK_END" "$file"; then
      awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" -v body="$body" '
        index($0, b) { print; print body; skip = 1; next }
        skip && index($0, e) { print; skip = 0; next }
        !skip { print }
      ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
      echo "   Refreshed the authorship rule in $file."
    else
      echo "!  $file has an opening marker but no closing one - left unchanged."
      echo "   Repair it by hand, then re-run."
    fi
    return 0
  fi

  { echo; echo "$BLOCK_BEGIN"; echo "$body"; echo "$BLOCK_END"; } >> "$file"
  echo "   Appended the authorship rule to $file (existing content kept)."
}

mode=""
project_path=""
write_claude_md=1
project_claude_md=0

while [ $# -gt 0 ]; do
  case "$1" in
    --user)          mode="user"; shift ;;
    --project)       mode="project"; project_path="${2:-.}"; shift 2 ;;
    --no-claude-md)  write_claude_md=0; shift ;;
    --claude)        project_claude_md=1; shift ;;
    -h|--help)       usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[ -n "$mode" ] || { echo "Error: pass --user or --project <path>" >&2; usage; }
if [ "$project_claude_md" -eq 1 ] && [ "$mode" != "project" ]; then
  echo "Error: --claude only applies to --project (--user already writes ~/.claude/CLAUDE.md)" >&2
  exit 1
fi
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
