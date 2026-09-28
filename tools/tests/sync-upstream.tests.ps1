<#
.SYNOPSIS
    Tests for tools/sync-upstream.ps1.

.DESCRIPTION
    Each case builds a throwaway "upstream" repo and a "fork" of it that prunes
    upstream's tree the way this repo does, then runs the sync script inside the
    fork. No network access; exits non-zero if any case fails.

.PARAMETER Shell
    The PowerShell host that runs the sync script: 'pwsh' (7+) or 'powershell'
    (Windows PowerShell 5.1).

.EXAMPLE
    pwsh -File tools\tests\sync-upstream.tests.ps1 -Shell powershell
#>
param(
    [ValidateSet('pwsh', 'powershell')]
    [string]$Shell = 'pwsh'
)

$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SyncScript = Join-Path $RepoRoot 'tools\sync-upstream.ps1'

$script:passed = 0
$script:failed = 0
$script:failures = @()

function Fail([string]$Message) { $script:failures += $Message }

function Assert-Eq($Actual, $Expected, [string]$What) {
    if ($Actual -ne $Expected) { Fail "$What - expected '$Expected', got '$Actual'" }
}

function Assert-Output([string]$Needle) {
    if (-not $script:out.Contains($Needle)) { Fail "expected output to contain: $Needle" }
}

function Assert-Absent([string]$Rel) {
    if (Test-Path (Join-Path $script:Fork $Rel)) { Fail "expected $Rel to be absent from the fork" }
}

# Run git in a directory; native stderr must not trip ErrorActionPreference.
function Invoke-Git([string]$Dir) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $result = & git -C $Dir @args 2>$null
    $ErrorActionPreference = $prev
    return $result
}

# LF-only writes, so content checks don't depend on the host's newline.
function Write-File([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Text)
}

function Read-Fork([string]$Rel) {
    return ([IO.File]::ReadAllText((Join-Path $script:Fork $Rel)) -replace "`r", '').TrimEnd("`n")
}

function Initialize-Repo([string]$Dir) {
    Invoke-Git $Dir config user.name 'Test Author' | Out-Null
    Invoke-Git $Dir config user.email 'test@example.com' | Out-Null
    Invoke-Git $Dir config core.autocrlf false | Out-Null
}

# Upstream: a README, CLI source, a workflow, the baseline schema, and docs.
# Fork: a clone that drops src/ and .github/, rewrites line 1 of the README,
# and adds its own tools/ and NOTICE.md - the shape of this repository.
function New-Repos {
    $script:Upstream = Join-Path $script:Sandbox 'upstream'
    $script:Fork     = Join-Path $script:Sandbox 'fork'
    $u = $script:Upstream

    git init -q -b main $u 2>$null | Out-Null
    Initialize-Repo $u
    Write-File "$u\README.md" "upstream readme`nb`nc`nd`ne`n"
    Write-File "$u\src\cli.ts" "export const cli = 1`n"
    Write-File "$u\.github\workflows\ci.yml" "name: ci`n"
    Write-File "$u\schemas\spec-driven\schema.yaml" "name: spec-driven`nversion: 1`n"
    Write-File "$u\docs\guide.md" "guide line 1`nguide line 2`n"
    Invoke-Git $u add -A | Out-Null
    Invoke-Git $u commit -q -m 'upstream: initial' | Out-Null

    # autocrlf off at clone time: Windows runners default it to true, which
    # would check files out as CRLF and make every one look modified.
    git -c core.autocrlf=false clone -q $u $script:Fork 2>$null | Out-Null
    $f = $script:Fork
    Initialize-Repo $f
    Invoke-Git $f remote rename origin upstream | Out-Null
    Invoke-Git $f rm -q -r src .github | Out-Null
    Write-File "$f\README.md" "fork readme`nb`nc`nd`ne`n"
    Write-File "$f\NOTICE.md" "fork notice`n"
    New-Item -ItemType Directory -Force -Path "$f\tools" | Out-Null
    Copy-Item $SyncScript "$f\tools\sync-upstream.ps1"
    Invoke-Git $f add -A | Out-Null
    Invoke-Git $f commit -q -m 'fork: prune' | Out-Null
    if ((Test-Path "$f\src") -or (Invoke-Git $f status --porcelain)) {
        throw 'fixture setup failed: the fork did not prune cleanly'
    }
}

# Make a commit in upstream after running $Change there.
function New-UpstreamCommit([string]$Message, [scriptblock]$Change) {
    Push-Location $script:Upstream
    try { & $Change } finally { Pop-Location }
    Invoke-Git $script:Upstream add -A | Out-Null
    Invoke-Git $script:Upstream commit -q -m $Message | Out-Null
}

