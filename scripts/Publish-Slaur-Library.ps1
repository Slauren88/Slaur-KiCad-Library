[CmdletBinding()]
param(
    [string]$Message,
    [string]$KiCadVersion,
    [switch]$NoPush,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param(
        [Parameter(Mandatory)] [string[]]$Arguments,
        [switch]$AllowFailure
    )

    & git -C $script:RepoRoot @Arguments
    if (-not $AllowFailure -and $LASTEXITCODE -ne 0) {
        throw "Git command failed: git $($Arguments -join ' ')"
    }
    return $LASTEXITCODE
}

function Get-KiCadInstallation {
    param([string]$RequestedVersion)

    $installRoot = Join-Path $env:ProgramFiles 'KiCad'
    $candidates = @(
        Get-ChildItem -LiteralPath $installRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $parsedVersion = $null
            $cli = Join-Path $_.FullName 'bin\kicad-cli.exe'
            if ([version]::TryParse($_.Name, [ref]$parsedVersion) -and (Test-Path -LiteralPath $cli)) {
                [pscustomobject]@{
                    Version = $parsedVersion
                    VersionText = $_.Name
                    Major = $parsedVersion.Major
                    Cli = $cli
                }
            }
        }
    )

    if ($RequestedVersion) {
        $selected = $candidates | Where-Object { $_.VersionText -eq $RequestedVersion } | Select-Object -First 1
        if (-not $selected) {
            throw "KiCad $RequestedVersion was not found under $installRoot."
        }
        return $selected
    }

    $selected = $candidates | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $selected) {
        throw "No KiCad installation with kicad-cli.exe was found under $installRoot."
    }
    return $selected
}

