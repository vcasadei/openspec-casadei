<#
.SYNOPSIS
    Merge upstream OpenSpec into this fork.

.DESCRIPTION
    This fork carries only a small slice of upstream's tree, so a merge touches
    three kinds of path, each handled differently:

      tracked   Paths the fork follows from upstream ($TrackedPrefixes below).
                Upstream changes merge in normally; a conflict here is real and
                is left for a human.
      everything else
                Outside the tracked paths, the fork's tree is kept exactly as it
                was before the merge. Fork-owned files (README.md, NOTICE.md,
                tools/, our workflows) keep our version even when upstream edits
                a file of the same name, and upstream-only files (the CLI
                source, tests, website, ...) stay out.

    Exits 0 when merged (or already up to date), 1 when a tracked path
    conflicts or the working tree is dirty.
#>
[CmdletBinding()]
param()

# Continue, not Stop: this script is all git calls checked via $LASTEXITCODE,
# and under Stop, Windows PowerShell 5.1 turns any redirected native stderr
# (git merge always writes some on conflict) into a terminating error.
$ErrorActionPreference = 'Continue'

$UpstreamUrl = 'https://github.com/Fission-AI/OpenSpec.git'

# Paths this fork follows from upstream. Keep in sync with sync-upstream.sh.
$TrackedPrefixes = @('schemas/', 'skills/', 'docs/', 'LICENSE', '.gitattributes', '.gitignore')

function Test-Tracked([string]$Path) {
    foreach ($prefix in $TrackedPrefixes) {
        if ($Path.StartsWith($prefix)) { return $true }
    }
    return $false
}

Set-Location (git rev-parse --show-toplevel)

if ((git status --porcelain).Length -gt 0) {
    Write-Host 'Error: working tree is dirty. Commit or stash first.'
    exit 1
}

git remote get-url upstream *>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Adding 'upstream' remote -> $UpstreamUrl"
    git remote add upstream $UpstreamUrl
}

Write-Host 'Fetching upstream...'
git fetch upstream main --tags

git merge-base --is-ancestor upstream/main HEAD
if ($LASTEXITCODE -eq 0) {
    Write-Host 'Already up to date with upstream/main. Nothing to do.'
    exit 0
}

Write-Host ''
Write-Host "Upstream commits not yet merged: $(git rev-list --count HEAD..upstream/main)"
git log --oneline -30 HEAD..upstream/main
Write-Host ''

# --no-commit: even a clean merge must stop here, so the path pass below runs
# before anything is committed. Conflicts are expected too; that is normal.
git merge upstream/main --no-commit --no-ff *>$null

git rev-parse -q --verify MERGE_HEAD *>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: git merge did not start. Run 'git merge upstream/main' to see why."
    exit 1
}

# Every path the merge touched, conflicted or not. Collected up front because
# the loop below rewrites the index.
$touched = @(@(git diff --cached --name-only --no-renames HEAD) + @(git diff --name-only --diff-filter=U) |
    Where-Object { $_ } | Sort-Object -Unique)

$restored = 0
$dropped = 0
foreach ($path in $touched) {
    if (Test-Tracked $path) { continue }
    git cat-file -e "HEAD:$path" *>$null
    if ($LASTEXITCODE -eq 0) {
        # Fork-owned: put back exactly what we had (this also resolves a conflict).
        git checkout -q HEAD -- $path
        $restored++
    } else {
        # Upstream-only: keep it out of the fork.
        git rm -q -f --cached --ignore-unmatch -- $path *>$null
        Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $path
        $dropped++
    }
}
$global:LASTEXITCODE = 0

Write-Host "Kept the fork's version of $restored file(s); left out $dropped upstream-only file(s)."

$remaining = @(git diff --name-only --diff-filter=U | Where-Object { $_ })
if ($remaining.Count -gt 0) {
    Write-Host ''
    Write-Host 'Conflicts needing your attention:'
    $remaining | ForEach-Object { Write-Host "  $_" }
    Write-Host ''
    Write-Host 'Resolve them, then: git add <files> && git commit'
    exit 1
}

# Record which upstream release the fork is now synced to, in the README
# header, as part of the merge commit itself. A failure here doesn't stop the
# merge; CI's --check then flags the stale header on the sync PR.
if (Test-Path 'tools\upstream-version.ps1') {
    $ok = $false
    try {
        & .\tools\upstream-version.ps1 upstream/main
        $ok = ($LASTEXITCODE -eq 0)
    } catch {
        Write-Host "   $_"
    }
    if ($ok) {
        git add README.md
    } else {
        Write-Host '!  README.md not updated; run .\tools\upstream-version.ps1 upstream/main by hand.'
    }
    $global:LASTEXITCODE = 0
}

# Commit even when nothing tracked changed: recording the merge is what moves
# the merge base forward, so the next sync starts from here.
git commit -q --no-edit
if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
Write-Host ''
Write-Host "Merged upstream/main ($(git rev-parse --short upstream/main)) into $(git rev-parse --abbrev-ref HEAD)."

$changed = @(git diff --name-only HEAD~1 HEAD -- $TrackedPrefixes | Where-Object { $_ })
if ($changed.Count -eq 0) {
    Write-Host 'No tracked paths changed.'
} else {
    Write-Host "Tracked paths changed: $($changed.Count)"
}
git diff --quiet HEAD~1 HEAD -- schemas/spec-driven/
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host "Upstream changed the baseline schema. Review it and port what's worth keeping:"
    Write-Host '  git diff HEAD~1 -- schemas/spec-driven/'
    Write-Host '  diff -ru schemas/spec-driven/ schemas/casadei/'
}
exit 0
