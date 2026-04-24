[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$Tag,

    [string]$Repo = "amanthanvi/winghostty",

    [string]$ArtifactRoot,

    [string]$OutputRoot,

    [string]$UpstreamBaseVersion,

    [int]$FirstForkPatch = 0,

    [string]$WingetPackageIdentifier = "AmanThanvi.winghostty",

    [string]$ScoopPackageName = "winghostty"
)

$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$tagValue = if ($Tag) { $Tag } else { "v$Version" }
$artifactRootPath = if ($ArtifactRoot) {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $ArtifactRoot))
} else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot "dist/artifacts/winghostty-$Version-windows-x64"))
}
$outputRootPath = if ($OutputRoot) {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputRoot))
} else {
    [System.IO.Path]::GetFullPath((Join-Path $artifactRootPath "package-managers"))
}

$checksumsPath = Join-Path $artifactRootPath "SHA256SUMS.txt"
$setupName = "winghostty-$Version-windows-x64-setup.exe"
$portableName = "winghostty-$Version-windows-x64-portable.zip"
$iconName = "winghostty-icon.svg"
$setupPath = Join-Path $artifactRootPath $setupName
$portablePath = Join-Path $artifactRootPath $portableName
$iconPath = Join-Path $artifactRootPath $iconName
$releaseBaseUrl = "https://github.com/$Repo/releases/download/$tagValue"
$projectUrl = "https://github.com/$Repo"
$releaseUrl = "$projectUrl/releases/tag/$tagValue"
$iconUrl = "$releaseBaseUrl/$iconName"
$packageDescription = @"
winghostty is a Windows terminal emulator that reuses Ghostty's terminal core under a native Win32 front end.
"@.Trim()

function Reset-Directory {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Get-ChecksumMap {
    param([string]$Path)

    $checksums = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if (-not $line) {
            continue
        }

        if ($line -notmatch '^([0-9a-fA-F]{64}) \*(.+)$') {
            throw "Unsupported checksum line format in ${Path}: $line"
        }

        $checksums[$Matches[2]] = $Matches[1].ToLowerInvariant()
    }

    return $checksums
}

function Get-AssetChecksum {
    param(
        [hashtable]$ChecksumMap,
        [string]$AssetName,
        [string]$AssetPath
    )

    if (-not (Test-Path -LiteralPath $AssetPath)) {
        throw "Expected asset was not found: $AssetPath"
    }

    $checksum = $ChecksumMap[$AssetName]
    if (-not $checksum) {
        throw "Missing checksum entry for $AssetName in $checksumsPath"
    }

    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $AssetPath).Hash.ToLowerInvariant()
    if ($actual -ne $checksum) {
        throw "Checksum mismatch for $AssetName. Expected $checksum, got $actual."
    }

    return $checksum
}

function Get-VersionLine {
    param([string]$InputVersion)

    if ($InputVersion -match '^(?<major>\d+)\.(?<minor>\d+)\.\d+(?:[.-].+)?$') {
        return "$($Matches.major).$($Matches.minor)"
    }

    throw "Unable to derive a version line from '$InputVersion'."
}

$requiredPaths = @($checksumsPath, $setupPath, $portablePath, $iconPath)
foreach ($requiredPath in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Expected packaging input was not found: $requiredPath"
    }
}

$checksumMap = Get-ChecksumMap -Path $checksumsPath
$setupSha256 = Get-AssetChecksum -ChecksumMap $checksumMap -AssetName $setupName -AssetPath $setupPath
$portableSha256 = Get-AssetChecksum -ChecksumMap $checksumMap -AssetName $portableName -AssetPath $portablePath
$versionLine = Get-VersionLine -InputVersion $Version

if ($UpstreamBaseVersion) {
    $upstreamLine = Get-VersionLine -InputVersion $UpstreamBaseVersion
    if ($upstreamLine -ne $versionLine) {
        throw "Release version '$Version' is on line $versionLine but UpstreamBaseVersion '$UpstreamBaseVersion' is on line $upstreamLine."
    }
}

Reset-Directory -Path $outputRootPath

$scoopRoot = Join-Path $outputRootPath "scoop"
$metadataPath = Join-Path $outputRootPath "metadata.json"
$scoopManifestPath = Join-Path $scoopRoot "$ScoopPackageName.json"

New-Item -ItemType Directory -Path $scoopRoot -Force | Out-Null

$scoopManifest = [ordered]@{
    version      = $Version
    description  = $packageDescription
    homepage     = $projectUrl
    license      = "MIT"
    architecture = [ordered]@{
        "64bit" = [ordered]@{
            url  = "$releaseBaseUrl/$portableName"
            hash = $portableSha256
        }
    }
    extract_dir  = "winghostty"
    bin          = "winghostty.exe"
}
Set-Content -LiteralPath $scoopManifestPath -Value ($scoopManifest | ConvertTo-Json -Depth 5)

$metadata = [ordered]@{
    version     = $Version
    tag         = $tagValue
    repository  = $Repo
    versioning  = [ordered]@{
        scheme = "major.minor follow the Ghostty upstream line; patch is the winghostty release number on that line"
        line   = $versionLine
    }
    release     = [ordered]@{
        baseUrl    = $releaseBaseUrl
        projectUrl = $projectUrl
        releaseUrl = $releaseUrl
        iconUrl    = $iconUrl
    }
    assets      = [ordered]@{
        installer = [ordered]@{
            name   = $setupName
            path   = $setupPath
            url    = "$releaseBaseUrl/$setupName"
            sha256 = $setupSha256
        }
        portable  = [ordered]@{
            name   = $portableName
            path   = $portablePath
            url    = "$releaseBaseUrl/$portableName"
            sha256 = $portableSha256
        }
    }
    winget      = [ordered]@{
        packageIdentifier = $WingetPackageIdentifier
        version           = $Version
        installerUrl      = "$releaseBaseUrl/$setupName"
    }
    scoop      = [ordered]@{
        packageName   = $ScoopPackageName
        manifestPath  = $scoopManifestPath
        manifestRelPath = "$ScoopPackageName.json"
    }
}

if ($UpstreamBaseVersion) {
    $metadata.upstream = [ordered]@{
        baseVersion = $UpstreamBaseVersion
    }
}

if ($FirstForkPatch -gt 0) {
    $metadata.versioning.firstForkPatch = $FirstForkPatch
}

Set-Content -LiteralPath $metadataPath -Value ($metadata | ConvertTo-Json -Depth 8)

Write-Host "Scoop manifest         : $scoopManifestPath"
Write-Host "Metadata               : $metadataPath"
