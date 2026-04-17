param(
    [string]$Version = "",
    [string]$MsiPath = "",
    [string]$Output = "",
    [string]$SourceRoot = "",
    [string]$RuntimeUrl = "",
    [string]$RuntimeFile = "",
    [string]$RuntimeSha256 = "",
    [switch]$EmbedNet8Runtime
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "paths.ps1")
$paths = Get-CompilePaths -SourceRoot $SourceRoot

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
    $MsiPath = Join-Path $paths.ArtifactsPath "MonitorSMS-$Version.msi"
}

if (-not (Test-Path $MsiPath)) {
    & (Join-Path $PSScriptRoot "build-msi.ps1") -Version $Version -Output $MsiPath -SourceRoot $SourceRoot
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

if (-not $Output) {
    $Output = Join-Path $paths.ArtifactsPath "MonitorSMS-$Version-setup.exe"
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

$embedDefine = "EmbedNet8Runtime=" + ($(if ($EmbedNet8Runtime) { "yes" } else { "no" }))

$args = @(
    "build",
    $bundleWxs,
    "-d", "Version=$Version",
    "-d", "MsiPath=$MsiPath",
    "-d", "Net8RuntimeUrl=$RuntimeUrl",
    "-d", "Net8RuntimeFile=$RuntimeFile",
    "-d", $embedDefine,
    "-ext", "WixToolset.Bal.wixext",
    "-ext", "WixToolset.NetCore.wixext",
    "-o", $Output
)

& $wixCommand.Executable @($wixCommand.PrefixArgs + $args)
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
