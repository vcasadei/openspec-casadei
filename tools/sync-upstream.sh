#!/usr/bin/env bash
# Merge upstream OpenSpec into this fork.
#
#   ./tools/sync-upstream.sh
#
# This fork carries only a small slice of upstream's tree, so a merge touches
# three kinds of path, each handled differently:
#
#   tracked   Paths the fork follows from upstream (TRACKED_PREFIXES below).
#             Upstream changes merge in normally; a conflict here is real and
#             is left for a human.
#   everything else
#             Outside the tracked paths, the fork's tree is kept exactly as it
#             was before the merge. That covers both halves at once:
#               - fork-owned files (README.md, NOTICE.md, tools/, our workflows)
#                 keep our version, even when upstream edits a file of the same
#                 name - upstream has its own README.md, for instance;
#               - upstream-only files (the CLI source, tests, website, ...)
#                 stay out, whether upstream modified or re-added them.
#
# Exits 0 when merged (or already up to date), 1 when a tracked path conflicts
# or the working tree is dirty.
set -euo pipefail

UPSTREAM_URL="https://github.com/Fission-AI/OpenSpec.git"

# Paths this fork follows from upstream. Keep in sync with sync-upstream.ps1.
TRACKED_PREFIXES=("schemas/" "skills/" "docs/" "LICENSE" ".gitattributes" ".gitignore")

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
echo "Upstream commits not yet merged: $(git rev-list --count HEAD..upstream/main)"
# -30 rather than `| head -30`: under pipefail, head closing the pipe early
# kills git log with SIGPIPE and aborts the script before the merge.
git log --oneline -30 HEAD..upstream/main
echo

is_tracked() {
  local path="$1" prefix
  for prefix in "${TRACKED_PREFIXES[@]}"; do
    case "$path" in "$prefix"*) return 0 ;; esac
  done
  return 1
}

# --no-commit: even a clean merge must stop here, so the path pass below runs
# before anything is committed. Conflicts are expected too; that is normal.
git merge upstream/main --no-commit --no-ff >/dev/null 2>&1 || true

if ! git rev-parse -q --verify MERGE_HEAD >/dev/null; then
  echo "Error: git merge did not start. Run 'git merge upstream/main' to see why." >&2
  exit 1
fi

# Every path the merge touched, conflicted or not. Collected up front because
# the loop below rewrites the index.
touched=()
while IFS= read -r path; do
  [ -n "$path" ] && touched+=("$path")
done < <({ git diff --cached --name-only --no-renames HEAD; git diff --name-only --diff-filter=U; } | sort -u)

restored=0
dropped=0
for path in ${touched[@]+"${touched[@]}"}; do
  if is_tracked "$path"; then
    continue
  fi
  if git cat-file -e "HEAD:$path" 2>/dev/null; then
    # Fork-owned: put back exactly what we had (this also resolves a conflict).
    git checkout -q HEAD -- "$path"
    restored=$((restored + 1))
  else
    # Upstream-only: keep it out of the fork.
    git rm -q -f --cached --ignore-unmatch -- "$path" >/dev/null 2>&1 || true
    rm -f -- "$path"
    dropped=$((dropped + 1))
  fi
done

echo "Kept the fork's version of $restored file(s); left out $dropped upstream-only file(s)."

remaining="$(git diff --name-only --diff-filter=U)"
if [ -n "$remaining" ]; then
  echo
  echo "Conflicts needing your attention:"
  while IFS= read -r line; do echo "  $line"; done <<< "$remaining"
  echo
  echo "Resolve them, then: git add <files> && git commit"
  exit 1
fi

# Commit even when nothing tracked changed: recording the merge is what moves
# the merge base forward, so the next sync starts from here.
git commit -q --no-edit
echo
echo "Merged upstream/main ($(git rev-parse --short upstream/main)) into $(git rev-parse --abbrev-ref HEAD)."

changed="$(git diff --name-only HEAD~1 HEAD -- "${TRACKED_PREFIXES[@]}")"
if [ -z "$changed" ]; then
  echo "No tracked paths changed."
else
  echo "Tracked paths changed: $(echo "$changed" | wc -l | tr -d ' ')"
fi
if git diff --quiet HEAD~1 HEAD -- schemas/spec-driven/; then
  :
else
  echo
  echo "Upstream changed the baseline schema. Review it and port what's worth keeping:"
  echo "  git diff HEAD~1 -- schemas/spec-driven/"
  echo "  diff -ru schemas/spec-driven/ schemas/casadei/"
fi
