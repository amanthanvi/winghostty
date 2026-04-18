function Get-InteractiveWin11NormalizedPath {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    return $full.TrimEnd('\').Replace('/', '\')
}

function Get-InteractiveWin11WorktreeId {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot
    )

    $normalized = Get-InteractiveWin11NormalizedPath -Path $RepoRoot
    $leaf = Split-Path -Path $normalized -Leaf
    $parentLeaf = Split-Path -Path (Split-Path -Path $normalized -Parent) -Leaf
    $slugSource = "$parentLeaf-$leaf".ToLowerInvariant()
    $slug = ($slugSource -replace '[^a-z0-9.-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        $slug = 'worktree'
    }
    if ($slug.Length -gt 32) {
        $slug = $slug.Substring(0, 32).TrimEnd('-')
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized.ToLowerInvariant())
        $hash = [System.BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }

    return '{0}-{1}' -f $slug, $hash.Substring(0, 12)
}

function Get-InteractiveWin11SandboxLayout {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot
    )

    $normalizedRepoRoot = Get-InteractiveWin11NormalizedPath -Path $RepoRoot
    $worktreeId = Get-InteractiveWin11WorktreeId -RepoRoot $normalizedRepoRoot
    $sandboxRoot = Join-Path $normalizedRepoRoot ".sandbox\win11\$worktreeId"
    $localAppData = Join-Path $sandboxRoot 'localappdata'

    return [ordered]@{
        RepoRoot      = $normalizedRepoRoot
        WorktreeId    = $worktreeId
        SandboxRoot   = $sandboxRoot
        AppData       = Join-Path $sandboxRoot 'appdata'
        LocalAppData  = $localAppData
        XdgConfigHome = $localAppData
        XdgCacheHome  = Join-Path $sandboxRoot 'cache'
        XdgStateHome  = Join-Path $sandboxRoot 'state'
        Temp          = Join-Path $sandboxRoot 'temp'
        Logs          = Join-Path $sandboxRoot 'logs'
    }
}

function New-InteractiveWin11Sandbox {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Layout
    )

    foreach ($path in @(
        $Layout.SandboxRoot,
        $Layout.AppData,
        $Layout.LocalAppData,
        $Layout.XdgCacheHome,
        $Layout.XdgStateHome,
        $Layout.Temp,
        $Layout.Logs
    )) {
        New-Item -ItemType Directory -Force -Path $path -ErrorAction Stop | Out-Null
    }
}

function Get-InteractiveWin11Environment {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Layout
    )

    return [ordered]@{
        APPDATA         = $Layout.AppData
        LOCALAPPDATA    = $Layout.LocalAppData
        XDG_CONFIG_HOME = $Layout.XdgConfigHome
        XDG_CACHE_HOME  = $Layout.XdgCacheHome
        XDG_STATE_HOME  = $Layout.XdgStateHome
        TEMP            = $Layout.Temp
        TMP             = $Layout.Temp
    }
}

function Get-InteractiveWin11LaunchArguments {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Layout
    )

    return @(
        '--single-instance=false'
        "--class=winghostty-interactive-$($Layout.WorktreeId)"
    )
}

function Get-InteractiveWin11LaunchAction {
    param(
        [Parameter(Mandatory)] [string] $ExePath,
        [switch] $Rebuild,
        [switch] $NoBuild
    )

    $resolvedExePath = Get-InteractiveWin11NormalizedPath -Path $ExePath
    if ($Rebuild -and $NoBuild) {
        throw 'Cannot use -Rebuild with -NoBuild together.'
    }

    if ($Rebuild) {
        return 'build'
    }

    if ([System.IO.File]::Exists($resolvedExePath)) {
        return 'launch'
    }

    if ($NoBuild) {
        throw "Missing winghostty.exe at $resolvedExePath"
    }

    return 'build'
}

function Reset-InteractiveWin11Sandbox {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Layout
    )

    $sandboxBase = Get-InteractiveWin11NormalizedPath -Path (Join-Path $Layout.RepoRoot '.sandbox\win11')
    $target = Get-InteractiveWin11NormalizedPath -Path $Layout.SandboxRoot
    $sandboxPrefix = '{0}\' -f $sandboxBase

    if (-not $target.StartsWith($sandboxPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to reset sandbox outside ${sandboxBase}: $target"
    }

    if (Test-Path -LiteralPath $target -ErrorAction Stop) {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
    }
}
