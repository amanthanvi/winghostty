param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [switch] $OpenShell,
    [switch] $NoBuild
)

$ErrorActionPreference = 'Stop'

if ($Rebuild -and $NoBuild) {
    throw 'Cannot use -Rebuild with -NoBuild together.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$launcherPath = Join-Path $PSScriptRoot 'interactive-win11.ps1'

if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_BOOTSTRAPPED) {
    $forwardedArgs = @()
    if ($Rebuild) { $forwardedArgs += '-Rebuild' }
    if ($ResetState) { $forwardedArgs += '-ResetState' }
    if ($OpenShell) { $forwardedArgs += '-OpenShell' }
    if ($NoBuild) { $forwardedArgs += '-NoBuild' }

    $bootstrapCmd = Join-Path $PSScriptRoot 'dev-windows.cmd'
    $quotedLauncherPath = '"{0}"' -f $launcherPath
    $exitCode = 0
    $env:WINGHOSTTY_INTERACTIVE_WIN11_BOOTSTRAPPED = '1'

    Push-Location $repoRoot
    try {
        & $bootstrapCmd powershell.exe -ExecutionPolicy Bypass -File $quotedLauncherPath @forwardedArgs
        if ($null -ne $LASTEXITCODE) {
            $exitCode = $LASTEXITCODE
        }
    }
    finally {
        Pop-Location
        Remove-Item Env:WINGHOSTTY_INTERACTIVE_WIN11_BOOTSTRAPPED -ErrorAction SilentlyContinue
    }

    exit $exitCode
}

$libPath = Join-Path $PSScriptRoot 'interactive-win11-lib.ps1'
. $libPath

$repoRoot = Get-InteractiveWin11NormalizedPath -Path $repoRoot
$layout = Get-InteractiveWin11SandboxLayout -RepoRoot $repoRoot

if ($ResetState) {
    Reset-InteractiveWin11Sandbox -Layout $layout
}

New-InteractiveWin11Sandbox -Layout $layout

$sandboxEnv = Get-InteractiveWin11Environment -Layout $layout
foreach ($entry in $sandboxEnv.GetEnumerator()) {
    [System.Environment]::SetEnvironmentVariable([string] $entry.Key, [string] $entry.Value, 'Process')
}

if ($OpenShell) {
    Write-Host "RepoRoot: $($layout.RepoRoot)"
    Write-Host "WorktreeId: $($layout.WorktreeId)"
    Write-Host "SandboxRoot: $($layout.SandboxRoot)"
    foreach ($entry in $sandboxEnv.GetEnumerator()) {
        Write-Host "$($entry.Key)=$($entry.Value)"
    }

    Push-Location $repoRoot
    try {
        & cmd.exe /k
    }
    finally {
        Pop-Location
    }

    exit 0
}

$exePath = Get-InteractiveWin11NormalizedPath -Path (Join-Path $repoRoot 'zig-out\bin\winghostty.exe')
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -NoBuild:$NoBuild
$launchArgs = Get-InteractiveWin11LaunchArguments -Layout $layout

if ($launchAction -eq 'build') {
    Push-Location $repoRoot
    try {
        & zig build -Demit-exe=true
        if ($LASTEXITCODE -ne 0) {
            throw "zig build -Demit-exe=true failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}

if (-not [System.IO.File]::Exists($exePath)) {
    throw "Missing winghostty.exe at $exePath"
}

Start-Process -FilePath $exePath -ArgumentList $launchArgs -WorkingDirectory $repoRoot | Out-Null
