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

    [string]$ChocolateyPackageId = "winghostty",

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
$licenseUrl = "$projectUrl/blob/$tagValue/LICENSE"
$docsUrl = "$projectUrl/blob/$tagValue/docs/getting-started.md"
$bugTrackerUrl = "$projectUrl/issues"
$iconUrl = "$releaseBaseUrl/$iconName"
$packageTitle = "winghostty terminal"
$packageSummary = "Native Win32 terminal emulator built on Ghostty's terminal core."
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

function ConvertTo-ChocolateyVersion {
    param([string]$InputVersion)

    if ($InputVersion -match '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$') {
        return "$($Matches.major).$($Matches.minor).$($Matches.patch)"
    }

    if ($InputVersion -match '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)\.(?<build>\d+)$') {
        return "$($Matches.major).$($Matches.minor).$($Matches.patch).$($Matches.build)"
    }

    if ($InputVersion -match '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)-winghostty(?<build>\d+)$') {
        return "$($Matches.major).$($Matches.minor).$($Matches.patch).$($Matches.build)"
    }

    if ($InputVersion -match '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)-winghostty\.(?<build>\d+)$') {
        return "$($Matches.major).$($Matches.minor).$($Matches.patch).$($Matches.build)"
    }

    throw "Unsupported Chocolatey version format '$InputVersion'. Prefer plain <major>.<minor>.<patch> release tags. Legacy winghostty suffix forms are still accepted for transition."
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
$chocolateyVersion = ConvertTo-ChocolateyVersion -InputVersion $Version
$versionLine = Get-VersionLine -InputVersion $Version

if ($UpstreamBaseVersion) {
    $upstreamLine = Get-VersionLine -InputVersion $UpstreamBaseVersion
    if ($upstreamLine -ne $versionLine) {
        throw "Release version '$Version' is on line $versionLine but UpstreamBaseVersion '$UpstreamBaseVersion' is on line $upstreamLine."
    }
}

Reset-Directory -Path $outputRootPath

$chocolateyRoot = Join-Path $outputRootPath "chocolatey"
$chocolateyTools = Join-Path $chocolateyRoot "tools"
$scoopRoot = Join-Path $outputRootPath "scoop"
$metadataPath = Join-Path $outputRootPath "metadata.json"
$nuspecPath = Join-Path $chocolateyRoot "$ChocolateyPackageId.nuspec"
$installScriptPath = Join-Path $chocolateyTools "chocolateyInstall.ps1"
$uninstallScriptPath = Join-Path $chocolateyTools "chocolateyUninstall.ps1"
$verificationPath = Join-Path $chocolateyTools "VERIFICATION.txt"
$scoopManifestPath = Join-Path $scoopRoot "$ScoopPackageName.json"

New-Item -ItemType Directory -Path $chocolateyTools -Force | Out-Null
New-Item -ItemType Directory -Path $scoopRoot -Force | Out-Null

$nuspec = @"
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd">
  <metadata>
    <id>$ChocolateyPackageId</id>
    <version>$chocolateyVersion</version>
    <title>$packageTitle</title>
    <authors>Aman Thanvi</authors>
    <owners>Aman Thanvi</owners>
    <licenseUrl>$licenseUrl</licenseUrl>
    <projectUrl>$projectUrl</projectUrl>
    <packageSourceUrl>$projectUrl</packageSourceUrl>
    <docsUrl>$docsUrl</docsUrl>
    <bugTrackerUrl>$bugTrackerUrl</bugTrackerUrl>
    <releaseNotes>$releaseUrl</releaseNotes>
    <iconUrl>$iconUrl</iconUrl>
    <requireLicenseAcceptance>false</requireLicenseAcceptance>
    <summary>$packageSummary</summary>
    <description>$packageDescription</description>
    <tags>terminal console ghostty win32 windows shell</tags>
  </metadata>
</package>
"@
Set-Content -LiteralPath $nuspecPath -Value $nuspec

$installScript = @'
$packageArgs = @{
    packageName    = '__PACKAGE_ID__'
    fileType       = 'exe'
    silentArgs     = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'
    url64bit       = '__INSTALLER_URL__'
    checksum64     = '__INSTALLER_SHA256__'
    checksumType64 = 'sha256'
    validExitCodes = @(0)
}

Install-ChocolateyPackage @packageArgs
'@
$installScript = $installScript.Replace("__PACKAGE_ID__", $ChocolateyPackageId)
$installScript = $installScript.Replace("__INSTALLER_URL__", "$releaseBaseUrl/$setupName")
$installScript = $installScript.Replace("__INSTALLER_SHA256__", $setupSha256)
Set-Content -LiteralPath $installScriptPath -Value $installScript

$uninstallScript = @'
$packageName = '__PACKAGE_ID__'
$softwareName = 'winghostty'
$validExitCodes = @(0)
[array]$keys = Get-UninstallRegistryKey -SoftwareName $softwareName

if ($keys.Count -eq 0) {
    Write-Warning "$packageName has already been uninstalled by another process."
    return
}

if ($keys.Count -gt 1) {
    throw "Expected one uninstall entry for $softwareName, found $([int]$keys.Count)."
}

$uninstallString = if ($keys[0].QuietUninstallString) {
    $keys[0].QuietUninstallString
} else {
    "$([string]$keys[0].UninstallString) /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-"
}

if ($uninstallString -match '^\s*"([^"]+)"\s*(.*)$') {
    $file = $Matches[1]
    $silentArgs = $Matches[2]
} elseif ($uninstallString -match '^\s*([^\s]+)\s*(.*)$') {
    $file = $Matches[1]
    $silentArgs = $Matches[2]
} else {
    throw "Unable to parse uninstall command: $uninstallString"
}

Uninstall-ChocolateyPackage -PackageName $packageName `
    -FileType 'exe' `
    -SilentArgs $silentArgs.Trim() `
    -File $file `
    -ValidExitCodes $validExitCodes
'@
$uninstallScript = $uninstallScript.Replace("__PACKAGE_ID__", $ChocolateyPackageId)
Set-Content -LiteralPath $uninstallScriptPath -Value $uninstallScript

$verification = @"
VERIFICATION
Verification is intended to assist package moderators and reviewers.

Installer
1. Download $releaseBaseUrl/$setupName
2. Run Get-FileHash -Algorithm SHA256 $setupName
3. Confirm the hash equals $setupSha256

Portable ZIP
1. Download $releaseBaseUrl/$portableName
2. Run Get-FileHash -Algorithm SHA256 $portableName
3. Confirm the hash equals $portableSha256

Project source
$projectUrl
"@
Set-Content -LiteralPath $verificationPath -Value $verification

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
    chocolatey = [ordered]@{
        packageId   = $ChocolateyPackageId
        version     = $chocolateyVersion
        packageDir  = $chocolateyRoot
        nuspecPath  = $nuspecPath
        installerUrl = "$releaseBaseUrl/$setupName"
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

Write-Host "Chocolatey package root: $chocolateyRoot"
Write-Host "Scoop manifest         : $scoopManifestPath"
Write-Host "Metadata               : $metadataPath"
