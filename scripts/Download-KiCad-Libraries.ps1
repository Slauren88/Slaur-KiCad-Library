[CmdletBinding()]
param(
    [string]$LibraryRoot,
    [string]$KiCadVersion
)

$ErrorActionPreference = 'Stop'

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

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git is not installed or is not available in PATH.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($LibraryRoot)) {
    $LibraryRoot = Split-Path $repoRoot -Parent
}

$runningKiCad = Get-Process -Name @('kicad', 'eeschema', 'pcbnew', 'cvpcb') -ErrorAction SilentlyContinue
if ($runningKiCad) {
    throw 'Close all KiCad windows before downloading library updates.'
}

$installation = Get-KiCadInstallation -RequestedVersion $KiCadVersion
$majorVersion = $installation.Major
Write-Host "Using KiCad $($installation.VersionText) library series."

$repositories = @(
    @{ Name = 'KiCad symbols'; Path = (Join-Path $LibraryRoot 'kicad-symbols'); Official = $true },
    @{ Name = 'KiCad footprints'; Path = (Join-Path $LibraryRoot 'kicad-footprints'); Official = $true },
    @{ Name = 'KiCad 3D models'; Path = (Join-Path $LibraryRoot 'kicad-packages3D'); Official = $true },
    @{ Name = 'Slaur library'; Path = $repoRoot; Official = $false }
)

$skipped = [System.Collections.Generic.List[string]]::new()

foreach ($repository in $repositories) {
    $path = $repository.Path
    if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) {
        Write-Warning "Skipping $($repository.Name): $path is not a Git repository."
        $skipped.Add($repository.Name)
        continue
    }

    $changes = & git -C $path status --porcelain
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect $($repository.Name) at $path."
    }
    if ($changes) {
        Write-Warning "Skipping $($repository.Name) because it has uncommitted changes. Publish or discard those changes first."
        $skipped.Add($repository.Name)
        continue
    }

    Write-Host "Downloading $($repository.Name) updates..." -ForegroundColor Cyan
    if ($repository.Official) {
        & git -C $path fetch origin --prune
        if ($LASTEXITCODE -ne 0) {
            throw "Could not fetch $($repository.Name) at $path."
        }

        $versionBranch = "v$majorVersion"
        & git -C $path show-ref --verify --quiet "refs/remotes/origin/$versionBranch"
        $targetBranch = if ($LASTEXITCODE -eq 0) { $versionBranch } else { 'master' }
        $currentBranch = (& git -C $path branch --show-current).Trim()

        if ($currentBranch -ne $targetBranch) {
            & git -C $path show-ref --verify --quiet "refs/heads/$targetBranch"
            if ($LASTEXITCODE -eq 0) {
                & git -C $path checkout $targetBranch
            }
            else {
                & git -C $path checkout --track -b $targetBranch "origin/$targetBranch"
            }
            if ($LASTEXITCODE -ne 0) {
                throw "Could not switch $($repository.Name) to branch $targetBranch."
            }
        }

        & git -C $path pull --ff-only origin $targetBranch
        if ($LASTEXITCODE -ne 0) {
            throw "Could not update $($repository.Name) from branch $targetBranch."
        }
    }
    else {
        & git -C $path pull --ff-only
        if ($LASTEXITCODE -ne 0) {
            throw "Could not update $($repository.Name) at $path."
        }
    }
}

Write-Host ''
if ($skipped.Count -gt 0) {
    Write-Warning "Download finished with skipped repositories: $($skipped -join ', ')"
    exit 2
}

Write-Host 'All library repositories are up to date.' -ForegroundColor Green
