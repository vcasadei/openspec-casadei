#!/usr/bin/env bash
# Write which upstream OpenSpec release this fork is synced to into the README.
#
#   ./tools/upstream-version.sh <commit>           # rewrite the README header
#   ./tools/upstream-version.sh --check <commit>   # fail if it is out of date
#
# <commit> is the upstream commit the fork has merged: upstream/main right
# after a sync, or `git merge-base HEAD upstream/main` at any other time. The
# version is the "version" field of that commit's package.json.
#
# The header is tools/readme-header.md with its placeholders filled in, written
# between the upstream-version markers in README.md. Edit the template, not the
# README: anything between the markers is overwritten. sync-upstream.sh runs
# this on every merge, and CI runs --check. Keep in sync with
# upstream-version.ps1, which reads the same template.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/tools/readme-header.md"
README="$ROOT/README.md"
BEGIN_MARK="<!-- BEGIN upstream-version: generated from tools/readme-header.md, do not edit -->"
END_MARK="<!-- END upstream-version -->"

check=0
if [ "${1:-}" = "--check" ]; then
  check=1
  shift
fi
commit="${1:-}"
if [ -z "$commit" ] || [ $# -ne 1 ]; then
  echo "Usage: $0 [--check] <upstream-commit>" >&2
  exit 1
fi

if ! sha="$(git -C "$ROOT" rev-parse --verify --quiet "$commit^{commit}")"; then
  echo "Error: '$commit' is not a commit." >&2
  exit 1
fi

if ! package_json="$(git -C "$ROOT" show "$sha:package.json" 2>/dev/null)"; then
  echo "Error: upstream commit ${sha:0:7} has no package.json." >&2
  exit 1
fi
# The top-level "version" is the first one indented by exactly two spaces.
version="$(sed -n 's/^  "version": *"\([^"]*\)".*/\1/p;/^  "version"/q' <<< "$package_json")"

# The value lands in a URL and in Markdown, so accept only a plain semver.
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "Error: package.json at ${sha:0:7} has no usable version (got '$version')." >&2
  exit 1
fi

# shields.io reads '-' as a separator, so a literal dash is written '--'.
badge_version="${version//-/--}"
# A fixed length, not --short: git lengthens that to stay unambiguous, which
# would differ between clones and make --check flap.
short_sha="${sha:0:7}"

header="$(sed -e "s|@VERSION@|$version|g" \
              -e "s|@BADGE_VERSION@|$badge_version|g" \
              -e "s|@SHORT_SHA@|$short_sha|g" \
              -e "s|@SHA@|$sha|g" "$TEMPLATE")"

if ! grep -qxF "$BEGIN_MARK" "$README" || ! grep -qxF "$END_MARK" "$README"; then
  echo "Error: README.md has no upstream-version markers. Expected these two lines:" >&2
  echo "  $BEGIN_MARK" >&2
  echo "  $END_MARK" >&2
  exit 1
fi

# The header goes through ENVIRON, not -v: BSD awk (macOS) rejects a -v value
# containing a newline.
updated="$(HEADER="$header" awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  $0 == b { print; print ENVIRON["HEADER"]; skip = 1; next }
  skip && $0 == e { print; skip = 0; next }
  !skip { print }
' "$README")"

if [ "$updated" = "$(cat "$README")" ]; then
  echo "README.md already says v$version ($short_sha)."
  exit 0
fi

if [ "$check" -eq 1 ]; then
  echo "Error: README.md does not say which upstream it is synced to (v$version, $short_sha)." >&2
  echo "Run: ./tools/upstream-version.sh $short_sha" >&2
  exit 1
fi

printf '%s\n' "$updated" > "$README"
echo "README.md now says v$version ($short_sha)."
