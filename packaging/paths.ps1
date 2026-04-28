param(
    [string]$SourceRoot = ""
)

function Get-CompilePaths {
    param(
        [string]$SourceRoot = ""
    )

    $compileRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
    $resolvedSource = $SourceRoot

    if (-not $resolvedSource) {
        if ($env:MONITOR_GUI_ROOT) {
            $resolvedSource = $env:MONITOR_GUI_ROOT
        } else {
            $parent = Split-Path -Parent $compileRoot
            $resolvedSource = Join-Path $parent "Monitor GUI"
        }
    }

    try {
        $resolvedSource = (Resolve-Path $resolvedSource -ErrorAction Stop).Path
    } catch {
        throw "Source root not found: $resolvedSource. Pass -SourceRoot or set MONITOR_GUI_ROOT."
    }

    $pyproject = Join-Path $resolvedSource "pyproject.toml"
    $entry = Join-Path $resolvedSource "src\station_monitor\main.py"
    if (-not (Test-Path $pyproject)) {
        throw "pyproject.toml not found in source root: $resolvedSource"
    }
    if (-not (Test-Path $entry)) {
        throw "Entry point not found: $entry"
    }

    return [pscustomobject]@{
        SourceRoot = $resolvedSource
        CompileRoot = $compileRoot.Path
        DistPath = Join-Path $compileRoot "dist"
        PyinstallerBuildPath = Join-Path $compileRoot ".pyinstaller\build"
        PyinstallerSpecPath = Join-Path $compileRoot ".pyinstaller\spec"
        ArtifactsPath = Join-Path $compileRoot "packaging\artifacts"
    }
}

function Get-VersionArtifactsPath {
    param(
        [string]$ArtifactsRoot,
        [string]$Version,
        [string]$ArtifactPrefix = ""
    )

    if (-not $ArtifactsRoot) {
        throw "Artifacts root path is required."
    }

    if (-not $Version) {
        throw "Version is required to resolve artifacts path."
    }

    $folderName = "${ArtifactPrefix}MonitorSMS-$Version"
    return Join-Path $ArtifactsRoot $folderName
}

if ($MyInvocation.InvocationName -ne '.') {
    Get-CompilePaths -SourceRoot $SourceRoot
}
