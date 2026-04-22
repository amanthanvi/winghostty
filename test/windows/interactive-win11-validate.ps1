param(
    [switch] $Rebuild,
    [switch] $ResetState
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$suiteLogDir = Join-Path $env:TEMP ("winghostty-interactive-win11-suite-{0}" -f $PID)
New-Item -ItemType Directory -Force -Path $suiteLogDir | Out-Null
$devWindowsCmd = Join-Path $repoRoot 'scripts\dev-windows.cmd'

class InteractiveWin11HarnessRun {
    [string] $Script
    [System.Diagnostics.Process] $Process
    [string] $Stdout
    [string] $Stderr

    InteractiveWin11HarnessRun(
        [string] $Script,
        [System.Diagnostics.Process] $Process,
        [string] $Stdout,
        [string] $Stderr
    ) {
        if ([string]::IsNullOrWhiteSpace($Script)) { throw 'Script is required.' }
        if ($null -eq $Process) { throw 'Process is required.' }
        if ([string]::IsNullOrWhiteSpace($Stdout)) { throw 'Stdout is required.' }
        if ([string]::IsNullOrWhiteSpace($Stderr)) { throw 'Stderr is required.' }

        $this.Script = $Script
        $this.Process = $Process
        $this.Stdout = $Stdout
        $this.Stderr = $Stderr
    }
}

function Invoke-SuiteBuild {
    Push-Location $repoRoot
    try {
        & cmd /c $devWindowsCmd zig build -Demit-exe=true
        if ($LASTEXITCODE -ne 0) {
            throw "suite rebuild failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}

function Get-HarnessArguments {
    param(
        [Parameter(Mandatory)] [string] $ScriptName,
        [int] $TimeoutSeconds = 0,
        [switch] $IncludeResetState
    )

    $scriptPath = Join-Path $PSScriptRoot $ScriptName
    $args = @(
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        $scriptPath
    )
    if ($TimeoutSeconds -gt 0) {
        $args += @(
            '-TimeoutSeconds'
            $TimeoutSeconds.ToString()
        )
    }
    if ($ResetState -and $IncludeResetState) { $args += '-ResetState' }

    return $args
}

function Invoke-Harness {
    param(
        [Parameter(Mandatory)] [string] $ScriptName,
        [int] $TimeoutSeconds = 0,
        [switch] $PassResetState
    )

    $args = Get-HarnessArguments -ScriptName $ScriptName -TimeoutSeconds $TimeoutSeconds -IncludeResetState:$PassResetState

    & powershell.exe @args
    if ($LASTEXITCODE -ne 0) {
        throw "$ScriptName failed with exit code $LASTEXITCODE"
    }
}

function Start-Harness {
    param(
        [Parameter(Mandatory)] [string] $ScriptName,
        [Parameter(Mandatory)] [int] $TimeoutSeconds
    )

    $stdoutPath = Join-Path $suiteLogDir ("{0}.stdout.log" -f $ScriptName)
    $stderrPath = Join-Path $suiteLogDir ("{0}.stderr.log" -f $ScriptName)
    $args = Get-HarnessArguments -ScriptName $ScriptName -TimeoutSeconds $TimeoutSeconds -IncludeResetState

    $process = Start-Process `
        -FilePath 'powershell.exe' `
        -ArgumentList $args `
        -WorkingDirectory $repoRoot `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru

    return [InteractiveWin11HarnessRun]::new($ScriptName, $process, $stdoutPath, $stderrPath)
}

function Get-HarnessSummary {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -eq 0) {
        return ''
    }

    return $lines[-1]
}

if ($Rebuild) {
    Invoke-SuiteBuild
}

Invoke-Harness -ScriptName 'interactive-win11.ps1'
Invoke-Harness -ScriptName 'interactive-win11-smoke.ps1' -TimeoutSeconds 10 -PassResetState

[InteractiveWin11HarnessRun[]] $parallelRuns = @(
    Start-Harness -ScriptName 'interactive-win11-command-finish.ps1' -TimeoutSeconds 12
    Start-Harness -ScriptName 'interactive-win11-progress.ps1' -TimeoutSeconds 20
)

foreach ($run in $parallelRuns) {
    $run.Process.WaitForExit()
}

foreach ($run in $parallelRuns) {
    $stdout = if (Test-Path -LiteralPath $run.Stdout) { Get-Content -LiteralPath $run.Stdout -Raw } else { '' }
    $stderr = if (Test-Path -LiteralPath $run.Stderr) { Get-Content -LiteralPath $run.Stderr -Raw } else { '' }
    $summary = Get-HarnessSummary -Path $run.Stdout
    $exitCode = $run.Process.ExitCode

    if (($null -ne $exitCode) -and ($exitCode -ne 0)) {
        throw @"
$($run.Script) exited with code $exitCode
stdout:
$stdout

stderr:
$stderr
"@
    }

    if ($summary -notlike '*PASS*') {
        throw @"
$($run.Script) did not report PASS
stdout:
$stdout

stderr:
$stderr
"@
    }

    if (-not [string]::IsNullOrWhiteSpace($summary)) {
        Write-Host $summary
    }
}

Write-Host "interactive-win11 validate suite: PASS ($suiteLogDir)"
