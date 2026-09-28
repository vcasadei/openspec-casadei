<#
.SYNOPSIS
    Write which upstream OpenSpec release this fork is synced to into the README.

.DESCRIPTION
    <Commit> is the upstream commit the fork has merged: upstream/main right
    after a sync, or `git merge-base HEAD upstream/main` at any other time. The
    version is the "version" field of that commit's package.json.

    The header is tools/readme-header.md with its placeholders filled in,
    written between the upstream-version markers in README.md. Edit the
    template, not the README: anything between the markers is overwritten.
    sync-upstream.ps1 runs this on every merge. Keep in sync with
    upstream-version.sh, which reads the same template.

.EXAMPLE
    .\tools\upstream-version.ps1 upstream/main           # rewrite the header

.EXAMPLE
    .\tools\upstream-version.ps1 -Check upstream/main    # fail if out of date
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Commit,

    [switch]$Check
)

$ErrorActionPreference = 'Stop'

$Root     = Split-Path -Parent $PSScriptRoot
$Template = Join-Path $Root 'tools\readme-header.md'
$Readme   = Join-Path $Root 'README.md'
$BeginMark = '<!-- BEGIN upstream-version: generated from tools/readme-header.md, do not edit -->'
$EndMark   = '<!-- END upstream-version -->'
$Utf8      = New-Object System.Text.UTF8Encoding($false)

# Windows PowerShell 5.1 turns a native command's stderr into a terminating
# error under 'Stop', so git runs under 'Continue' and is checked by exit code.
function Invoke-Git {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $Root @args 2>$null
        return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Out = $out }
    } finally {
        $ErrorActionPreference = $prev
        $global:LASTEXITCODE = 0
    }
}

$rev = Invoke-Git rev-parse --verify --quiet "$Commit^{commit}"
if (-not $rev.Ok) {
    Write-Host "Error: '$Commit' is not a commit."
    exit 1
}
$sha = "$($rev.Out)".Trim()
$shortSha = $sha.Substring(0, 7)

$show = Invoke-Git show "${sha}:package.json"
if (-not $show.Ok) {
    Write-Host "Error: upstream commit $shortSha has no package.json."
    exit 1
}
# The top-level "version" is the first one indented by exactly two spaces.
$version = ''
foreach ($line in @($show.Out)) {
    if ($line -match '^  "version": *"([^"]*)"') { $version = $Matches[1]; break }
}

# The value lands in a URL and in Markdown, so accept only a plain semver.
if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$') {
    Write-Host "Error: package.json at $shortSha has no usable version (got '$version')."
    exit 1
}

# shields.io reads '-' as a separator, so a literal dash is written '--'.
$badgeVersion = $version.Replace('-', '--')

$header = @(Get-Content $Template -Encoding UTF8 | ForEach-Object {
    $_.Replace('@VERSION@', $version).Replace('@BADGE_VERSION@', $badgeVersion).
       Replace('@SHORT_SHA@', $shortSha).Replace('@SHA@', $sha)
})

$text = [IO.File]::ReadAllText($Readme, $Utf8)
$newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
$lines = @($text -split "`r?`n")
# A file ending in a newline splits into a final empty element; drop it and
# add the newline back when writing.
if ($lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = @($lines[0..($lines.Count - 2)]) }

$b = [Array]::IndexOf($lines, $BeginMark)
$e = [Array]::IndexOf($lines, $EndMark)
if ($b -lt 0 -or $e -le $b) {
    Write-Host 'Error: README.md has no upstream-version markers. Expected these two lines:'
    Write-Host "  $BeginMark"
    Write-Host "  $EndMark"
    exit 1
}

$head = $lines[0..$b]
$tail = $lines[$e..($lines.Count - 1)]
$updated = (@($head) + $header + @($tail)) -join $newline

if ($updated + $newline -ceq $text) {
    Write-Host "README.md already says v$version ($shortSha)."
    exit 0
}

if ($Check) {
    Write-Host "Error: README.md does not say which upstream it is synced to (v$version, $shortSha)."
    Write-Host "Run: .\tools\upstream-version.ps1 $shortSha"
    exit 1
}

[IO.File]::WriteAllText($Readme, $updated + $newline, $Utf8)
Write-Host "README.md now says v$version ($shortSha)."
exit 0
