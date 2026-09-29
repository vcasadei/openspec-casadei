<#
.SYNOPSIS
    Install the Casadei OpenSpec schema so the upstream `openspec` CLI can find it.

.DESCRIPTION
    -Project also selects the schema in that project's openspec/config.yaml.
    -User also installs the authorship rule into ~/.claude/CLAUDE.md, so it
    applies to every session rather than only to an /opsx:apply run.
    -Project -Claude also writes the authorship rule into <project>\CLAUDE.md
    (warning if that path is git-ignored, which keeps the rule local),
    so it is committed with the repo.
    -Project -Secrets medium also sets up secret protection: .gitignore rules,
    a gitleaks pre-commit hook, and a GitHub Actions secret scan. -Secrets high
    adds openspec/secrets-policy.md on top. The schema's own secret rules apply
    at every level.

.EXAMPLE
    .\tools\install.ps1 -Project C:\path\to\repo   # project-local (priority 1)

.EXAMPLE
    .\tools\install.ps1 -Project C:\path\to\repo -Claude   # + <project>\CLAUDE.md

.EXAMPLE
    .\tools\install.ps1 -Project C:\path\to\repo -Secrets high   # + secret protection

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
    [switch]$Claude,

    [Parameter(ParameterSetName = 'Project')]
    [ValidateSet('medium', 'high')]
    [string]$Secrets
)

$ErrorActionPreference = 'Stop'

$SchemaName = 'casadei'
$RepoRoot   = Split-Path -Parent $PSScriptRoot
$SourceDir  = Join-Path $RepoRoot "schemas\$SchemaName"
$BlockBegin = '<!-- BEGIN openspec-casadei: authorship -->'
$BlockEnd   = '<!-- END openspec-casadei: authorship -->'
$RuleFile   = Join-Path $RepoRoot 'tools\authorship.md'
$SecretsDir   = Join-Path $RepoRoot 'tools\secrets'
$SecretsBegin = '# BEGIN openspec-casadei: secrets'
$SecretsEnd   = '# END openspec-casadei: secrets'

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

# Write a delimited block into a file, idempotently: create the file if it is
# missing, append the block if the file has none, otherwise rewrite only what
# is between the markers. Everything outside the block is left untouched.
#
#   $File  - target file
#   $Begin - opening marker line
#   $End   - closing marker line
#   $Body  - block body
#   $What  - what the block is, for messages ("the authorship rule")
function Install-Block([string]$File, [string]$Begin, [string]$End, [string]$Body, [string]$What) {
    $dir = Split-Path -Parent $File
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    if (-not (Test-Path $File)) {
        # Written line by line, exactly as a refresh writes it, so re-running
        # never rewrites the line endings of a committed file.
        @($Begin) + @($Body -split "`r?`n") + @($End) | Set-Content $File -Encoding utf8
        Write-Host "   Created $File with $What."
        return
    }

    $lines = @(Get-Content $File)
    $b = [Array]::FindIndex($lines, [Predicate[string]] { $args[0] -eq $Begin })
    $e = [Array]::FindIndex($lines, [Predicate[string]] { $args[0] -eq $End })

    if ($b -ge 0) {
        if ($e -gt $b) {
            $head = if ($b -gt 0) { $lines[0..($b - 1)] } else { @() }
            $tail = if ($e -lt ($lines.Count - 1)) { $lines[($e + 1)..($lines.Count - 1)] } else { @() }
            $out = @($head) + @($Begin) + @($Body -split "`r?`n") + @($End) + @($tail)
            $out | Set-Content $File -Encoding utf8
            Write-Host "   Refreshed $What in $File."
        } else {
            Write-Host "!  $File has an opening marker but no closing one - left unchanged."
            Write-Host "   Repair it by hand, then re-run."
        }
        return
    }

    $append = @('') + @($Begin) + @($Body -split "`r?`n") + @($End)
    $append | Add-Content $File -Encoding utf8
    Write-Host "   Appended $What to $File (existing content kept)."
}

# A shared source file's content, without trailing whitespace.
function Get-SourceBody([string]$Path) {
    return ((Get-Content $Path -Raw) -replace '\s+$', '')
}

# Install the authorship rule into a CLAUDE.md.
#
# It lives here rather than only in the schema's apply instruction because the
# apply instruction is only in context during an /opsx:apply run - a plain
# "commit this" would never see it.
#
#   $File - ~/.claude/CLAUDE.md (-User) or <project>\CLAUDE.md (-Project -Claude)
function Install-ClaudeMd([string]$File) {
    # Single source shared with install.sh, so the two installers cannot drift.
    if (-not (Test-Path $RuleFile)) {
        throw "Authorship rule not found at $RuleFile"
    }
    Install-Block $File $BlockBegin $BlockEnd (Get-SourceBody $RuleFile) 'the authorship rule'
}

# Copy a file into the project unless one is already there. An existing file
# is never overwritten: the project may have edited it, and a policy or
# workflow it has made its own is not ours to replace.
#
#   $Src  - source file under tools\secrets\
#   $Dest - destination
#   $What - what the file is, for messages
function Install-File([string]$Src, [string]$Dest, [string]$What) {
    if (-not (Test-Path $Dest)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Dest) | Out-Null
        Copy-Item $Src $Dest
        Write-Host "   Created $Dest ($What)."
    } elseif ((Get-FileHash $Src).Hash -eq (Get-FileHash $Dest).Hash) {
        Write-Host "   $Dest is already up to date."
    } else {
        Write-Host "!  $Dest already exists and differs from this repo's copy - left unchanged."
        Write-Host "   Compare it with $Src by hand."
    }
}

