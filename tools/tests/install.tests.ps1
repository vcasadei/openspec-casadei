<#
.SYNOPSIS
    Tests for tools/install.ps1.

.DESCRIPTION
    Every case runs against a throwaway directory with USERPROFILE and
    XDG_DATA_HOME redirected into it, so the real ~/.claude/CLAUDE.md and user
    schema dir are never touched. Exits non-zero if any case fails.

.PARAMETER Shell
    The PowerShell host that runs the installer: 'pwsh' (7+) or 'powershell'
    (Windows PowerShell 5.1).

.EXAMPLE
    pwsh -File tools\tests\install.tests.ps1 -Shell powershell
#>
param(
    [ValidateSet('pwsh', 'powershell')]
    [string]$Shell = 'pwsh'
)

$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Installer  = Join-Path $RepoRoot 'tools\install.ps1'
$SchemaSrc  = Join-Path $RepoRoot 'schemas\casadei'
$RuleFile   = Join-Path $RepoRoot 'tools\authorship.md'
$BlockBegin = '<!-- BEGIN openspec-casadei: authorship -->'
$BlockEnd   = '<!-- END openspec-casadei: authorship -->'

$script:passed = 0
$script:failed = 0
$script:failures = @()

function Fail([string]$Message) { $script:failures += $Message }

function Assert-Eq($Actual, $Expected, [string]$What) {
    if ($Actual -ne $Expected) { Fail "$What - expected '$Expected', got '$Actual'" }
}

function Assert-File([string]$Path)   { if (-not (Test-Path $Path)) { Fail "expected $Path to exist" } }
function Assert-NoFile([string]$Path) { if (Test-Path $Path) { Fail "expected no file at $Path" } }

function Assert-Match([string]$Text, [string]$Needle) {
    if (-not $Text.Contains($Needle)) { Fail "expected output to contain: $Needle" }
}

# Lines strictly between the authorship markers, joined with LF.
function Get-BlockBody([string]$File) {
    if (-not (Test-Path $File)) { return $null }
    $lines = @(Get-Content $File)
    $b = [Array]::IndexOf($lines, $BlockBegin)
    $e = [Array]::IndexOf($lines, $BlockEnd)
    if ($b -lt 0 -or $e -le $b) { return $null }
    if ($e -eq $b + 1) { return '' }
    return ($lines[($b + 1)..($e - 1)] -join "`n")
}

function Get-Rule { return ((Get-Content $RuleFile -Raw) -replace '\r', '' -replace '\s+$', '') }

function Assert-BlockMatchesRule([string]$File) {
    Assert-Eq (Get-BlockBody $File) (Get-Rule) "authorship block in $File"
    $count = @(Get-Content $File | Where-Object { $_ -eq $BlockBegin }).Count
    Assert-Eq $count 1 "begin markers in $File"
}

function Test-SameTree([string]$A, [string]$B) {
    if (-not (Test-Path $B)) { return $false }
    $left  = @(Get-ChildItem $A -Recurse -File | ForEach-Object { $_.FullName.Substring($A.Length) } | Sort-Object)
    $right = @(Get-ChildItem $B -Recurse -File | ForEach-Object { $_.FullName.Substring($B.Length) } | Sort-Object)
    if (($left -join '|') -ne ($right -join '|')) { return $false }
    foreach ($rel in $left) {
        if ((Get-FileHash (Join-Path $A $rel)).Hash -ne (Get-FileHash (Join-Path $B $rel)).Hash) { return $false }
    }
    return $true
}

# Run the installer in a child process with an isolated profile.
function Invoke-Install {
    $env:USERPROFILE   = Join-Path $script:Sandbox 'home'
    $env:XDG_DATA_HOME = Join-Path $script:Sandbox 'xdg'
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $script:out = (& $Shell -NoProfile -ExecutionPolicy Bypass -File $Installer @args 2>&1 | Out-String)
    $script:status = $LASTEXITCODE
    $ErrorActionPreference = $prev
}

# A project with an openspec/config.yaml selecting the stock schema.
function New-Project([string]$Name) {
    $dir = Join-Path $script:Sandbox $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'openspec') | Out-Null
    @('schema: spec-driven', '', '# keep this comment') | Set-Content (Join-Path $dir 'openspec\config.yaml')
    return $dir
}

# --- -Project ----------------------------------------------------------------

function Test-ProjectInstallsAndSelectsSchema {
    $p = New-Project 'p'
    Invoke-Install -Project $p
    Assert-Eq $script:status 0 'exit status'
    if (-not (Test-SameTree $SchemaSrc (Join-Path $p 'openspec\schemas\casadei'))) { Fail 'schema copy differs from source' }
    $cfg = @(Get-Content (Join-Path $p 'openspec\config.yaml'))
    Assert-Eq $cfg[0] 'schema: casadei' 'first config line'
    if ($cfg -notcontains '# keep this comment') { Fail 'config comment was lost' }
}

function Test-ProjectWithoutClaudeWritesNoClaudeMd {
    $p = New-Project 'p'
    Invoke-Install -Project $p
    Assert-NoFile (Join-Path $p 'CLAUDE.md')
    Assert-NoFile (Join-Path $script:Sandbox 'home\.claude\CLAUDE.md')
}

function Test-ProjectClaudeCreatesClaudeMd {
    $p = New-Project 'p'
    Invoke-Install -Project $p -Claude
    Assert-Eq $script:status 0 'exit status'
    Assert-File (Join-Path $p 'CLAUDE.md')
    Assert-BlockMatchesRule (Join-Path $p 'CLAUDE.md')
    Assert-NoFile (Join-Path $script:Sandbox 'home\.claude\CLAUDE.md')
}

