param(
    [string]$Version = "",
    [string]$BaseUrl = "https://example.com",
    [string]$SourceRoot = ""
)

. (Join-Path $PSScriptRoot "paths.ps1")
$paths = Get-CompilePaths -SourceRoot $SourceRoot

$root = $paths.SourceRoot
$distDir = Join-Path $paths.DistPath "MonitorSMS"

if (-not (Test-Path $distDir)) {
    Write-Error "dist\\MonitorSMS not found. Build the app first."
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

$zipName = "MonitorSMS-$Version.zip"
$zipPath = Join-Path $outDir $zipName
if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
}

Compress-Archive -Path (Join-Path $distDir "*") -DestinationPath $zipPath
$hash = (Get-FileHash -Algorithm SHA256 $zipPath).Hash.ToLower()

$manifest = @{
    version = $Version
    url = "$BaseUrl/$zipName"
    sha256 = $hash
} | ConvertTo-Json -Depth 3

$manifestPath = Join-Path $outDir "latest.json"
$manifest | Set-Content -Path $manifestPath -Encoding UTF8

Write-Host "Wrote $zipPath"
Write-Host "Wrote $manifestPath"
