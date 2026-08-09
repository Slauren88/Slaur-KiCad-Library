[CmdletBinding()]
param(
    [string]$LibraryRoot = 'C:\KiCad-Libraries',
    [string]$KiCadVersion,
    [switch]$SkipRepositoryUpdate
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

function Invoke-GitRepository {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [int]$MajorVersion
    )

    if (Test-Path -LiteralPath (Join-Path $Path '.git')) {
        if ($SkipRepositoryUpdate) {
            return
        }
    }
    else {
        if (Test-Path -LiteralPath $Path) {
            throw "$Path exists but is not a Git repository. Move it aside or choose another LibraryRoot."
        }

        Write-Host "Cloning $Name..."
        & git clone $Url $Path
        if ($LASTEXITCODE -ne 0) {
            throw "Could not clone $Name from $Url."
        }
    }

    $changes = & git -C $Path status --porcelain
    if ($LASTEXITCODE -ne 0 -or $changes) {
        throw "$Name has uncommitted changes at $Path; it cannot be switched to the KiCad $MajorVersion library branch."
    }

    Write-Host "Updating $Name for KiCad $MajorVersion..."
    & git -C $Path fetch origin --prune
    if ($LASTEXITCODE -ne 0) {
        throw "Could not fetch $Name at $Path."
    }

    $versionBranch = "v$MajorVersion"
    & git -C $Path show-ref --verify --quiet "refs/remotes/origin/$versionBranch"
    $targetBranch = if ($LASTEXITCODE -eq 0) { $versionBranch } else { 'master' }
    $currentBranch = (& git -C $Path branch --show-current).Trim()

    if ($currentBranch -ne $targetBranch) {
        & git -C $Path show-ref --verify --quiet "refs/heads/$targetBranch"
        if ($LASTEXITCODE -eq 0) {
            & git -C $Path checkout $targetBranch
        }
        else {
            & git -C $Path checkout --track -b $targetBranch "origin/$targetBranch"
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Could not switch $Name to branch $targetBranch."
        }
    }

    & git -C $Path pull --ff-only origin $targetBranch
    if ($LASTEXITCODE -ne 0) {
        throw "Could not update $Name from branch $targetBranch."
    }
}

