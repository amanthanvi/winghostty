param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [int] $TimeoutSeconds = 12
)

$ErrorActionPreference = 'Stop'

if ($TimeoutSeconds -le 0) {
    throw 'TimeoutSeconds must be greater than 0.'
}

$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$libPath = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
. $libPath

if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_COMMAND_FINISH_BOOTSTRAPPED) {
    $forwardedArgs = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
    if ($Rebuild) { $forwardedArgs += '-Rebuild' }
    if ($ResetState) { $forwardedArgs += '-ResetState' }

    $bootstrapExitCode = 0
    Invoke-InteractiveWin11Bootstrap `
        -RepoRoot $repoRoot `
        -LauncherPath $launcherPath `
        -EnvironmentVariable 'WINGHOSTTY_INTERACTIVE_WIN11_COMMAND_FINISH_BOOTSTRAPPED' `
        -ArgumentList $forwardedArgs `
        -ExitCode ([ref] $bootstrapExitCode)
    exit $bootstrapExitCode
}

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'command-finish' -ResetState:$ResetState -IncludeResourcesDir
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs
$stdoutPath = Join-Path $layout.Logs 'interactive-win11-command-finish-stdout.log'
$stderrPath = Join-Path $layout.Logs 'interactive-win11-command-finish-stderr.log'
$configPath = Join-Path $layout.Temp 'interactive-win11-command-finish.conf'
$payloadPath = Join-Path $layout.Temp 'interactive-win11-command-finish-payload.ps1'

if ($launchAction -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}

Assert-InteractiveWin11ExeExists -ExePath $exePath

@"
desktop-notifications = true
notify-on-command-finish = always
notify-on-command-finish-action = notify
notify-on-command-finish-after = 0s
progress-style = true
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8

@"
`$stdout = [Console]::OpenStandardOutput()

function Send-Bytes([byte[]]`$bytes) {
    `$stdout.Write(`$bytes, 0, `$bytes.Length)
    `$stdout.Flush()
}

Send-Bytes ([byte[]](0x1b,0x5d,0x31,0x33,0x33,0x3b,0x43,0x07))
Send-Bytes ([byte[]](0x1b,0x5d,0x39,0x3b,0x34,0x3b,0x31,0x3b,0x35,0x30,0x07))
Start-Sleep -Seconds 2
Send-Bytes ([byte[]](0x1b,0x5d,0x31,0x33,0x33,0x3b,0x44,0x3b,0x31,0x37,0x07))
Start-Sleep -Seconds 4
"@ | Set-Content -LiteralPath $payloadPath -Encoding UTF8

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$aumid = 'com.ghostty.winghostty'
$toastMgr = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
$notifier = $toastMgr::CreateToastNotifier($aumid)
$settingValue = [int] $notifier.Setting
$settingText = $notifier.Setting.ToString()
$notificationsEnabled = $settingText -eq 'Enabled'

Remove-Item -LiteralPath $stdoutPath, $stderrPath -ErrorAction SilentlyContinue

$launchArgs = @(
    '--single-instance=false'
    "--class=winghostty-command-finish-$($layout.SandboxId)"
    "--config-file=$configPath"
    '-e'
    'powershell.exe'
    '-NoLogo'
    '-NoProfile'
    '-ExecutionPolicy'
    'Bypass'
    '-File'
    $payloadPath
)

$process = Start-Process `
    -FilePath $exePath `
    -ArgumentList $launchArgs `
    -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath `
    -PassThru

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$validated = $false
$failureReason = $null
$commandFinishedObserved = $false
$commandObservedAt = $null

try {
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 250

        $stderr = Get-InteractiveWin11TextFile -Path $stderrPath

        if ($stderr -match 'taskbar progress init failed|taskbar progress sync failed|panic: reached unreachable code') {
            $failureReason = 'unexpected runtime failure reported in stderr'
            break
        }

        if ((-not $commandFinishedObserved) -and $stderr -match 'command took ') {
            $commandFinishedObserved = $true
            $commandObservedAt = [DateTime]::UtcNow
        }

        if ($commandFinishedObserved) {
            $elapsedSinceCommandMs = ([DateTime]::UtcNow - $commandObservedAt).TotalMilliseconds
            if ($notificationsEnabled) {
                if ($stderr -match 'winrt toast show failed') {
                    $failureReason = "unexpected WinRT toast failure while notifier setting is Enabled ($settingText)"
                } elseif ($elapsedSinceCommandMs -ge 1000) {
                    $validated = $true
                }
            } else {
                if ($stderr -match 'winrt toast show failed err=.*NotifierDisabled; falling back to banner') {
                    $validated = $true
                } elseif ($elapsedSinceCommandMs -ge 1000) {
                    $failureReason = "expected explicit NotifierDisabled fallback while notifier setting is $settingText"
                }
            }

            if ($validated -or $failureReason) {
                break
            }
        }

        if ($process.HasExited -and -not $validated) {
            $failureReason = "winghostty exited before validation completed (exit code $($process.ExitCode))"
            break
        }
    }
}
finally {
    Stop-InteractiveWin11Process -Process $process
}

if (-not $validated) {
    if (-not $failureReason) {
        $failureReason = "timed out after $TimeoutSeconds seconds waiting for command-finished validation"
    }

    $stderrTail = Get-InteractiveWin11TextFileTail -Path $stderrPath -LineCount 80

    throw @"
interactive Win11 command-finish validation failed: $failureReason
toast setting: $settingText ($settingValue)
stderr log: $stderrPath
stdout log: $stdoutPath

Recent stderr:
$stderrTail
"@
}

Write-Host "interactive-win11 command-finish validation: PASS (setting=$settingText, stderr=$stderrPath)"
