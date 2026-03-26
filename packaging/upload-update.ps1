param(
    [string]$Endpoint = "",
    [string]$Bucket = "",
    [string]$AccessKey = "",
    [string]$SecretKey = "",
    [string]$Region = "",
    [string]$SessionToken = "",
    [Nullable[bool]]$UseSsl,
    [Nullable[bool]]$VerifyTls,
    [string]$Prefix = "",
    [string]$ArtifactsDir = "",
    [switch]$Force,
    [string]$SourceRoot = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "paths.ps1")
$paths = Get-CompilePaths -SourceRoot $SourceRoot
$compileRoot = $paths.CompileRoot

function Import-DotEnv {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return
    }
    foreach ($rawLine in Get-Content -Path $Path) {
        $line = $rawLine.Trim()
        if (-not $line) { continue }
        if ($line.StartsWith("#")) { continue }
        if ($line -notmatch "=") { continue }

        $parts = $line.Split("=", 2)
        $key = $parts[0].Trim()
        if (-not $key) { continue }
        if (Test-Path "env:$key") { continue }

        $value = $parts[1].Trim()
        if ($value.Length -ge 2) {
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        Set-Item -Path "Env:$key" -Value $value
    }
}

function Get-EnvBool {
    param(
        [string]$Name,
        [bool]$Default
    )
    $value = Get-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
    $value = if ($null -ne $value) { $value.Value } else { $null }
    if ($null -eq $value -or $value -eq "") {
        return $Default
    }
    $text = $value.ToString().Trim().ToLowerInvariant()
    return $text -in @("1", "true", "yes", "on")
}

function Require-Value {
    param(
        [string]$Value,
        [string]$EnvName,
        [string]$ParamName
    )
    if (-not $Value) {
        Write-Error "$ParamName is required. Set $EnvName or pass -$ParamName."
        exit 1
    }
}

Import-DotEnv (Join-Path $compileRoot ".env")
Import-DotEnv (Join-Path $PSScriptRoot ".env")

if (-not $ArtifactsDir) {
    $ArtifactsDir = $paths.ArtifactsPath
}
if (-not (Test-Path $ArtifactsDir)) {
    Write-Error "Artifacts directory not found: $ArtifactsDir"
    exit 1
}

$latestPath = Join-Path $ArtifactsDir "latest.json"
if (-not (Test-Path $latestPath)) {
    Write-Error "latest.json not found: $latestPath"
    exit 1
}

try {
    $manifest = Get-Content -Path $latestPath -Raw | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse latest.json: $_"
    exit 1
}

$version = [string]$manifest.version
if (-not $version) {
    Write-Error "latest.json is missing the version field."
    exit 1
}

$zipName = "MonitorSMS-$version.zip"
$zipPath = Join-Path $ArtifactsDir $zipName
if (-not (Test-Path $zipPath)) {
    Write-Error "Expected ZIP not found: $zipPath"
    exit 1
}

$url = [string]$manifest.url
if (-not $url) {
    Write-Error "latest.json is missing the url field."
    exit 1
}

$urlZipName = ""
try {
    $uri = [uri]$url
    $urlZipName = [System.IO.Path]::GetFileName($uri.AbsolutePath)
} catch {
    $urlZipName = ""
}
if (-not $urlZipName) {
    $urlZipName = ($url -split "\?")[0].Split("/")[-1]
}
if ($urlZipName -ne $zipName) {
    Write-Error "latest.json url does not end with $zipName (got $urlZipName)."
    exit 1
}

if (-not $Endpoint) { $Endpoint = $env:UPDATE_R2_ENDPOINT }
if (-not $Bucket) { $Bucket = $env:UPDATE_R2_BUCKET }
if (-not $AccessKey) { $AccessKey = $env:UPDATE_R2_ACCESS_KEY }
if (-not $SecretKey) { $SecretKey = $env:UPDATE_R2_SECRET_KEY }
if (-not $Region) { $Region = $env:UPDATE_R2_REGION }
if (-not $SessionToken) { $SessionToken = $env:UPDATE_R2_SESSION_TOKEN }
if (-not $Prefix) { $Prefix = $env:UPDATE_R2_PREFIX }

if ($PSBoundParameters.ContainsKey("UseSsl")) {
    $useSslValue = [bool]$UseSsl
} else {
    $useSslValue = Get-EnvBool "UPDATE_R2_USE_SSL" $true
}

if ($PSBoundParameters.ContainsKey("VerifyTls")) {
    $verifyTlsValue = [bool]$VerifyTls
} else {
    $verifyTlsValue = Get-EnvBool "UPDATE_R2_VERIFY_TLS" $true
}

Require-Value -Value $Endpoint -EnvName "UPDATE_R2_ENDPOINT" -ParamName "Endpoint"
Require-Value -Value $Bucket -EnvName "UPDATE_R2_BUCKET" -ParamName "Bucket"
Require-Value -Value $AccessKey -EnvName "UPDATE_R2_ACCESS_KEY" -ParamName "AccessKey"
Require-Value -Value $SecretKey -EnvName "UPDATE_R2_SECRET_KEY" -ParamName "SecretKey"

if (-not $Force) {
    Write-Host "This will DELETE ALL objects in bucket '$Bucket' at '$Endpoint'." -ForegroundColor Yellow
    if ($Prefix) {
        Write-Host "Uploads will use prefix '$Prefix', but purge affects the entire bucket." -ForegroundColor Yellow
    }
    $confirmation = Read-Host "Type DELETE to continue"
    if ($confirmation -ne "DELETE") {
        Write-Host "Aborted."
        exit 1
    }
}

$python = Join-Path $paths.SourceRoot ".venv\\Scripts\\python.exe"
if (-not (Test-Path $python)) {
    $python = "python"
}

$helper = Join-Path $PSScriptRoot "upload_update.py"
if (-not (Test-Path $helper)) {
    Write-Error "Helper not found: $helper"
    exit 1
}

$argsList = @(
    $helper,
    "--endpoint", $Endpoint,
    "--bucket", $Bucket,
    "--access-key", $AccessKey,
    "--secret-key", $SecretKey,
    "--use-ssl", $useSslValue.ToString().ToLowerInvariant(),
    "--verify-tls", $verifyTlsValue.ToString().ToLowerInvariant(),
    "--latest", $latestPath,
    "--zip", $zipPath
)

if ($Region) {
    $argsList += @("--region", $Region)
}
if ($SessionToken) {
    $argsList += @("--session-token", $SessionToken)
}
if ($Prefix) {
    $argsList += @("--prefix", $Prefix)
}

& $python @argsList
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host "Upload complete."

