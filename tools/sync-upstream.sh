#!/usr/bin/env bash
# Merge upstream OpenSpec into this fork.
#
# This fork intentionally carries only a small slice of upstream's tree, so a
# merge produces a modify/delete conflict for every upstream file we dropped.
# Those are not real conflicts — we always want them to stay deleted. This
# script resolves them automatically and leaves only the conflicts that need a
# human: changes inside the paths we actually keep.
set -euo pipefail

UPSTREAM_URL="https://github.com/Fission-AI/OpenSpec.git"

# Paths this fork tracks. An unmerged path under one of these is a real conflict.
KEEP_PREFIXES=("schemas/" "skills/" "docs/" "LICENSE" ".gitattributes" ".gitignore" ".github/workflows/installers.yml")

cd "$(git rev-parse --show-toplevel)"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Error: working tree is dirty. Commit or stash first." >&2
  exit 1
fi

if ! git remote get-url upstream >/dev/null 2>&1; then
  echo "Adding 'upstream' remote -> $UPSTREAM_URL"
  git remote add upstream "$UPSTREAM_URL"
fi

echo "Fetching upstream..."
git fetch upstream main --tags

if git merge-base --is-ancestor upstream/main HEAD; then
  echo "Already up to date with upstream/main. Nothing to do."
  exit 0
fi

echo
echo "Upstream commits not yet merged:"
git log --oneline HEAD..upstream/main | head -30
echo

# The merge is expected to fail on conflicts; that is the normal path here.
git merge upstream/main --no-edit || true

is_kept() {
  local path="$1" prefix
  for prefix in "${KEEP_PREFIXES[@]}"; do
    case "$path" in "$prefix"*) return 0 ;; esac
  done
  return 1
}

auto_resolved=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if is_kept "$path"; then
    continue
  fi
  git rm -q -f --ignore-unmatch -- "$path" >/dev/null 2>&1 || true
  auto_resolved=$((auto_resolved + 1))
done < <(git diff --name-only --diff-filter=U)

# Upstream may also re-add whole trees we pruned; drop anything staged outside
# the kept paths so the fork stays lean.
readded=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if is_kept "$path"; then
    continue
  fi
  git rm -q -f --ignore-unmatch --cached -- "$path" >/dev/null 2>&1 || true
  rm -f -- "$path" 2>/dev/null || true
  readded=$((readded + 1))
done < <(git diff --cached --name-only --diff-filter=A)

echo "Auto-resolved $auto_resolved dropped-file conflict(s); discarded $readded re-added file(s)."

remaining=$(git diff --name-only --diff-filter=U)
if [ -n "$remaining" ]; then
  echo
  echo "Conflicts needing your attention:"
  echo "$remaining" | sed 's/^/  /'
  echo
  echo "Resolve them, then: git add <files> && git commit"
  exit 1
fi

if git diff --cached --quiet && ! git rev-parse -q --verify MERGE_HEAD >/dev/null; then
  echo "Nothing to commit."
  exit 0
fi

git commit --no-edit
echo
echo "Merge complete. Now review what upstream changed in the baseline schema:"
echo "  git diff HEAD~1 -- schemas/spec-driven/"
echo "  diff -ru schemas/spec-driven/ schemas/casadei/"
