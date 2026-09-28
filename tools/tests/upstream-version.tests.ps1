<#
.SYNOPSIS
    Tests for tools/upstream-version.ps1.

.DESCRIPTION
    Each case builds a throwaway repo holding a copy of the script, its
    template, and a README with the upstream-version markers, plus an
    "upstream" commit with a package.json. No network access; exits non-zero if
    any case fails.

.PARAMETER Shell
    The PowerShell host that runs the script: 'pwsh' (7+) or 'powershell'
    (Windows PowerShell 5.1).

.EXAMPLE
    pwsh -File tools\tests\upstream-version.tests.ps1 -Shell powershell
#>
param(
    [ValidateSet('pwsh', 'powershell')]
    [string]$Shell = 'pwsh'
)

$ErrorActionPreference = 'Stop'

$RepoRoot  = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$BeginMark = '<!-- BEGIN upstream-version: generated from tools/readme-header.md, do not edit -->'
$EndMark   = '<!-- END upstream-version -->'

$script:passed = 0
$script:failed = 0
$script:failures = @()

function Fail([string]$Message) { $script:failures += $Message }

function Assert-Eq($Actual, $Expected, [string]$What) {
    if ($Actual -cne $Expected) { Fail "$What - expected '$Expected', got '$Actual'" }
}

function Assert-Output([string]$Needle) {
    if (-not $script:out.Contains($Needle)) { Fail "expected output to contain: $Needle" }
}

function Assert-Readme([string]$Needle) {
    if (-not (Get-Readme).Contains($Needle)) { Fail "expected README.md to contain: $Needle" }
}

# README.md with LF line endings, whatever the host wrote.
function Get-Readme { return ([IO.File]::ReadAllText((Join-Path $script:Repo 'README.md')) -replace "`r", '') }

# LF-only writes, so content checks don't depend on the host's newline.
function Write-File([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text) }

# Run git in the repo; native stderr must not trip ErrorActionPreference.
function Invoke-Git {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $result = & git -C $script:Repo @args 2>$null
    $ErrorActionPreference = $prev
    return $result
}

# A repo with the script, the template, a README with markers between other
# content, and an upstream commit ($script:Upstream) at version 1.13.2.
function New-Repo {
    $script:Repo = Join-Path $script:Sandbox 'repo'
    git init -q -b main $script:Repo 2>$null | Out-Null
    Invoke-Git config user.name 'Test Author' | Out-Null
    Invoke-Git config user.email 'test@example.com' | Out-Null
    Invoke-Git config core.autocrlf false | Out-Null
    $tools = Join-Path $script:Repo 'tools'
    New-Item -ItemType Directory -Force -Path $tools | Out-Null
    Copy-Item (Join-Path (Join-Path $RepoRoot 'tools') 'upstream-version.ps1') $tools
    Copy-Item (Join-Path (Join-Path $RepoRoot 'tools') 'readme-header.md') $tools
    Write-File (Join-Path $script:Repo 'README.md') "# Title`n`n$BeginMark`n$EndMark`n`nbody stays`n"
    Set-UpstreamVersion '1.13.2'
}

# Commit a package.json with version $Version; remember it as $script:Upstream.
function Set-UpstreamVersion([string]$Version) {
    Write-File (Join-Path $script:Repo 'package.json') ("{`n  `"name`": `"@fission-ai/openspec`",`n  `"version`": `"$Version`",`n" +
        "  `"dependencies`": {`n    `"x`": {`n      `"version`": `"9.9.9`"`n    }`n  }`n}`n")
    Invoke-Git add package.json | Out-Null
    Invoke-Git commit -q -m "upstream $Version" | Out-Null
    $script:Upstream = "$(Invoke-Git rev-parse HEAD)".Trim()
}

# Run the script in a child process, as a user would.
function Invoke-Script {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $script:out = (& $Shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Join-Path $script:Repo 'tools') 'upstream-version.ps1') @args 2>&1 | Out-String)
    $script:status = $LASTEXITCODE
    $ErrorActionPreference = $prev
}

function Test-WritesVersionAndCommitBetweenTheMarkers {
    Invoke-Script $script:Upstream
    Assert-Eq $script:status 0 'exit status'
    Assert-Readme 'synced_to_OpenSpec-v1.13.2-blue'
    Assert-Readme 'to **v1.13.2** (upstream commit'
    Assert-Readme "[``$($script:Upstream.Substring(0, 7))``](https://github.com/Fission-AI/OpenSpec/commit/$($script:Upstream))"
    Assert-Output "README.md now says v1.13.2 ($($script:Upstream.Substring(0, 7)))."
}

