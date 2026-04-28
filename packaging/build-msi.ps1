param(
    [string]$Version = "",
    [string]$LauncherExe = "",
    [string]$Output = "",
    [string]$SourceRoot = "",
    [string]$Channel = "",
    [string]$ManifestUrl = "",
    [string]$PrimaryBaseUrl = "",
    [string]$BackupBaseUrl = "",
    [string]$EstacionesKey = "",
    [string]$ReportesKey = "",
    [string]$DebugPanelVisible = "",
    [switch]$AllowSelfContained
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "paths.ps1")
. (Join-Path $PSScriptRoot "channel.ps1")
$paths = Get-CompilePaths -SourceRoot $SourceRoot
$resolvedChannel = Resolve-MonitorChannel -Channel $Channel
$artifactPrefix = Get-ChannelArtifactPrefix -Channel $resolvedChannel
$productDisplayName = Get-ChannelProductDisplayName -Channel $resolvedChannel
$installFolderName = Get-ChannelInstallFolderName -Channel $resolvedChannel
$programMenuFolderName = Get-ChannelProgramMenuFolderName -Channel $resolvedChannel
$desktopShortcutName = Get-ChannelDesktopShortcutName -Channel $resolvedChannel
$localDataSubdir = Get-ChannelLocalDataSubdir -Channel $resolvedChannel
$msiUpgradeCode = Get-ChannelMsiUpgradeCode -Channel $resolvedChannel

$root = $paths.SourceRoot
$wxs = Join-Path $PSScriptRoot "wix\MonitorSMS.wxs"
$clientConfigFile = Join-Path $paths.CompileRoot ".tmp\client-config\installer.env"

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

$launcherItem = Get-Item -LiteralPath $LauncherExe -ErrorAction SilentlyContinue
if ($launcherItem -and -not $AllowSelfContained) {
    $sizeMb = [math]::Round($launcherItem.Length / 1MB, 1)
    if ($launcherItem.Length -gt 30MB) {
        Write-Error @"
Launcher exe appears to be self-contained (~$sizeMb MB).
Rebuild the launcher framework-dependent, then rerun:
  .\packaging\build-launcher.ps1 -FrameworkDependent
  .\packaging\build-msi.ps1

To override this check, pass -AllowSelfContained.
"@
        exit 1
    }
}

if (-not $Output) {
    $versionArtifactsDir = Get-VersionArtifactsPath -ArtifactsRoot $paths.ArtifactsPath -Version $Version -ArtifactPrefix $artifactPrefix
    New-Item -ItemType Directory -Path $versionArtifactsDir -Force | Out-Null
    $Output = Join-Path $versionArtifactsDir ("${artifactPrefix}MonitorSMS-$Version.msi")
}

$outputDir = Split-Path -Parent $Output
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$clientConfigArgs = @{
    OutputPath = $clientConfigFile
    Channel = $resolvedChannel
    ManifestUrl = $ManifestUrl
    PrimaryBaseUrl = $PrimaryBaseUrl
    BackupBaseUrl = $BackupBaseUrl
    EstacionesKey = $EstacionesKey
    ReportesKey = $ReportesKey
}
if ($PSBoundParameters.ContainsKey("DebugPanelVisible")) {
    $clientConfigArgs.DebugPanelVisible = $DebugPanelVisible
}

& (Join-Path $PSScriptRoot "new-client-config.ps1") @clientConfigArgs
if (-not $?) {
    exit 1
}
$arpIcon = Join-Path $PSScriptRoot "app.ico"

$args = @(
    "build",
    $wxs,
    "-ext", "WixToolset.Util.wixext",
    "-d", "Version=$Version",
    "-d", "ProductDisplayName=$productDisplayName",
    "-d", "InstallFolderName=$installFolderName",
    "-d", "ProgramMenuFolderName=$programMenuFolderName",
    "-d", "DesktopShortcutName=$desktopShortcutName",
    "-d", "RuntimeDataSubdir=$localDataSubdir",
    "-d", "MsiUpgradeCode=$msiUpgradeCode",
    "-d", "LauncherExe=$LauncherExe",
    "-d", "EnvFile=$clientConfigFile",
    "-o", $Output
)

if (Test-Path $arpIcon) {
    $args += @("-d", "ArpIcon=$arpIcon")
}

& $wixCommand.Executable @($wixCommand.PrefixArgs + $args)
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
