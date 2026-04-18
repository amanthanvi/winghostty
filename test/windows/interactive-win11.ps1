$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param(
        [Parameter(Mandatory)] $Actual,
        [Parameter(Mandatory)] $Expected,
        [Parameter(Mandatory)] [string] $Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory)] [bool] $Condition,
        [Parameter(Mandatory)] [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Match {
    param(
        [Parameter(Mandatory)] [string] $Value,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $Message
    )

    if ($Value -notmatch $Pattern) {
        throw "$Message`nPattern: $Pattern`nValue:   $Value"
    }
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$libPath = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
. $libPath

$samePathA = 'C:\Users\amant\.codex\worktrees\162b\winghostty'
$samePathB = 'C:/Users/amant/.codex/worktrees/162b/winghostty\'
$otherPath = 'C:\Users\amant\.codex\worktrees\main\winghostty'

$idA = Get-InteractiveWin11WorktreeId -RepoRoot $samePathA
$idB = Get-InteractiveWin11WorktreeId -RepoRoot $samePathB
$idC = Get-InteractiveWin11WorktreeId -RepoRoot $otherPath

Assert-Equal $idA $idB 'worktree id should normalize slash direction and trailing slash'
Assert-Match $idA '^162b-winghostty-[0-9a-f]{12}$' 'worktree id should include short slug and hash suffix'
Assert-True ($idA -ne $idC) 'different worktree paths should produce different ids'

$layout = Get-InteractiveWin11SandboxLayout -RepoRoot $samePathA

Assert-Equal $layout.RepoRoot 'C:\Users\amant\.codex\worktrees\162b\winghostty' 'layout should preserve normalized repo root'
Assert-True ($layout.SandboxRoot.StartsWith('C:\Users\amant\.codex\worktrees\162b\winghostty\.sandbox\win11\', [System.StringComparison]::OrdinalIgnoreCase)) 'sandbox root should live under repo-local .sandbox\win11'
Assert-Equal $layout.XdgConfigHome $layout.LocalAppData 'config home should reuse localappdata'
Assert-Equal $layout.Temp (Join-Path $layout.SandboxRoot 'temp') 'temp path should be rooted in sandbox'

$scratchRepo = Join-Path $env:TEMP 'winghostty-interactive-win11-test'
$scratchLayout = Get-InteractiveWin11SandboxLayout -RepoRoot $scratchRepo
New-Item -ItemType Directory -Force -Path $scratchLayout.Temp | Out-Null
Set-Content -Path (Join-Path $scratchLayout.Temp 'marker.txt') -Value 'ok'

Reset-InteractiveWin11Sandbox -Layout $scratchLayout
Assert-True (-not (Test-Path $scratchLayout.SandboxRoot)) 'reset should remove only the current worktree sandbox'

$escapeRoot = Join-Path $scratchRepo '.sandbox\win11-escape'
New-Item -ItemType Directory -Force -Path $escapeRoot | Out-Null
Set-Content -Path (Join-Path $escapeRoot 'marker.txt') -Value 'keep'

$escapeLayout = [ordered]@{
    RepoRoot    = $scratchRepo
    SandboxRoot = $escapeRoot
}

$resetBlocked = $false
try {
    Reset-InteractiveWin11Sandbox -Layout $escapeLayout
}
catch {
    $resetBlocked = $true
    Assert-True ($_.Exception.Message -like '*Refusing to reset sandbox outside*') 'out-of-sandbox reset should mention refusal'
}

Assert-True $resetBlocked 'prefix-collision sandbox target should be refused'
Assert-True (Test-Path $escapeRoot) 'refused sandbox target should not be deleted'

$launchScratch = Join-Path $env:TEMP 'winghostty-interactive-win11-launch-test'
Remove-Item -LiteralPath $launchScratch -Recurse -Force -ErrorAction SilentlyContinue

$missingExe = Join-Path $launchScratch 'zig-out\bin\winghostty.exe'
$existingExe = Join-Path $launchScratch 'ready\zig-out\bin\winghostty.exe'
$directoryExe = Join-Path $launchScratch 'dir\zig-out\bin\winghostty.exe'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $existingExe) | Out-Null
Set-Content -Path $existingExe -Value 'stub'
New-Item -ItemType Directory -Force -Path $directoryExe | Out-Null

Assert-Equal (
    Get-InteractiveWin11LaunchAction -ExePath $missingExe
) 'build' 'missing binary without flags should build'

Assert-Equal (
    Get-InteractiveWin11LaunchAction -ExePath $existingExe -Rebuild
) 'build' 'rebuild flag should force build even when binary exists'

Assert-Equal (
    Get-InteractiveWin11LaunchAction -ExePath $existingExe
) 'launch' 'existing binary without rebuild should launch'

Assert-Equal (
    Get-InteractiveWin11LaunchAction -ExePath $directoryExe
) 'build' 'directory at exe path should not count as launchable'

$missingBinaryBlocked = $false
try {
    Get-InteractiveWin11LaunchAction -ExePath $missingExe -NoBuild | Out-Null
}
catch {
    $missingBinaryBlocked = $true
    Assert-True ($_.Exception.Message -like '*winghostty.exe*') 'missing binary with no-build should mention winghostty.exe'
}

Assert-True $missingBinaryBlocked 'missing binary with no-build should throw'

$conflictingFlagsBlocked = $false
try {
    Get-InteractiveWin11LaunchAction -ExePath $existingExe -Rebuild -NoBuild | Out-Null
}
catch {
    $conflictingFlagsBlocked = $true
    Assert-True ($_.Exception.Message -like '*-Rebuild*') 'conflicting flags should mention -Rebuild'
    Assert-True ($_.Exception.Message -like '*-NoBuild*') 'conflicting flags should mention -NoBuild'
}

Assert-True $conflictingFlagsBlocked 'rebuild and no-build together should throw'

Write-Host 'interactive-win11 helper tests: PASS'
