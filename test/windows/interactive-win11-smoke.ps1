param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [int] $TimeoutSeconds = 10
)

$ErrorActionPreference = 'Stop'

if ($TimeoutSeconds -le 0) {
    throw 'TimeoutSeconds must be greater than 0.'
}

$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_SMOKE_BOOTSTRAPPED) {
    $forwardedArgs = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
    if ($Rebuild) { $forwardedArgs += '-Rebuild' }
    if ($ResetState) { $forwardedArgs += '-ResetState' }

    $bootstrapCmd = Join-Path $repoRoot 'scripts\dev-windows.cmd'
    $exitCode = 0
    $env:WINGHOSTTY_INTERACTIVE_WIN11_SMOKE_BOOTSTRAPPED = '1'

    Push-Location $repoRoot
    try {
        & $bootstrapCmd powershell.exe -ExecutionPolicy Bypass -File $launcherPath @forwardedArgs
        if ($null -ne $LASTEXITCODE) {
            $exitCode = $LASTEXITCODE
        }
    }
    finally {
        Pop-Location
        Remove-Item Env:WINGHOSTTY_INTERACTIVE_WIN11_SMOKE_BOOTSTRAPPED -ErrorAction SilentlyContinue
    }

    exit $exitCode
}

$libPath = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
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

$exePath = Get-InteractiveWin11NormalizedPath -Path (Join-Path $repoRoot 'zig-out\bin\winghostty.exe')
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild
$launchArgs = @(Get-InteractiveWin11LaunchArguments -Layout $layout)
$stdoutPath = Join-Path $layout.Logs 'interactive-win11-smoke-stdout.log'
$stderrPath = Join-Path $layout.Logs 'interactive-win11-smoke-stderr.log'

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

Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue

$process = Start-Process `
    -FilePath $exePath `
    -ArgumentList $launchArgs `
    -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru

$successPattern = 'started subcommand path='
$failurePattern = 'error starting IO thread:'
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$smokePassed = $false
$failureReason = $null

try {
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 250

        $stderr = if (Test-Path -LiteralPath $stderrPath) {
            Get-Content -LiteralPath $stderrPath -Raw
        } else {
            ''
        }

        if ($stderr.Contains($successPattern)) {
            $smokePassed = $true
            break
        }

        if ($stderr.Contains($failurePattern)) {
            $failureReason = 'terminal startup failure detected in stderr log'
            break
        }

        if ($process.HasExited) {
            $failureReason = "winghostty exited before shell startup was observed (exit code $($process.ExitCode))"
            break
        }
    }
}
finally {
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
    }
}

if (-not $smokePassed) {
    if (-not $failureReason) {
        $failureReason = "timed out after $TimeoutSeconds seconds waiting for initial shell startup"
    }

    $stderrTail = if (Test-Path -LiteralPath $stderrPath) {
        (Get-Content -LiteralPath $stderrPath | Select-Object -Last 40) -join [Environment]::NewLine
    } else {
        '<stderr log missing>'
    }

    throw @"
interactive Win11 smoke test failed: $failureReason
stderr log: $stderrPath
stdout log: $stdoutPath

Recent stderr:
$stderrTail
"@
}

Write-Host "interactive-win11 smoke test: PASS ($stderrPath)"
