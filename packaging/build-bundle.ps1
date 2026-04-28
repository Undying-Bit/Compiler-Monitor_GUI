param(
    [string]$Version = "",
    [string]$MsiPath = "",
    [string]$Output = "",
    [string]$SourceRoot = "",
    [string]$Channel = "",
    [string]$RuntimeUrl = "",
    [string]$RuntimeFile = "",
    [string]$RuntimeSha256 = "",
    [switch]$EmbedNet8Runtime
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "paths.ps1")
. (Join-Path $PSScriptRoot "channel.ps1")
$paths = Get-CompilePaths -SourceRoot $SourceRoot
$resolvedChannel = Resolve-MonitorChannel -Channel $Channel
$artifactPrefix = Get-ChannelArtifactPrefix -Channel $resolvedChannel
$productDisplayName = Get-ChannelProductDisplayName -Channel $resolvedChannel
$bundleUpgradeCode = Get-ChannelBundleUpgradeCode -Channel $resolvedChannel

$root = $paths.SourceRoot
$bundleWxs = Join-Path $PSScriptRoot "wix\MonitorSMS.bundle.wxs"

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

function Get-WixToolVersion {
    param(
        [pscustomobject]$WixCommand
    )

    $output = & $WixCommand.Executable @($WixCommand.PrefixArgs + @("--version")) 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        return ""
    }

    $line = ($output | Select-Object -First 1).ToString().Trim()
    $match = [regex]::Match($line, "\d+\.\d+\.\d+")
    if ($match.Success) {
        return $match.Value
    }

    return ""
}

function Get-WixInstalledExtensions {
    param(
        [pscustomobject]$WixCommand
    )

    $output = & $WixCommand.Executable @($WixCommand.PrefixArgs + @("extension", "list", "-g")) 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to query WiX extension cache."
        exit $LASTEXITCODE
    }

    $extensions = @{}
    foreach ($line in $output) {
        $trimmed = $line.Trim()
        if (-not $trimmed) {
            continue
        }

        $match = [regex]::Match($trimmed, "^(?<id>\S+)\s+(?<version>\S+)(?<damaged>\s+\(damaged\))?$")
        if (-not $match.Success) {
            continue
        }

        $extensions[$match.Groups["id"].Value] = [pscustomobject]@{
            Version = $match.Groups["version"].Value
            Damaged = $match.Groups["damaged"].Success
        }
    }

    return $extensions
}

function Ensure-WixExtensions {
    param(
        [pscustomobject]$WixCommand,
        [string[]]$RequiredExtensions
    )

    $installed = Get-WixInstalledExtensions -WixCommand $WixCommand
    $wixVersion = Get-WixToolVersion -WixCommand $WixCommand

    foreach ($extensionId in $RequiredExtensions) {
        if ($installed.ContainsKey($extensionId)) {
            $entry = $installed[$extensionId]
            if (-not $entry.Damaged) {
                continue
            }

            Write-Host "Repairing damaged WiX extension: $extensionId"
            & $WixCommand.Executable @($WixCommand.PrefixArgs + @("extension", "remove", "-g", $extensionId))
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to remove damaged WiX extension: $extensionId"
                exit $LASTEXITCODE
            }
        }

        $extensionRef = $extensionId
        if ($wixVersion) {
            $extensionRef = "$extensionId/$wixVersion"
        }

        Write-Host "Installing missing WiX extension: $extensionRef"
        & $WixCommand.Executable @($WixCommand.PrefixArgs + @("extension", "add", "-g", $extensionRef))
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to install WiX extension: $extensionRef"
            exit $LASTEXITCODE
        }
    }
}

if (-not (Test-Path $bundleWxs)) {
    Write-Error "WiX bundle source file not found: $bundleWxs"
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

if (-not $MsiPath) {
    $versionArtifactsDir = Get-VersionArtifactsPath -ArtifactsRoot $paths.ArtifactsPath -Version $Version -ArtifactPrefix $artifactPrefix
    $MsiPath = Join-Path $versionArtifactsDir ("${artifactPrefix}MonitorSMS-$Version.msi")
}

if (-not (Test-Path $MsiPath)) {
    & (Join-Path $PSScriptRoot "build-msi.ps1") -Version $Version -Output $MsiPath -SourceRoot $SourceRoot -Channel $resolvedChannel
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

if (-not $Output) {
    $versionArtifactsDir = Get-VersionArtifactsPath -ArtifactsRoot $paths.ArtifactsPath -Version $Version -ArtifactPrefix $artifactPrefix
    New-Item -ItemType Directory -Path $versionArtifactsDir -Force | Out-Null
    $Output = Join-Path $versionArtifactsDir ("${artifactPrefix}MonitorSMS-$Version-setup.exe")
}

$outputDir = Split-Path -Parent $Output
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

if (-not $RuntimeUrl) {
    $RuntimeUrl = "https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe"
}

if (-not $RuntimeSha256) {
    $RuntimeSha256 = $env:MONITOR_NET8_RUNTIME_SHA256
}

if (-not $RuntimeFile) {
    $RuntimeFile = Join-Path $paths.CompileRoot ".tmp\windowsdesktop-runtime-win-x64.exe"
}

$runtimeDir = Split-Path -Parent $RuntimeFile
if (-not (Test-Path $runtimeDir)) {
    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
}

if (-not $RuntimeSha256) {
    Write-Error "Runtime SHA256 not configured. Set MONITOR_NET8_RUNTIME_SHA256 or pass -RuntimeSha256."
    exit 1
}

if (-not (Test-Path $RuntimeFile)) {
    Write-Host "Downloading .NET 8 Desktop Runtime..."
    Invoke-WebRequest -Uri $RuntimeUrl -OutFile $RuntimeFile
}

$downloadedHash = (Get-FileHash -Algorithm SHA256 $RuntimeFile).Hash.ToLowerInvariant()
if ($downloadedHash -ne $RuntimeSha256.ToLowerInvariant()) {
    Write-Error "Runtime SHA256 mismatch for $RuntimeFile. Expected $RuntimeSha256, got $downloadedHash."
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

$requiredExtensions = @(
    "WixToolset.BootstrapperApplications.wixext",
    "WixToolset.Netfx.wixext"
)
Ensure-WixExtensions -WixCommand $wixCommand -RequiredExtensions $requiredExtensions

$embedDefine = "EmbedNet8Runtime=" + ($(if ($EmbedNet8Runtime) { "yes" } else { "no" }))

$args = @(
    "build",
    $bundleWxs,
    "-d", "Version=$Version",
    "-d", "ProductDisplayName=$productDisplayName",
    "-d", "BundleUpgradeCode=$bundleUpgradeCode",
    "-d", "MsiPath=$MsiPath",
    "-d", "Net8RuntimeUrl=$RuntimeUrl",
    "-d", "Net8RuntimeFile=$RuntimeFile",
    "-d", $embedDefine,
    "-ext", "WixToolset.BootstrapperApplications.wixext",
    "-ext", "WixToolset.Netfx.wixext",
    "-o", $Output
)

& $wixCommand.Executable @($wixCommand.PrefixArgs + $args)
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