function Test-KeepsEverythingOutsideTheMarkers {
    Invoke-Script $script:Upstream
    $lines = @((Get-Readme).TrimEnd("`n") -split "`n")
    Assert-Eq ($lines[0..2] -join '|') "# Title||$BeginMark" 'lines before the block'
    Assert-Eq ($lines[-3..-1] -join '|') "$EndMark||body stays" 'lines after the block'
}

function Test-IsIdempotent {
    Invoke-Script $script:Upstream
    $before = Get-Readme
    Invoke-Script $script:Upstream
    Assert-Eq $script:status 0 'exit status on re-run'
    Assert-Eq (Get-Readme) $before 'README.md after re-run'
    Assert-Output 'already says v1.13.2'
}

function Test-MovesToANewerVersion {
    Invoke-Script $script:Upstream
    Set-UpstreamVersion '1.14.0'
    Invoke-Script $script:Upstream
    Assert-Eq $script:status 0 'exit status'
    Assert-Readme 'to **v1.14.0**'
    if ((Get-Readme).Contains('1.13.2')) { Fail 'old version still in README.md' }
}

function Test-CheckFailsWhenStaleAndLeavesReadmeAlone {
    $before = Get-Readme
    Invoke-Script -Check $script:Upstream
    Assert-Eq $script:status 1 'exit status'
    Assert-Output "upstream-version.ps1 $($script:Upstream.Substring(0, 7))"
    Assert-Eq (Get-Readme) $before 'README.md'
}

function Test-CheckPassesWhenCurrent {
    Invoke-Script $script:Upstream
    Invoke-Script -Check $script:Upstream
    Assert-Eq $script:status 0 'exit status'
}

function Test-KeepsCrlfLineEndings {
    $readme = Join-Path $script:Repo 'README.md'
    Write-File $readme ((Get-Readme) -replace "`n", "`r`n")
    Invoke-Script $script:Upstream
    $raw = [IO.File]::ReadAllText($readme)
    Assert-Eq (($raw -split "`r`n").Count) (($raw -split "`n").Count) 'every line ends in CRLF'
    $bytes = [IO.File]::ReadAllBytes($readme)
    if ($bytes[0] -eq 0xEF) { Fail 'README.md gained a byte order mark' }
}

function Test-EscapesDashesInTheBadgeOnly {
    Set-UpstreamVersion '2.0.0-beta.1'
    Invoke-Script $script:Upstream
    Assert-Eq $script:status 0 'exit status'
    Assert-Readme 'synced_to_OpenSpec-v2.0.0--beta.1-blue'
    Assert-Readme 'to **v2.0.0-beta.1**'
}

function Test-RejectsAVersionThatIsNotSemver {
    $before = Get-Readme
    Set-UpstreamVersion '1.0](https://evil.example'
    Invoke-Script $script:Upstream
    Assert-Eq $script:status 1 'exit status'
    Assert-Output 'no usable version'
    Assert-Eq (Get-Readme) $before 'README.md'
}

function Test-RejectsACommitWithoutPackageJson {
    Invoke-Git rm -q package.json | Out-Null
    Invoke-Git commit -q -m 'no package.json' | Out-Null
    Invoke-Script HEAD
    Assert-Eq $script:status 1 'exit status'
    Assert-Output 'has no package.json'
}

function Test-RejectsAReadmeWithoutMarkers {
    Write-File (Join-Path $script:Repo 'README.md') "# Title`n"
    Invoke-Script $script:Upstream
    Assert-Eq $script:status 1 'exit status'
    Assert-Output 'no upstream-version markers'
    Assert-Eq (Get-Readme) "# Title`n" 'README.md'
}

function Test-RejectsAnUnknownCommit {
    Invoke-Script 'no-such-commit'
    Assert-Eq $script:status 1 'exit status'
    Assert-Output 'is not a commit'
}

# Only functions defined in this file - Get-Command alone would also pick up
# every Test-* function from installed modules (the Az modules on CI runners).
$tests = Get-Command -CommandType Function -Name 'Test-*' |
    Where-Object { $_.ScriptBlock.File -eq $PSCommandPath } |
    Sort-Object Name

foreach ($t in $tests) {
    $script:failures = @()
    $script:out = ''
    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
    try {
        New-Repo
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
# Always exit explicitly: $LASTEXITCODE still holds the last script run (some
# cases expect it to fail), and CI hosts exit with it otherwise.
if ($script:failed -gt 0) { exit 1 }
exit 0
