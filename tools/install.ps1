<#
.SYNOPSIS
    Install the Casadei OpenSpec schema so the upstream `openspec` CLI can find it.

.DESCRIPTION
    -Project also selects the schema in that project's openspec/config.yaml.
    -User also installs the authorship rule into ~/.claude/CLAUDE.md, so it
    applies to every session rather than only to an /opsx:apply run.
    -Project -Claude also writes the authorship rule into <project>\CLAUDE.md,
    so it is committed with the repo.

.EXAMPLE
    .\tools\install.ps1 -Project C:\path\to\repo   # project-local (priority 1)

.EXAMPLE
    .\tools\install.ps1 -Project C:\path\to\repo -Claude   # + <project>\CLAUDE.md

.EXAMPLE
    .\tools\install.ps1 -User                      # per-machine    (priority 2)

.EXAMPLE
    .\tools\install.ps1 -User -NoClaudeMd          # skip ~/.claude/CLAUDE.md

.NOTES
    See README.md for the schema resolution order.
#>
[CmdletBinding(DefaultParameterSetName = 'User')]
param(
    [Parameter(Mandatory, ParameterSetName = 'User')]
    [switch]$User,

    [Parameter(ParameterSetName = 'User')]
    [switch]$NoClaudeMd,

    [Parameter(Mandatory, ParameterSetName = 'Project')]
    [string]$Project,

    [Parameter(ParameterSetName = 'Project')]
    [switch]$Claude
)

$ErrorActionPreference = 'Stop'

$SchemaName = 'casadei'
$RepoRoot   = Split-Path -Parent $PSScriptRoot
$SourceDir  = Join-Path $RepoRoot "schemas\$SchemaName"
$BlockBegin = '<!-- BEGIN openspec-casadei: authorship -->'
$BlockEnd   = '<!-- END openspec-casadei: authorship -->'
$RuleFile   = Join-Path $RepoRoot 'tools\authorship.md'

if (-not (Test-Path $SourceDir)) {
    throw "Schema not found at $SourceDir"
}

# Mirrors getGlobalDataDir() in the upstream CLI: XDG_DATA_HOME wins on every
# platform when set, otherwise Windows uses %LOCALAPPDATA%.
function Get-UserSchemasDir {
    if ($env:XDG_DATA_HOME) {
        return Join-Path $env:XDG_DATA_HOME 'openspec\schemas'
    }
    if ($env:LOCALAPPDATA) {
        return Join-Path $env:LOCALAPPDATA 'openspec\schemas'
    }
    return Join-Path $env:USERPROFILE 'AppData\Local\openspec\schemas'
}

# Point a project's openspec/config.yaml at this schema.
#
# Only rewrites a top-level `schema:` line that still holds the stock
# `spec-driven` value. A project that deliberately pins some other schema is
# left alone and reported - silently retargeting someone's chosen workflow
# would be worse than making them type one line.
function Set-ProjectSchema([string]$Root) {
    $cfg = Join-Path $Root 'openspec\config.yaml'

    if (-not (Test-Path $cfg)) {
        Write-Host "!  No openspec/config.yaml in $Root - schema installed but NOT selected."
        Write-Host "   Run 'openspec init' there, then re-run this installer (or set"
        Write-Host "   'schema: $SchemaName' by hand)."
        return
    }

    $lines = @(Get-Content $cfg)
    $idx = -1
    $current = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^schema:\s*([^#\s]*)') {
            $idx = $i
            $current = $Matches[1]
            break
        }
    }

    if ($idx -lt 0 -or [string]::IsNullOrWhiteSpace($current)) {
        # No top-level schema: key at all (hand-edited config). Add one at the top.
        , ("schema: $SchemaName") + $lines | Set-Content $cfg -Encoding utf8
        Write-Host "   Added 'schema: $SchemaName' to openspec/config.yaml (no schema key was set)."
        return
    }

    if ($current -eq $SchemaName) {
        Write-Host "   openspec/config.yaml already selects 'schema: $SchemaName'."
        return
    }

    if ($current -ne 'spec-driven') {
        Write-Host "!  openspec/config.yaml pins 'schema: $current' - left unchanged."
        Write-Host "   Change it to '$SchemaName' by hand if that is what you meant."
        return
    }

    $lines[$idx] = "schema: $SchemaName"
    $lines | Set-Content $cfg -Encoding utf8
    Write-Host "   Set 'schema: $SchemaName' in openspec/config.yaml (was 'spec-driven')."
}