function Invoke-Sync {
    Push-Location $script:Fork
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $script:out = (& $Shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Fork 'tools\sync-upstream.ps1') 2>&1 | Out-String)
        $script:status = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
        Pop-Location
    }
}

# --- cases -------------------------------------------------------------------

function Test-AlreadyUpToDateIsANoOp {
    $before = Invoke-Git $script:Fork rev-parse HEAD
    Invoke-Sync
    Assert-Eq $script:status 0 'exit status'
    Assert-Output 'Already up to date'
    Assert-Eq (Invoke-Git $script:Fork rev-parse HEAD) $before 'HEAD'
}

function Test-MergesTrackedChanges {
    New-UpstreamCommit 'schema v2' { Write-File "$PWD\schemas\spec-driven\schema.yaml" "name: spec-driven`nversion: 2`n" }
    Invoke-Sync
    Assert-Eq $script:status 0 'exit status'
    Assert-Eq (Read-Fork 'schemas\spec-driven\schema.yaml') "name: spec-driven`nversion: 2" 'schema'
    Assert-Eq (@((Invoke-Git $script:Fork log -1 --format=%p HEAD) -split ' ').Count) 2 'merge commit parents'
    Assert-Output 'Upstream changed the baseline schema'
}

function Test-KeepsForkReadmeWhenUpstreamEditsTheSameLines {
    New-UpstreamCommit 'upstream readme' { Write-File "$PWD\README.md" "new upstream readme`nb`nc`nd`ne`n" }
    Invoke-Sync
    Assert-Eq $script:status 0 'exit status'
    Assert-Eq (Read-Fork 'README.md') "fork readme`nb`nc`nd`ne" 'README.md'
}

function Test-KeepsForkReadmeWhenUpstreamEditWouldMergeCleanly {
    New-UpstreamCommit 'upstream readme tail' { Write-File "$PWD\README.md" "upstream readme`nb`nc`nd`nUPSTREAM`n" }
    Invoke-Sync
    Assert-Eq $script:status 0 'exit status'
    Assert-Eq (Read-Fork 'README.md') "fork readme`nb`nc`nd`ne" 'README.md'
}

function Test-IgnoresUpstreamFilesUnderForkOwnedDirs {
    New-UpstreamCommit 'upstream tools' {
        Write-File "$PWD\tools\extra.ps1" "x`n"
        Write-File "$PWD\NOTICE.md" "y`n"
    }
    Invoke-Sync
    Assert-Eq $script:status 0 'exit status'
    Assert-Absent 'tools\extra.ps1'
    Assert-Eq (Read-Fork 'NOTICE.md') 'fork notice' 'NOTICE.md'
}

function Test-KeepsDroppedFilesOutWhenUpstreamModifiesThem {
    New-UpstreamCommit 'cli v2' {
        Write-File "$PWD\src\cli.ts" "export const cli = 2`n"
        Write-File "$PWD\.github\workflows\ci.yml" "name: ci2`n"
    }
    Invoke-Sync
    Assert-Eq $script:status 0 'exit status'
    Assert-Absent 'src\cli.ts'
    Assert-Absent '.github\workflows\ci.yml'
    Assert-Eq ((Invoke-Git $script:Fork status --porcelain) -join '|') '' 'working tree after sync'
}

function Test-KeepsNewUpstreamFilesOut {
    New-UpstreamCommit 'new files' {
        Write-File "$PWD\src\new.ts" "n`n"
        Write-File "$PWD\website\index.html" "w`n"
    }
    Invoke-Sync
    Assert-Eq $script:status 0 'exit status'
    Assert-Absent 'src\new.ts'
    Assert-Absent 'website\index.html'
}

function Test-NonTrackedTreeIsUnchangedByTheMerge {
    New-UpstreamCommit 'mixed' {
        Add-Content "$PWD\README.md" 'z'
        Write-File "$PWD\src\new.ts" "n`n"
        Add-Content "$PWD\docs\guide.md" 'more'
    }
    Invoke-Sync
    Assert-Eq $script:status 0 'exit status'
    Assert-Eq ((Invoke-Git $script:Fork diff --name-only HEAD~1 HEAD) -join '|') 'docs/guide.md' 'paths changed by the merge'
}

function Test-MergesMoreThanThirtyCommits {
    foreach ($i in 1..35) {
        New-UpstreamCommit "doc $i" ([scriptblock]::Create("Add-Content `"`$PWD\docs\guide.md`" '$i'"))
    }
    Invoke-Sync
    Assert-Eq $script:status 0 'exit status'
    Assert-Output 'Upstream commits not yet merged: 35'
    Assert-Eq ((Read-Fork 'docs\guide.md') -split "`n")[-1] '35' 'last guide line'
}