function Backup-File {
    param([Parameter(Mandatory)] [string]$Path)

    if (Test-Path -LiteralPath $Path) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item -LiteralPath $Path -Destination "$Path.$stamp.bak"
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Set-KiCadPathVariables {
    param(
        [Parameter(Mandatory)] [string]$ConfigPath,
        [Parameter(Mandatory)] [hashtable]$Variables
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "KiCad configuration was not found at $ConfigPath. Start KiCad $KiCadVersion once, close it, and rerun this script."
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if ($null -eq $config.environment) {
        $config | Add-Member -MemberType NoteProperty -Name environment -Value ([pscustomobject]@{})
    }
    if ($null -eq $config.environment.vars) {
        $config.environment | Add-Member -MemberType NoteProperty -Name vars -Value ([pscustomobject]@{})
    }

    foreach ($item in $Variables.GetEnumerator()) {
        $config.environment.vars | Add-Member -MemberType NoteProperty -Name $item.Key -Value $item.Value -Force
    }

    Backup-File -Path $ConfigPath
    $json = $config | ConvertTo-Json -Depth 100
    Write-Utf8NoBom -Path $ConfigPath -Content ($json + [Environment]::NewLine)
}

function Set-NestedLibraryTable {
    param(
        [Parameter(Mandatory)] [string]$TablePath,
        [Parameter(Mandatory)] [ValidateSet('sym', 'fp')] [string]$Kind,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$NestedTablePath,
        [Parameter(Mandatory)] [string]$Description
    )

    if (-not (Test-Path -LiteralPath $TablePath)) {
        $header = if ($Kind -eq 'sym') { 'sym_lib_table' } else { 'fp_lib_table' }
        Write-Utf8NoBom -Path $TablePath -Content "($header`n`t(version 7)`n)`n"
    }

    $content = Get-Content -LiteralPath $TablePath -Raw
    $uri = $NestedTablePath.Replace('\', '/')
    $entry = "`t(lib (name `"$Name`") (type `"Table`") (uri `"$uri`") (options `"`") (descr `"$Description`"))"
    $escapedName = [regex]::Escape($Name)
    $pattern = '(?m)^[\t ]*\(lib \(name "' + $escapedName + '"\).*$'

    if ([regex]::IsMatch($content, $pattern)) {
        $updated = [regex]::Replace($content, $pattern, $entry, 1)
    }
    else {
        $closing = $content.LastIndexOf(')')
        if ($closing -lt 0) {
            throw "Invalid library table: $TablePath"
        }
        $updated = $content.Insert($closing, $entry + [Environment]::NewLine)
    }

    if ($updated -ne $content) {
        Backup-File -Path $TablePath
        Write-Utf8NoBom -Path $TablePath -Content $updated
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git is not installed or is not available in PATH.'
}

$runningKiCad = Get-Process -Name @('kicad', 'eeschema', 'pcbnew', 'cvpcb', 'fpeditor') -ErrorAction SilentlyContinue
if ($runningKiCad) {
    throw 'Close all KiCad windows before running this installer so its configuration files can be updated safely.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'sym-lib-table'))) {
    throw "The Slaur library repository could not be identified at $repoRoot."
}

New-Item -ItemType Directory -Force -Path $LibraryRoot | Out-Null

$installation = Get-KiCadInstallation -RequestedVersion $KiCadVersion
$KiCadVersion = $installation.VersionText
$majorVersion = $installation.Major
Write-Host "Using KiCad $KiCadVersion at $($installation.Cli)"

$repositories = @(
    @{ Name = 'KiCad symbols'; Url = 'https://gitlab.com/kicad/libraries/kicad-symbols.git'; Path = (Join-Path $LibraryRoot 'kicad-symbols'); MajorVersion = $majorVersion },
    @{ Name = 'KiCad footprints'; Url = 'https://gitlab.com/kicad/libraries/kicad-footprints.git'; Path = (Join-Path $LibraryRoot 'kicad-footprints'); MajorVersion = $majorVersion },
    @{ Name = 'KiCad 3D models'; Url = 'https://gitlab.com/kicad/libraries/kicad-packages3D.git'; Path = (Join-Path $LibraryRoot 'kicad-packages3D'); MajorVersion = $majorVersion }
)

foreach ($repository in $repositories) {
    Invoke-GitRepository @repository
}

$configDir = Join-Path $env:APPDATA "kicad\$KiCadVersion"
$commonConfig = Join-Path $configDir 'kicad_common.json'
$symbolTable = Join-Path $configDir 'sym-lib-table'
$footprintTable = Join-Path $configDir 'fp-lib-table'

$officialSymbolDir = Join-Path $LibraryRoot 'kicad-symbols'
$officialFootprintDir = Join-Path $LibraryRoot 'kicad-footprints'
$official3dModelDir = Join-Path $LibraryRoot 'kicad-packages3D'
$variablePrefix = "KICAD$majorVersion"
$pathVariables = @{
    SLAURLIB_DIR = $repoRoot
    KICAD_OFFICIAL_3DMODEL_DIR = $official3dModelDir
}
$pathVariables["${variablePrefix}_SYMBOL_DIR"] = $officialSymbolDir
$pathVariables["${variablePrefix}_FOOTPRINT_DIR"] = $officialFootprintDir
$pathVariables["${variablePrefix}_3DMODEL_DIR"] = $official3dModelDir
Set-KiCadPathVariables -ConfigPath $commonConfig -Variables $pathVariables

Set-NestedLibraryTable -TablePath $symbolTable -Kind sym -Name 'KiCad' `
    -NestedTablePath (Join-Path $officialSymbolDir 'sym-lib-table') `
    -Description 'KiCad Git libraries'
Set-NestedLibraryTable -TablePath $symbolTable -Kind sym -Name 'SlaurLib' `
    -NestedTablePath (Join-Path $repoRoot 'sym-lib-table') `
    -Description 'Slaur custom symbol libraries'

Set-NestedLibraryTable -TablePath $footprintTable -Kind fp -Name 'KiCad' `
    -NestedTablePath (Join-Path $officialFootprintDir 'fp-lib-table') `
    -Description 'KiCad Git libraries'
Set-NestedLibraryTable -TablePath $footprintTable -Kind fp -Name 'SlaurLib' `
    -NestedTablePath (Join-Path $repoRoot 'fp-lib-table') `
    -Description 'Slaur custom footprint libraries'

Write-Host ''
Write-Host 'KiCad libraries configured successfully.' -ForegroundColor Green
Write-Host "SLAURLIB_DIR = $repoRoot"
Write-Host "Backups of changed KiCad configuration files use a timestamped .bak suffix."
Write-Host "Start KiCad $KiCadVersion and verify the libraries under Preferences > Manage Symbol/Footprint Libraries."