function Test-ProjectClaudeIsIdempotent {
    $p = New-Project 'p'
    $file = Join-Path $p 'CLAUDE.md'
    Invoke-Install -Project $p -Claude
    $before = Get-Content $file -Raw
    Invoke-Install -Project $p -Claude
    Assert-Eq $script:status 0 'exit status on re-run'
    Assert-Eq (Get-Content $file -Raw) $before 'CLAUDE.md after re-run'
    Assert-Match $script:out 'Refreshed the authorship rule'
}

function Test-ProjectClaudeAppendsToExistingFile {
    $p = New-Project 'p'
    $file = Join-Path $p 'CLAUDE.md'
    @('# Project notes', '', 'Use tabs.') | Set-Content $file
    Invoke-Install -Project $p -Claude
    $lines = @(Get-Content $file)
    Assert-Eq ($lines[0..2] -join '|') '# Project notes||Use tabs.' 'existing content'
    Assert-BlockMatchesRule $file
}

function Test-ProjectClaudeRefreshesStaleBlockOnly {
    $p = New-Project 'p'
    $file = Join-Path $p 'CLAUDE.md'
    @('before', $BlockBegin, 'stale rule', $BlockEnd, 'after') | Set-Content $file
    Invoke-Install -Project $p -Claude
    Assert-BlockMatchesRule $file
    $lines = @(Get-Content $file)
    Assert-Eq $lines[0] 'before' 'first line'
    Assert-Eq $lines[-1] 'after' 'last line'
    if ($lines -contains 'stale rule') { Fail 'stale rule was not replaced' }
}

function Test-ProjectClaudeLeavesUnterminatedBlockAlone {
    $p = New-Project 'p'
    $file = Join-Path $p 'CLAUDE.md'
    @($BlockBegin, 'no end marker') | Set-Content $file
    $before = Get-Content $file -Raw
    Invoke-Install -Project $p -Claude
    Assert-Eq (Get-Content $file -Raw) $before 'CLAUDE.md with no end marker'
    Assert-Match $script:out 'no closing one'
}

function Test-ProjectLeavesOtherPinnedSchema {
    $p = New-Project 'p'
    $cfg = Join-Path $p 'openspec\config.yaml'
    'schema: someone-elses' | Set-Content $cfg
    Invoke-Install -Project $p
    Assert-Eq $script:status 0 'exit status'
    Assert-Eq ((Get-Content $cfg -Raw).Trim()) 'schema: someone-elses' 'config'
}

function Test-ProjectWithoutConfigWarns {
    $dir = Join-Path $script:Sandbox 'bare'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Invoke-Install -Project $dir
    Assert-Eq $script:status 0 'exit status'
    Assert-File (Join-Path $dir 'openspec\schemas\casadei\schema.yaml')
    Assert-Match $script:out 'NOT selected'
}

function Test-ProjectRefusesToClobberDivergedSchema {
    $p = New-Project 'p'
    Invoke-Install -Project $p
    $schema = Join-Path $p 'openspec\schemas\casadei\schema.yaml'
    Add-Content $schema '# local edit'
    Invoke-Install -Project $p
    Assert-Eq $script:status 1 'exit status'
    if (-not ((Get-Content $schema -Raw).Contains('# local edit'))) { Fail 'local edit was discarded' }
}

# --- -User -------------------------------------------------------------------

function Test-UserInstallsSchemaAndClaudeMd {
    Invoke-Install -User
    Assert-Eq $script:status 0 'exit status'
    if (-not (Test-SameTree $SchemaSrc (Join-Path $script:Sandbox 'xdg\openspec\schemas\casadei'))) { Fail 'schema copy differs from source' }
    Assert-BlockMatchesRule (Join-Path $script:Sandbox 'home\.claude\CLAUDE.md')
}

function Test-UserNoClaudeMdSkipsIt {
    Invoke-Install -User -NoClaudeMd
    Assert-Eq $script:status 0 'exit status'
    Assert-NoFile (Join-Path $script:Sandbox 'home\.claude\CLAUDE.md')
}

function Test-UserRejectsClaudeSwitch {
    Invoke-Install -User -Claude
    if ($script:status -eq 0) { Fail 'expected a non-zero exit status' }
    Assert-NoFile (Join-Path $script:Sandbox 'xdg\openspec\schemas\casadei')
    Assert-NoFile (Join-Path $script:Sandbox 'home\.claude\CLAUDE.md')
}

function Test-UserAndProjectBlocksAreIdentical {
    $p = New-Project 'p'
    Invoke-Install -User
    Invoke-Install -Project $p -Claude
    Assert-Eq (Get-BlockBody (Join-Path $p 'CLAUDE.md')) (Get-BlockBody (Join-Path $script:Sandbox 'home\.claude\CLAUDE.md')) 'blocks'
}

$realProfile = $env:USERPROFILE
$realXdg     = $env:XDG_DATA_HOME

Write-Host "tools/install.ps1 (via $Shell)"
# Only functions defined in this file - Get-Command alone would also pick up
# every Test-* function from installed modules (the Az modules on CI runners).
$tests = Get-Command -CommandType Function -Name 'Test-*' |
    Where-Object { $_.ScriptBlock.File -eq $PSCommandPath -and $_.Name -ne 'Test-SameTree' } |
    Sort-Object Name

foreach ($t in $tests) {
    $script:failures = @()
    $script:out = ''
    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Force -Path (Join-Path $script:Sandbox 'home') | Out-Null
    try {
        & $t.Name
    } catch {
        Fail "threw: $_"
    } finally {
        $env:USERPROFILE   = $realProfile
        $env:XDG_DATA_HOME = $realXdg
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
# Always exit explicitly: $LASTEXITCODE still holds the last installer run
# (some cases expect it to fail), and CI hosts exit with it otherwise.
if ($script:failed -gt 0) { exit 1 }
exit 0