# Install the authorship rule into a CLAUDE.md.
#
# It lives here rather than only in the schema's apply instruction because the
# apply instruction is only in context during an /opsx:apply run - a plain
# "commit this" would never see it. Written inside a delimited block so the
# file can be re-written idempotently without touching anything else in it.
#
#   $File - ~/.claude/CLAUDE.md (-User) or <project>\CLAUDE.md (-Project -Claude)
function Install-ClaudeMd([string]$File) {
    $dir = Split-Path -Parent $File

    # Single source shared with install.sh, so the two installers cannot drift.
    if (-not (Test-Path $RuleFile)) {
        throw "Authorship rule not found at $RuleFile"
    }
    $body = ((Get-Content $RuleFile -Raw) -replace '\s+$', '')

    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    if (-not (Test-Path $file)) {
        ($BlockBegin, $body, $BlockEnd) -join "`n" | Set-Content $file -Encoding utf8
        Write-Host "   Created $file with the authorship rule."
        return
    }

    $lines = @(Get-Content $file)
    $b = [Array]::FindIndex($lines, [Predicate[string]] { $args[0] -eq $BlockBegin })
    $e = [Array]::FindIndex($lines, [Predicate[string]] { $args[0] -eq $BlockEnd })

    if ($b -ge 0) {
        if ($e -gt $b) {
            $head = if ($b -gt 0) { $lines[0..($b - 1)] } else { @() }
            $tail = if ($e -lt ($lines.Count - 1)) { $lines[($e + 1)..($lines.Count - 1)] } else { @() }
            $out = @($head) + @($BlockBegin) + @($body -split "`r?`n") + @($BlockEnd) + @($tail)
            $out | Set-Content $file -Encoding utf8
            Write-Host "   Refreshed the authorship rule in $file."
        } else {
            Write-Host "!  $file has an opening marker but no closing one - left unchanged."
            Write-Host "   Repair it by hand, then re-run."
        }
        return
    }

    $append = @('') + @($BlockBegin) + @($body -split "`r?`n") + @($BlockEnd)
    $append | Add-Content $file -Encoding utf8
    Write-Host "   Appended the authorship rule to $file (existing content kept)."
}

if ($PSCmdlet.ParameterSetName -eq 'User') {
    $destParent  = Get-UserSchemasDir
    $projectRoot = $null
} else {
    if (-not (Test-Path $Project -PathType Container)) {
        throw "Not a directory: $Project"
    }
    $projectRoot = (Resolve-Path $Project).Path
    $destParent  = Join-Path $projectRoot 'openspec\schemas'
}

$dest = Join-Path $destParent $SchemaName

# Refuse to clobber a schema that has diverged locally; it may have been edited
# in place and we must not silently discard that.
if (Test-Path $dest) {
    $left  = Get-ChildItem $SourceDir -Recurse -File | Sort-Object FullName
    $right = Get-ChildItem $dest      -Recurse -File | Sort-Object FullName
    $differs = $left.Count -ne $right.Count
    if (-not $differs) {
        for ($i = 0; $i -lt $left.Count; $i++) {
            if ((Get-FileHash $left[$i].FullName).Hash -ne (Get-FileHash $right[$i].FullName).Hash) {
                $differs = $true
                break
            }
        }
    }
    if ($differs) {
        Write-Error @"
$dest already exists and differs from this repo's copy.
Inspect it, then remove it if you want to overwrite.
"@
        exit 1
    }
}

New-Item -ItemType Directory -Force -Path $destParent | Out-Null
if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
Copy-Item -Recurse $SourceDir $dest

Write-Host "Installed schema '$SchemaName' -> $dest"

if ($PSCmdlet.ParameterSetName -eq 'Project') {
    Set-ProjectSchema $projectRoot
    if ($Claude) {
        Install-ClaudeMd (Join-Path $projectRoot 'CLAUDE.md')
    }
    Write-Host ""
    Write-Host "Verify with: openspec schema which $SchemaName"
} else {
    if ($NoClaudeMd) {
        Write-Host "   Skipped ~/.claude/CLAUDE.md (-NoClaudeMd)."
    } else {
        Install-ClaudeMd (Join-Path (Join-Path $env:USERPROFILE '.claude') 'CLAUDE.md')
    }
    Write-Host ""
    Write-Host "!  A user-level schema is installed but not selected anywhere."
    Write-Host "   Each project still needs 'schema: $SchemaName' in openspec/config.yaml."
    Write-Host "   Run this installer with -Project <path> to set that automatically."
    Write-Host ""
    Write-Host "Verify with: openspec schema which $SchemaName"
}