# Committed files that the project's ignore rules now match, or none when the
# project is not a git work tree (or git is not installed).
function Get-TrackedIgnoredFiles([string]$Root) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return @() }
    # Windows PowerShell 5.1 turns a native command's stderr into a terminating
    # error under 'Stop', so git's "not a git repository" must not reach it.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git -C $Root rev-parse --is-inside-work-tree 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return @() }
        return @(& git -C $Root ls-files -ci --exclude-standard 2>$null | Where-Object { $_ })
    } finally {
        $ErrorActionPreference = $prev
        $global:LASTEXITCODE = 0
    }
}

# Set up secret protection in a project. The schema's rules already apply;
# these add the tooling that enforces them.
#
#   $Root  - project root
#   $Level - medium or high
function Install-Secrets([string]$Root, [string]$Level) {
    $precommit = Join-Path $Root '.pre-commit-config.yaml'
    $precommitSrc = Join-Path $SecretsDir 'pre-commit-config.yaml'

    Write-Host ""
    Write-Host "Secret protection ($Level):"

    Install-Block (Join-Path $Root '.gitignore') $SecretsBegin $SecretsEnd `
        (Get-SourceBody (Join-Path $SecretsDir 'gitignore')) 'the secret ignore rules'

    if (-not (Test-Path $precommit)) {
        Copy-Item $precommitSrc $precommit
        Write-Host "   Created $precommit (gitleaks pre-commit hook)."
    } elseif (Select-String -Path $precommit -Pattern 'gitleaks' -SimpleMatch -Quiet) {
        Write-Host "   $precommit already runs gitleaks."
    } else {
        Write-Host "!  $precommit exists without a gitleaks hook - left unchanged."
        Write-Host "   Add the 'repos:' entry from $precommitSrc by hand."
    }

    Install-File (Join-Path $SecretsDir 'secret-scan.yml') `
        (Join-Path $Root '.github\workflows\secret-scan.yml') 'GitHub Actions secret scan'

    if ($Level -eq 'high') {
        Install-File (Join-Path $SecretsDir 'secrets-policy.md') `
            (Join-Path $Root 'openspec\secrets-policy.md') "secrets policy - fill in its 'Where secrets live' table"
    }

    # The ignore rules do nothing for a file that is already committed.
    $tracked = @(Get-TrackedIgnoredFiles $Root)
    if ($tracked.Count -gt 0) {
        Write-Host "!  These committed files match the secret ignore rules and are still tracked:"
        $tracked | ForEach-Object { Write-Host "     $_" }
        Write-Host "   If one holds a real secret, rotate it first - it is in git history."
        Write-Host "   Then untrack it with: git rm --cached <file>"
    }

    Write-Host ""
    Write-Host "   Next steps:"
    Write-Host "   1. In every clone: pre-commit install"
    Write-Host "   2. Turn on GitHub secret scanning and push protection (repo admin;"
    Write-Host "      private repos need GitHub Advanced Security) under Settings >"
    Write-Host "      Code security, or:"
    Write-Host "        gh api -X PATCH repos/<owner>/<repo> ``"
    Write-Host "          -f 'security_and_analysis[secret_scanning][status]=enabled' ``"
    Write-Host "          -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled'"
    if ($Level -eq 'high') {
        Write-Host "   3. Fill in the 'Where secrets live' table in openspec/secrets-policy.md."
    }
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

# Say so when a CLAUDE.md we just wrote is ignored by that project's git setup.
#
# -Claude exists so the rule can travel with the repo. Upstream OpenSpec's
# .gitignore lists CLAUDE.md, and every project the fork touches inherits it,
# so the common case is that the file is written, reported, and then quietly
# skipped by `git add`. Keeping it local is a fine choice - this only makes it
# a visible one.
function Warn-IfGitIgnored([string]$File, [string]$Root) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }

    # Continue, not Stop, around the git calls: Windows PowerShell 5.1 turns
    # redirected native stderr into a terminating error under 'Stop', and git
    # writes to stderr whenever $Root is not a repository - which is exactly
    # the case this function exists to survive quietly.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $rule = $null
    $ignored = $false
    try {
        git -C $Root rev-parse --git-dir *>$null
        if ($LASTEXITCODE -eq 0) {
            git -C $Root check-ignore -q $File *>$null
            if ($LASTEXITCODE -eq 0) {
                $ignored = $true
                $rule = (git -C $Root check-ignore -v $File 2>$null) -split "`t" | Select-Object -First 1
            }
        }
    } finally {
        $ErrorActionPreference = $prev
        $global:LASTEXITCODE = 0
    }

    if (-not $ignored) { return }

    $by = if ($rule) { " (by $rule)" } else { "" }
    Write-Host "!  $File is git-ignored$by, so it will NOT be committed."
    Write-Host "   The rule still applies in this working copy, but a fresh clone will"
    Write-Host "   not carry it. To commit it anyway, add an exception to .gitignore:"
    Write-Host "       '!CLAUDE.md' >> `"$Root\.gitignore`""
}

if ($PSCmdlet.ParameterSetName -eq 'Project') {
    Set-ProjectSchema $projectRoot
    if ($Claude) {
        Install-ClaudeMd (Join-Path $projectRoot 'CLAUDE.md')
        Warn-IfGitIgnored (Join-Path $projectRoot 'CLAUDE.md') $projectRoot
    }
    if ($Secrets) {
        Install-Secrets $projectRoot $Secrets
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
