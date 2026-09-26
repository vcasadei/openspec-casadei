<#
.SYNOPSIS
    Merge upstream OpenSpec into this fork.

.DESCRIPTION
    This fork intentionally carries only a small slice of upstream's tree, so a
    merge produces a modify/delete conflict for every upstream file we dropped.
    Those are not real conflicts - we always want them to stay deleted. This
    script resolves them automatically and leaves only the conflicts that need a
    human: changes inside the paths we actually keep.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$UpstreamUrl = 'https://github.com/Fission-AI/OpenSpec.git'

# Paths this fork tracks. An unmerged path under one of these is a real conflict.
$KeepPrefixes = @('schemas/', 'skills/', 'docs/', 'LICENSE', '.gitattributes', '.gitignore')

function Test-Kept([string]$Path) {
    foreach ($prefix in $KeepPrefixes) {
        if ($Path.StartsWith($prefix)) { return $true }
    }
    return $false
}

Set-Location (git rev-parse --show-toplevel)

if ((git status --porcelain).Length -gt 0) {
    throw 'Working tree is dirty. Commit or stash first.'
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
Write-Host 'Upstream commits not yet merged:'
git log --oneline HEAD..upstream/main | Select-Object -First 30
Write-Host ''

# The merge is expected to fail on conflicts; that is the normal path here.
git merge upstream/main --no-edit
$global:LASTEXITCODE = 0

$autoResolved = 0
foreach ($path in @(git diff --name-only --diff-filter=U)) {
    if (-not $path -or (Test-Kept $path)) { continue }
    git rm -q -f --ignore-unmatch -- $path *>$null
    $autoResolved++
}

# Upstream may also re-add whole trees we pruned; drop anything staged outside
# the kept paths so the fork stays lean.
$readded = 0
foreach ($path in @(git diff --cached --name-only --diff-filter=A)) {
    if (-not $path -or (Test-Kept $path)) { continue }
    git rm -q -f --ignore-unmatch --cached -- $path *>$null
    Remove-Item -Force -ErrorAction SilentlyContinue -- $path
    $readded++
}

Write-Host "Auto-resolved $autoResolved dropped-file conflict(s); discarded $readded re-added file(s)."

$remaining = @(git diff --name-only --diff-filter=U)
if ($remaining.Count -gt 0) {
    Write-Host ''
    Write-Host 'Conflicts needing your attention:'
    $remaining | ForEach-Object { Write-Host "  $_" }
    Write-Host ''
    Write-Host 'Resolve them, then: git add <files> && git commit'
    exit 1
}

git commit --no-edit
Write-Host ''
Write-Host 'Merge complete. Now review what upstream changed in the baseline schema:'
Write-Host '  git diff HEAD~1 -- schemas/spec-driven/'
Write-Host '  diff -ru schemas/spec-driven/ schemas/casadei/'
