param(
    [string]$Version = "",
    [string]$LauncherExe = "",
    [string]$Output = "",
    [string]$SourceRoot = ""
)

. (Join-Path $PSScriptRoot "paths.ps1")
$paths = Get-CompilePaths -SourceRoot $SourceRoot

$root = $paths.SourceRoot
$wxs = Join-Path $PSScriptRoot "wix\MonitorSMS.wxs"
$envFile = Join-Path $PSScriptRoot ".env"
if (-not (Test-Path $envFile)) {
    $envFile = Join-Path $PSScriptRoot "env.template"
}

function Get-EnvValue {
    param(
        [string]$Path,
        [string]$Key
    )
    if (-not (Test-Path $Path)) {
        return $null
    }
    foreach ($raw in Get-Content -Path $Path) {
        $line = $raw.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith("#") -or -not $line.Contains("=")) {
            continue
        }
        $idx = $line.IndexOf("=")
        $k = $line.Substring(0, $idx).Trim()
        if ($k -ne $Key) {
            continue
        }
        $value = $line.Substring($idx + 1).Trim()
        if ($value.Length -ge 2) {
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        return $value
    }
    return $null
}

function Resolve-WixCommand {
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    $toolDll = $null
    $storeRoot = Join-Path $env:USERPROFILE ".dotnet\tools\.store\wix"
    if (Test-Path $storeRoot) {
        $toolDll = Get-ChildItem -Path $storeRoot -Recurse -Filter wix.dll -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like "*\tools\net6.0\any\wix.dll" } |
            Sort-Object FullName -Descending |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if ($dotnet -and (Test-Path $toolDll)) {
        return [pscustomobject]@{
            Executable = $dotnet.Source
            PrefixArgs = @($toolDll)
            Description = "dotnet wix.dll"
        }
    }

    $cmd = Get-Command wix -ErrorAction SilentlyContinue
    if ($cmd) {
        return [pscustomobject]@{
            Executable = $cmd.Source
            PrefixArgs = @()
            Description = "wix.exe"
        }
    }

    $dotnetTool = Join-Path $env:USERPROFILE ".dotnet\tools\wix.exe"
    if (Test-Path $dotnetTool) {
        return [pscustomobject]@{
            Executable = $dotnetTool
            PrefixArgs = @()
            Description = "wix.exe"
        }
    }

    return $null
}

if (-not (Test-Path $wxs)) {
    Write-Error "WiX source file not found: $wxs"
    exit 1
}

$wixCommand = Resolve-WixCommand
if (-not $wixCommand) {
    Write-Error @"
WiX CLI was not found.

Install prerequisites, then rerun this script:
1. Install the .NET SDK
2. Run: dotnet tool install --global wix
3. Open a new PowerShell window

If you already installed WiX as a .NET tool, but this shell still cannot find it,
try running it directly from:
$env:USERPROFILE\.dotnet\tools\wix.exe
"@
    exit 1
}

if (-not $Version) {
    $line = Select-String -Path (Join-Path $root "pyproject.toml") -Pattern '^version\s*=' | Select-Object -First 1
    if ($null -eq $line) {
        Write-Error "Unable to find version in pyproject.toml."
        exit 1
    }
    $Version = ($line.Line -replace 'version\s*=\s*"(.*)"', '$1').Trim()
}

if (-not $LauncherExe) {
    $LauncherExe = Join-Path $paths.DistPath "MonitorSMSLauncher\MonitorSMSLauncher.exe"
}

if (-not (Test-Path $LauncherExe)) {
    Write-Error "Launcher exe not found. Run .\\packaging\\build-launcher.ps1 first."
    exit 1
}

if (-not $Output) {
    $Output = Join-Path $paths.ArtifactsPath "MonitorSMS-$Version.msi"
}

$manifestUrl = Get-EnvValue -Path $envFile -Key "MONITOR_UPDATE_MANIFEST_URL"
if ([string]::IsNullOrWhiteSpace($manifestUrl)) {
    Write-Error "MONITOR_UPDATE_MANIFEST_URL is missing or blank in $envFile. Set it so the launcher can download the initial version."
    exit 1
}
$arpIcon = Join-Path $PSScriptRoot "app.ico"

$args = @(
    "build",
    $wxs,
    "-d", "Version=$Version",
    "-d", "LauncherExe=$LauncherExe",
    "-d", "EnvFile=$envFile",
    "-o", $Output
)

if (Test-Path $arpIcon) {
    $args += @("-d", "ArpIcon=$arpIcon")
}

& $wixCommand.Executable @($wixCommand.PrefixArgs + $args)