function Test-TrackedConflictIsLeftForAHuman {
    Write-File "$($script:Fork)\docs\guide.md" "fork guide`nguide line 2`n"
    Invoke-Git $script:Fork commit -q -am 'fork: edit guide' | Out-Null
    New-UpstreamCommit 'upstream guide' { Write-File "$PWD\docs\guide.md" "upstream guide`nguide line 2`n" }
    New-UpstreamCommit 'upstream readme' { Write-File "$PWD\README.md" "new upstream readme`nb`nc`nd`ne`n" }
    Invoke-Sync
    Assert-Eq $script:status 1 'exit status'
    Assert-Output 'Conflicts needing your attention:'
    Assert-Eq ((Invoke-Git $script:Fork diff --name-only --diff-filter=U) -join '|') 'docs/guide.md' 'unmerged paths'
    Assert-Eq ((Read-Fork 'README.md') -split "`n")[0] 'fork readme' 'README.md line 1'
}

function Test-RefusesADirtyTree {
    New-UpstreamCommit 'doc' { Add-Content "$PWD\docs\guide.md" '1' }
    Add-Content "$($script:Fork)\README.md" 'dirty'
    Invoke-Sync
    Assert-Eq $script:status 1 'exit status'
    Assert-Output 'working tree is dirty'
}

Write-Host "tools/sync-upstream.ps1 (via $Shell)"
# Only functions defined in this file - Get-Command alone would also pick up
# every Test-* function from installed modules (the Az modules on CI runners).
# --- upstream version in the README -----------------------------------------

# Give the fork the version script, its template, and a README with markers.
function Add-VersionScript {
    $f = $script:Fork
    Copy-Item (Join-Path $RepoRoot 'tools\upstream-version.ps1') "$f\tools\upstream-version.ps1"
    Copy-Item (Join-Path $RepoRoot 'tools\readme-header.md') "$f\tools\readme-header.md"
    Write-File "$f\README.md" ("fork readme`n" +
        "<!-- BEGIN upstream-version: generated from tools/readme-header.md, do not edit -->`n" +
        "<!-- END upstream-version -->`n")
    Invoke-Git $f add -A | Out-Null
    Invoke-Git $f commit -q -m 'fork: version script' | Out-Null
}

function Test-RecordsTheUpstreamVersionInTheMergeCommit {
    Add-VersionScript
    New-UpstreamCommit 'release 1.14.0' { Write-File (Join-Path $script:Upstream 'package.json') "{`n  `"version`": `"1.14.0`"`n}`n" }
    Invoke-Sync
    Assert-Eq $script:status 0 'exit status'
    Assert-Output 'README.md now says v1.14.0'
    $committed = (Invoke-Git $script:Fork show HEAD:README.md) -join "`n"
    if (-not $committed.Contains('to **v1.14.0**')) { Fail "merge commit's README.md lacks v1.14.0" }
    Assert-Eq (@((Invoke-Git $script:Fork log -1 --format=%p HEAD) -split ' ').Count) 2 'merge commit parents'
    Assert-Eq "$(Invoke-Git $script:Fork status --porcelain)" '' 'working tree after sync'
    Assert-Absent 'package.json'
}

function Test-MergesEvenWhenTheVersionCannotBeRead {
    Add-VersionScript
    New-UpstreamCommit 'doc' { Add-Content -Path (Join-Path $script:Upstream 'docs\guide.md') -Value '1' }
    Invoke-Sync
    Assert-Eq $script:status 0 'exit status'
    Assert-Output 'README.md not updated'
    Assert-Eq (@((Invoke-Git $script:Fork log -1 --format=%p HEAD) -split ' ').Count) 2 'merge commit parents'
}

$tests = Get-Command -CommandType Function -Name 'Test-*' |
    Where-Object { $_.ScriptBlock.File -eq $PSCommandPath } |
    Sort-Object Name

foreach ($t in $tests) {
    $script:failures = @()
    $script:out = ''
    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
    try {
        New-Repos
        & $t.Name
    } catch {
        Fail "threw: $_"
    } finally {
        Remove-Item -Recurse -Force $script:Sandbox -ErrorAction SilentlyContinue
    }
    if ($script:failures.Count -eq 0) {
        Write-Host "  ok   $($t.Name)"
        $script:passed++
    } else {
        Write-Host "  FAIL $($t.Name)"
        $script:failures | ForEach-Object { Write-Host "    $_" }
        ($script:out -split "`r?`n") | ForEach-Object { Write-Host "       | $_" }
        $script:failed++
    }
}

Write-Host ""
Write-Host "$($script:passed) passed, $($script:failed) failed"
# Always exit explicitly: $LASTEXITCODE still holds the last sync run
# (some cases expect it to fail), and CI hosts exit with it otherwise.
if ($script:failed -gt 0) { exit 1 }
exit 0
