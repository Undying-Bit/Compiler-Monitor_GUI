param(
    [string]$Version = "",
    [string]$BaseUrl = "https://example.com",
    [string]$SigningKeyPath = "",
    [string]$EntryExe = "MonitorSMS.exe",
    [string]$SourceRoot = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "paths.ps1")
$paths = Get-CompilePaths -SourceRoot $SourceRoot

$root = $paths.SourceRoot
$distDir = Join-Path $paths.DistPath "MonitorSMS"
$signerProject = Join-Path $PSScriptRoot "signer\MonitorSMSSigner.csproj"

if (-not (Test-Path $distDir)) {
    Write-Error "dist\\MonitorSMS not found. Build the app first."
    exit 1
}

if (-not (Test-Path $signerProject)) {
    Write-Error "Signer project not found: $signerProject"
    exit 1
}

if (-not $SigningKeyPath) {
    $SigningKeyPath = $env:MONITOR_UPDATE_SIGNING_KEY_PATH
}
if (-not $SigningKeyPath) {
    Write-Error "Signing key not configured. Set MONITOR_UPDATE_SIGNING_KEY_PATH or pass -SigningKeyPath."
    exit 1
}

try {
    $SigningKeyPath = (Resolve-Path $SigningKeyPath -ErrorAction Stop).Path
} catch {
    Write-Error "Signing key not found: $SigningKeyPath"
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

$outDir = $paths.ArtifactsPath
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$trimmedBaseUrl = $BaseUrl.TrimEnd("/")
$zipName = "MonitorSMS-$Version.zip"
$zipPath = Join-Path $outDir $zipName
$zipSignaturePath = "$zipPath.sig"
$manifestPath = Join-Path $outDir "latest.json"
$manifestSignaturePath = "$manifestPath.sig"

foreach ($artifact in @($zipPath, $zipSignaturePath, $manifestPath, $manifestSignaturePath)) {
    if (Test-Path $artifact) {
        Remove-Item $artifact -Force
    }
}

Compress-Archive -Path (Join-Path $distDir "*") -DestinationPath $zipPath
$hash = (Get-FileHash -Algorithm SHA256 $zipPath).Hash.ToLowerInvariant()
$signatureUrl = "$trimmedBaseUrl/$zipName.sig"

$manifest = @{
    version = $Version
    url = "$trimmedBaseUrl/$zipName"
    sha256 = $hash
    entry_exe = $EntryExe
    signature_url = $signatureUrl
} | ConvertTo-Json -Depth 3

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($manifestPath, $manifest + [Environment]::NewLine, $utf8NoBom)

$dotnetArgs = @(
    "run",
    "--project", $signerProject,
    "--",
    "sign",
    "--input", $zipPath,
    "--key", $SigningKeyPath,
    "--output", $zipSignaturePath
)
dotnet @dotnetArgs
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$dotnetArgs = @(
    "run",
    "--project", $signerProject,
    "--",
    "sign",
    "--input", $manifestPath,
    "--key", $SigningKeyPath,
    "--output", $manifestSignaturePath
)
dotnet @dotnetArgs
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host "Wrote $zipPath"
Write-Host "Wrote $zipSignaturePath"
Write-Host "Wrote $manifestPath"
Write-Host "Wrote $manifestSignaturePath"
