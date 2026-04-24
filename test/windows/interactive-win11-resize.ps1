param(
    [switch] $Rebuild,
    [switch] $ResetState,
    [int] $TimeoutSeconds = 15
)

$ErrorActionPreference = 'Stop'

if ($TimeoutSeconds -le 0) {
    throw 'TimeoutSeconds must be greater than 0.'
}

$launcherPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$libPath = Join-Path $repoRoot 'scripts\interactive-win11-lib.ps1'
. $libPath

if (-not $env:WINGHOSTTY_INTERACTIVE_WIN11_RESIZE_BOOTSTRAPPED) {
    $forwardedArgs = @('-TimeoutSeconds', $TimeoutSeconds.ToString())
    if ($Rebuild) { $forwardedArgs += '-Rebuild' }
    if ($ResetState) { $forwardedArgs += '-ResetState' }

    $bootstrapExitCode = 0
    Invoke-InteractiveWin11Bootstrap `
        -RepoRoot $repoRoot `
        -LauncherPath $launcherPath `
        -EnvironmentVariable 'WINGHOSTTY_INTERACTIVE_WIN11_RESIZE_BOOTSTRAPPED' `
        -ArgumentList $forwardedArgs `
        -ExitCode ([ref] $bootstrapExitCode)
    exit $bootstrapExitCode
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class WinghosttyResizeWin32 {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UpdateWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr FindWindowExW(IntPtr hwndParent, IntPtr hwndChildAfter, string lpszClass, string lpszWindow);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessageW(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam);
}
'@

$wmEnterSizeMove = 0x0231
$wmExitSizeMove = 0x0232

function Assert-Win32CallSucceeded {
    param(
        [Parameter(Mandatory)] [bool] $Succeeded,
        [Parameter(Mandatory)] [string] $Operation
    )

    if (-not $Succeeded) {
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "$Operation failed with Win32 error $lastError"
    }
}

function Get-WindowRectObject {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd
    )

    $rect = New-Object WinghosttyResizeWin32+RECT
    if (-not [WinghosttyResizeWin32]::GetWindowRect($Hwnd, [ref] $rect)) {
        throw "GetWindowRect failed for hwnd=$Hwnd"
    }

    return [pscustomobject]@{
        Left = $rect.Left
        Top = $rect.Top
        Right = $rect.Right
        Bottom = $rect.Bottom
        Width = [Math]::Max(0, $rect.Right - $rect.Left)
        Height = [Math]::Max(0, $rect.Bottom - $rect.Top)
    }
}

function Show-ResizeHarnessWindow {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd
    )

    [void] [WinghosttyResizeWin32]::ShowWindow($Hwnd, 9)
    [void] [WinghosttyResizeWin32]::SetForegroundWindow($Hwnd)
}

function Capture-WindowImage {
    param(
        [Parameter(Mandatory)] [IntPtr] $Hwnd,
        [Parameter(Mandatory)] [string] $Path
    )

    $rect = Get-WindowRectObject -Hwnd $Hwnd
    $width = [Math]::Max(1, $rect.Width)
    $height = [Math]::Max(1, $rect.Height)
    $bmp = New-Object System.Drawing.Bitmap $width, $height
    try {
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $gfx.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size)
        }
        finally {
            $gfx.Dispose()
        }
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bmp.Dispose()
    }
}

function Measure-ExpansionBandRatios {
    param(
        [Parameter(Mandatory)] [System.Drawing.Bitmap] $Bitmap,
        [Parameter(Mandatory)] [System.Drawing.Rectangle] $Region,
        [int] $Step = 3
    )

    $samples = 0
    $nearBlack = 0
    $neutralGray = 0
    $maxX = $Region.X + $Region.Width
    $maxY = $Region.Y + $Region.Height
    for ($y = $Region.Y; $y -lt $maxY; $y += $Step) {
        for ($x = $Region.X; $x -lt $maxX; $x += $Step) {
            $color = $Bitmap.GetPixel($x, $y)
            $samples++
            if ($color.R -le 14 -and $color.G -le 14 -and $color.B -le 14) {
                $nearBlack++
            }
            $maxChannel = [Math]::Max($color.R, [Math]::Max($color.G, $color.B))
            $minChannel = [Math]::Min($color.R, [Math]::Min($color.G, $color.B))
            $avgChannel = [int] (($color.R + $color.G + $color.B) / 3)
            if (($maxChannel - $minChannel) -le 10 -and $avgChannel -ge 80 -and $avgChannel -le 250) {
                $neutralGray++
            }
        }
    }

    if ($samples -eq 0) {
        throw "empty screenshot sample region: $Region"
    }

    return [pscustomobject]@{
        NearBlack = [double] $nearBlack / [double] $samples
        NeutralGray = [double] $neutralGray / [double] $samples
    }
}

function Assert-SettledResizeImageHasNoUnpaintedExpansionBands {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $bmp = [System.Drawing.Bitmap]::FromFile($Path)
    try {
        if ($bmp.Width -lt 900 -or $bmp.Height -lt 560) {
            throw "resize screenshot is too small for reliable analysis: $($bmp.Width)x$($bmp.Height)"
        }

        $rightBand = [System.Drawing.Rectangle]::new(
            [Math]::Max(0, $bmp.Width - 260),
            [Math]::Min([Math]::Max(96, [int] ($bmp.Height * 0.18)), $bmp.Height - 220),
            200,
            [Math]::Max(120, $bmp.Height - [Math]::Min([Math]::Max(96, [int] ($bmp.Height * 0.18)), $bmp.Height - 220) - 96)
        )
        $bottomBand = [System.Drawing.Rectangle]::new(
            100,
            [Math]::Max(120, $bmp.Height - 220),
            [Math]::Max(200, $bmp.Width - 200),
            150
        )

        $rightRatios = Measure-ExpansionBandRatios -Bitmap $bmp -Region $rightBand
        $bottomRatios = Measure-ExpansionBandRatios -Bitmap $bmp -Region $bottomBand
        $blackThreshold = 0.25
        $grayThreshold = 0.15

        if ($rightRatios.NearBlack -gt $blackThreshold -or $bottomRatios.NearBlack -gt $blackThreshold) {
            throw ("settled resize expansion area is unexpectedly near-black: right={0:P1} bottom={1:P1} screenshot={2}" -f $rightRatios.NearBlack, $bottomRatios.NearBlack, $Path)
        }
        if ($rightRatios.NeutralGray -gt $grayThreshold -or $bottomRatios.NeutralGray -gt $grayThreshold) {
            throw ("settled resize expansion area has unpainted neutral-gray boxes: right={0:P1} bottom={1:P1} screenshot={2}" -f $rightRatios.NeutralGray, $bottomRatios.NeutralGray, $Path)
        }

        return [pscustomobject]@{
            RightBlackRatio = $rightRatios.NearBlack
            BottomBlackRatio = $bottomRatios.NearBlack
            RightGrayRatio = $rightRatios.NeutralGray
            BottomGrayRatio = $bottomRatios.NeutralGray
        }
    }
    finally {
        $bmp.Dispose()
    }
}

$harness = Initialize-InteractiveWin11Sandbox -RepoRoot $repoRoot -SandboxName 'resize' -ResetState:$ResetState -IncludeResourcesDir
$repoRoot = $harness.RepoRoot
$layout = $harness.Layout

$exePath = Get-InteractiveWin11ExePath -RepoRoot $repoRoot
$buildInputs = Get-InteractiveWin11DefaultBuildInputs -RepoRoot $repoRoot
$launchAction = Get-InteractiveWin11LaunchAction -ExePath $exePath -Rebuild:$Rebuild -BuildInputs $buildInputs
$stdoutPath = Join-Path $layout.Logs 'interactive-win11-resize-stdout.log'
$stderrPath = Join-Path $layout.Logs 'interactive-win11-resize-stderr.log'
$configPath = Join-Path $layout.Temp 'interactive-win11-resize.conf'
$payloadPath = Join-Path $layout.Temp 'interactive-win11-resize-payload.ps1'
$screenshotPath = Join-Path $layout.Logs 'interactive-win11-resize-grown.png'
$surfaceScreenshotPath = Join-Path $layout.Logs 'interactive-win11-resize-grown-surface.png'

if ($launchAction -eq 'build') {
    Invoke-InteractiveWin11Build -RepoRoot $repoRoot
}

Assert-InteractiveWin11ExeExists -ExePath $exePath

@"
background = #F3E9CB
foreground = #111111
background-opacity = 1
confirm-close-surface = false
font-size = 16
"@ | Set-Content -LiteralPath $configPath -Encoding UTF8

@"
Write-Output 'resize validation ready'
Start-Sleep -Seconds 30
"@ | Set-Content -LiteralPath $payloadPath -Encoding UTF8

Remove-Item -LiteralPath $stdoutPath, $stderrPath, $screenshotPath, $surfaceScreenshotPath -ErrorAction SilentlyContinue

$launchArgs = @(
    '--single-instance=false'
    "--class=winghostty-resize-$($layout.SandboxId)"
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

$successPattern = 'started subcommand path='
$runtimeFailurePattern = 'paint redraw failed|InvalidValue|surface closed|panic: reached unreachable code|error starting IO thread:'
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$enteredSizeMove = $false

try {
    while ([DateTime]::UtcNow -lt $deadline) {
        $process.Refresh()
        $stderr = Get-InteractiveWin11TextFile -Path $stderrPath
        if ($stderr -match $runtimeFailurePattern) {
            throw "unexpected runtime failure reported before resize:`n$stderr"
        }

        if ($process.MainWindowHandle -ne 0 -and $stderr.Contains($successPattern)) {
            break
        }

        if ($process.HasExited) {
            throw "winghostty exited before resize validation could start (exit code $($process.ExitCode))"
        }

        Start-Sleep -Milliseconds 100
    }

    if ($process.MainWindowHandle -eq 0) {
        throw 'winghostty main window handle was not ready before timeout.'
    }

    $workingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x = $workingArea.Left + 40
    $y = $workingArea.Top + 40
    $initialWidth = [Math]::Min(720, [Math]::Max(640, $workingArea.Width - 80))
    $initialHeight = [Math]::Min(460, [Math]::Max(420, $workingArea.Height - 100))
    $grownWidth = [Math]::Min(1280, [Math]::Max(960, $workingArea.Width - 80))
    $grownHeight = [Math]::Min(820, [Math]::Max(620, $workingArea.Height - 100))

    Show-ResizeHarnessWindow -Hwnd $process.MainWindowHandle
    Assert-Win32CallSucceeded `
        -Succeeded ([WinghosttyResizeWin32]::MoveWindow($process.MainWindowHandle, $x, $y, $initialWidth, $initialHeight, $true)) `
        -Operation "initial MoveWindow(hwnd=$($process.MainWindowHandle))"
    Start-Sleep -Milliseconds 600

    [void] [WinghosttyResizeWin32]::SendMessageW($process.MainWindowHandle, $wmEnterSizeMove, [UIntPtr]::Zero, [IntPtr]::Zero)
    $enteredSizeMove = $true
    Assert-Win32CallSucceeded `
        -Succeeded ([WinghosttyResizeWin32]::MoveWindow($process.MainWindowHandle, $x, $y, $grownWidth, $grownHeight, $true)) `
        -Operation "grown MoveWindow(hwnd=$($process.MainWindowHandle))"
    [void] [WinghosttyResizeWin32]::UpdateWindow($process.MainWindowHandle)
    Start-Sleep -Milliseconds 700

    [void] [WinghosttyResizeWin32]::SendMessageW($process.MainWindowHandle, $wmExitSizeMove, [UIntPtr]::Zero, [IntPtr]::Zero)
    $enteredSizeMove = $false
    [void] [WinghosttyResizeWin32]::UpdateWindow($process.MainWindowHandle)
    Start-Sleep -Milliseconds 700

    $surfaceHwnd = [WinghosttyResizeWin32]::FindWindowExW($process.MainWindowHandle, [IntPtr]::Zero, 'winghostty.win32', $null)
    if ($surfaceHwnd -eq [IntPtr]::Zero) {
        throw 'failed to locate winghostty surface child HWND after resize'
    }
    $hostRect = Get-WindowRectObject -Hwnd $process.MainWindowHandle
    $surfaceRect = Get-WindowRectObject -Hwnd $surfaceHwnd
    Capture-WindowImage -Hwnd $process.MainWindowHandle -Path $screenshotPath
    Capture-WindowImage -Hwnd $surfaceHwnd -Path $surfaceScreenshotPath

    $ratios = Assert-SettledResizeImageHasNoUnpaintedExpansionBands -Path $surfaceScreenshotPath

    $stderr = Get-InteractiveWin11TextFile -Path $stderrPath
    if ($stderr -match $runtimeFailurePattern) {
        throw "unexpected runtime failure reported after resize:`n$stderr"
    }
}
finally {
    if ($enteredSizeMove -and $process.MainWindowHandle -ne 0) {
        [void] [WinghosttyResizeWin32]::SendMessageW($process.MainWindowHandle, $wmExitSizeMove, [UIntPtr]::Zero, [IntPtr]::Zero)
    }
    Stop-InteractiveWin11Process -Process $process
}

Write-Host ("interactive-win11 resize validation: PASS (stderr={0}, screenshot={1}, surface-screenshot={2}, host={3}x{4}, surface={5}x{6}, right-near-black={7:P1}, bottom-near-black={8:P1}, right-neutral-gray={9:P1}, bottom-neutral-gray={10:P1})" -f $stderrPath, $screenshotPath, $surfaceScreenshotPath, $hostRect.Width, $hostRect.Height, $surfaceRect.Width, $surfaceRect.Height, $ratios.RightBlackRatio, $ratios.BottomBlackRatio, $ratios.RightGrayRatio, $ratios.BottomGrayRatio)
