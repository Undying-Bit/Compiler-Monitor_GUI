param(
    [string]$Configuration = "Release",
    [string]$Runtime = "win-x64",
    [string]$DotnetExe = "",
    [string]$SourceRoot = "",
    [string]$UpdateSigningPublicKeyPath = "",
    [switch]$FrameworkDependent
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "paths.ps1")
$paths = Get-CompilePaths -SourceRoot $SourceRoot

$root = $paths.SourceRoot
$project = Join-Path $PSScriptRoot "launcher\MonitorSMSLauncher.csproj"
$distDir = Join-Path $paths.DistPath "MonitorSMSLauncher"

if (-not (Test-Path $project)) {
    Write-Error "Launcher project not found: $project"
    exit 1
}

if (-not $DotnetExe) {
    $DotnetExe = "dotnet"
}

$sdkList = & $DotnetExe --list-sdks 2>$null
if (-not $sdkList) {
    Write-Error "dotnet SDK not found. Install .NET 8 SDK and retry."
    exit 1
}

$hasNet8 = ($sdkList | Where-Object { $_ -match '^\s*8\.' }).Count -gt 0
if (-not $hasNet8) {
    Write-Error @"
.NET 8 SDK not found. The launcher targets net8.0-windows and avoids the CET
error seen with .NET 10 on older Windows builds.

Install the .NET 8 SDK, then retry:
https://dotnet.microsoft.com/download/dotnet/8.0
"@
    exit 1
}

if (-not $UpdateSigningPublicKeyPath) {
    $UpdateSigningPublicKeyPath = $env:MONITOR_UPDATE_SIGNING_PUBLIC_KEY_PATH
}
if (-not $UpdateSigningPublicKeyPath) {
    Write-Error "Update signing public key not configured. Set MONITOR_UPDATE_SIGNING_PUBLIC_KEY_PATH or pass -UpdateSigningPublicKeyPath."
    exit 1
}

try {
    $UpdateSigningPublicKeyPath = (Resolve-Path $UpdateSigningPublicKeyPath -ErrorAction Stop).Path
} catch {
    Write-Error "Update signing public key not found: $UpdateSigningPublicKeyPath"
    exit 1
}

$line = Select-String -Path (Join-Path $root "pyproject.toml") -Pattern '^version\s*=' | Select-Object -First 1
if ($null -eq $line) {
    Write-Error "Unable to find version in pyproject.toml."
    exit 1
}
$version = ($line.Line -replace 'version\s*=\s*"(.*)"', '$1').Trim()

$numeric = ($version -split '[^0-9.]')[0]
if (-not $numeric) {
    $numeric = "0.0.0"
}
$parts = $numeric.Split('.') | Where-Object { $_ -ne "" }
while ($parts.Count -lt 4) {
    $parts += "0"
}
if ($parts.Count -gt 4) {
    $parts = $parts[0..3]
}
$assemblyVersion = ($parts -join '.')

$selfContained = (-not $FrameworkDependent).ToString().ToLower()

$args = @(
    "publish",
    $project,
    "-c", $Configuration,
    "-r", $Runtime,
    "-o", $distDir,
    "-p:PublishSingleFile=true",
    "-p:SelfContained=$selfContained",
    "-p:PublishTrimmed=false",
    "-p:Version=$version",
    "-p:AssemblyVersion=$assemblyVersion",
    "-p:FileVersion=$assemblyVersion",
    "-p:UpdateSigningPublicKeyFile=$UpdateSigningPublicKeyPath"
)

& $DotnetExe @args
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