function Test-KiCadLibraries {
    param(
        [Parameter(Mandatory)] [string]$Cli,
        [Parameter(Mandatory)] [string]$Version
    )

    $symbolLibrary = Join-Path $script:RepoRoot 'symbols\SlaurLib.kicad_sym'
    $footprintLibrary = Join-Path $script:RepoRoot 'footprints\SlaurLib.pretty'
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("slaurlib-validation-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

    try {
        Write-Host "Validating symbols with KiCad $Version..." -ForegroundColor Cyan
        & $Cli sym upgrade --force $symbolLibrary -o (Join-Path $temporaryRoot 'SlaurLib.kicad_sym')
        if ($LASTEXITCODE -ne 0) {
            throw 'KiCad rejected the symbol library.'
        }

        Write-Host "Validating footprints with KiCad $Version..." -ForegroundColor Cyan
        & $Cli fp upgrade --force $footprintLibrary -o (Join-Path $temporaryRoot 'SlaurLib.pretty')
        if ($LASTEXITCODE -ne 0) {
            throw 'KiCad rejected the footprint library.'
        }

        $libraryRoot = Split-Path $script:RepoRoot -Parent
        $official3dRoot = Join-Path $libraryRoot 'kicad-packages3D'
        $unresolvedModels = [System.Collections.Generic.List[string]]::new()
        $modelMatches = Select-String -Path (Join-Path $footprintLibrary '*.kicad_mod') -Pattern '\(model "([^"]+)"'

        foreach ($match in $modelMatches) {
            $model = $match.Matches[0].Groups[1].Value
            if ($model.StartsWith('${SLAURLIB_DIR}/')) {
                $resolved = $model.Replace('${SLAURLIB_DIR}', $script:RepoRoot).Replace('/', '\')
            }
            elseif ($model.StartsWith('${KICAD_OFFICIAL_3DMODEL_DIR}/')) {
                $resolved = $model.Replace('${KICAD_OFFICIAL_3DMODEL_DIR}', $official3dRoot).Replace('/', '\')
            }
            else {
                $unresolvedModels.Add("$(Split-Path $match.Path -Leaf): unsupported model path $model")
                continue
            }

            if (-not (Test-Path -LiteralPath $resolved)) {
                $unresolvedModels.Add("$(Split-Path $match.Path -Leaf): missing $resolved")
            }
        }

        if ($unresolvedModels.Count -gt 0) {
            throw "3D-model validation failed:`n$($unresolvedModels -join [Environment]::NewLine)"
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
        }
    }

    Write-Host 'KiCad files and 3D-model references are valid.' -ForegroundColor Green
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git is not installed or is not available in PATH.'
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))) {
    throw "$RepoRoot is not a Git repository."
}

$runningEditors = Get-Process -Name @('eeschema', 'pcbnew', 'cvpcb') -ErrorAction SilentlyContinue
if ($runningEditors) {
    throw 'Close the KiCad schematic, symbol, footprint, and PCB editors before publishing so all changes are saved.'
}

$installation = Get-KiCadInstallation -RequestedVersion $KiCadVersion
Write-Host "Using KiCad $($installation.VersionText) at $($installation.Cli)"
Test-KiCadLibraries -Cli $installation.Cli -Version $installation.VersionText

if ($ValidateOnly) {
    Write-Host 'Validation-only run complete; Git was not changed.' -ForegroundColor Green
    exit 0
}

$authorName = & git -C $RepoRoot config --get user.name
$authorEmail = & git -C $RepoRoot config --get user.email
if ([string]::IsNullOrWhiteSpace($authorName) -or [string]::IsNullOrWhiteSpace($authorEmail)) {
    throw @'
Git author details are not configured. Run these once, then retry:

  git config --global user.name "Your Name"
  git config --global user.email "YOUR_GITHUB_EMAIL_OR_NOREPLY"
'@
}

$branch = (& git -C $RepoRoot branch --show-current).Trim()
if ([string]::IsNullOrWhiteSpace($branch)) {
    throw 'The repository is in detached-HEAD state. Switch to a branch before publishing.'
}

Write-Host "Checking GitHub for newer changes on $branch..." -ForegroundColor Cyan
Invoke-Git -Arguments @('fetch', 'origin', $branch) | Out-Null

$remoteRef = "refs/remotes/origin/$branch"
& git -C $RepoRoot show-ref --verify --quiet $remoteRef
$remoteExists = $LASTEXITCODE -eq 0

if ($remoteExists) {
    $behind = [int](& git -C $RepoRoot rev-list --count "HEAD..origin/$branch")
    if ($behind -gt 0) {
        throw "GitHub has $behind newer commit(s). Run Download-Library-Updates.cmd before publishing."
    }
}

Invoke-Git -Arguments @('add', '-A', '--', '.') | Out-Null
$stagedFiles = & git -C $RepoRoot diff --cached --name-status
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the staged changes.'
}

if ($stagedFiles) {
    Write-Host ''
    Write-Host 'Changes to publish:' -ForegroundColor Cyan
    $stagedFiles | ForEach-Object { Write-Host "  $_" }

    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = Read-Host 'Enter a short commit message'
    }
    if ([string]::IsNullOrWhiteSpace($Message)) {
        throw 'A commit message is required.'
    }

    Invoke-Git -Arguments @('commit', '-m', $Message) | Out-Null
}
else {
    Write-Host 'There are no new working-tree changes to commit.'
}

if ($remoteExists) {
    $ahead = [int](& git -C $RepoRoot rev-list --count "origin/$branch..HEAD")
}
else {
    $ahead = 1
}

if ($ahead -eq 0) {
    Write-Host 'Your GitHub repository is already up to date.' -ForegroundColor Green
    exit 0
}

if ($NoPush) {
    Write-Host "Created the local commit. $ahead commit(s) still need to be pushed." -ForegroundColor Yellow
    exit 0
}

Write-Host "Uploading $ahead commit(s) to GitHub..." -ForegroundColor Cyan
if ($remoteExists) {
    Invoke-Git -Arguments @('push', 'origin', $branch) | Out-Null
}
else {
    Invoke-Git -Arguments @('push', '--set-upstream', 'origin', $branch) | Out-Null
}

Write-Host 'Your Slaur library is published to GitHub.' -ForegroundColor Green
