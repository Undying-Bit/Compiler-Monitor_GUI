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
    [string]$SourceRoot = "",
    [string]$Channel = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "paths.ps1")
. (Join-Path $PSScriptRoot "channel.ps1")
$paths = Get-CompilePaths -SourceRoot $SourceRoot
$resolvedChannel = Resolve-MonitorChannel -Channel $Channel
$artifactPrefix = Get-ChannelArtifactPrefix -Channel $resolvedChannel
$artifactNamePrefix = Get-ChannelArtifactNamePrefix -Channel $resolvedChannel

function Get-EnvBool {
    param(
        [string]$Name,
        [bool]$Default
    )
    $value = [Environment]::GetEnvironmentVariable($Name, "Process")
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

if (-not $ArtifactsDir) {
    $versionLine = Select-String -Path (Join-Path $paths.SourceRoot "pyproject.toml") -Pattern '^version\s*=' | Select-Object -First 1
    if (-not $versionLine) {
        Write-Error "Unable to find version in pyproject.toml."
        exit 1
    }
    $version = ($versionLine.Line -replace 'version\s*=\s*"(.*)"', '$1').Trim()
    $ArtifactsDir = Get-VersionArtifactsPath -ArtifactsRoot $paths.ArtifactsPath -Version $version -ArtifactPrefix $artifactPrefix
}
if (-not (Test-Path $ArtifactsDir)) {
    Write-Error "Artifacts directory not found: $ArtifactsDir"
    exit 1
}

$latestPath = Join-Path $ArtifactsDir "latest.json"
$latestSigPath = "$latestPath.sig"
if (-not (Test-Path $latestPath)) {
    Write-Error "latest.json not found: $latestPath"
    exit 1
}
if (-not (Test-Path $latestSigPath)) {
    Write-Error "latest.json.sig not found: $latestSigPath"
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

$zipName = "$artifactNamePrefix$version.zip"
$zipPath = Join-Path $ArtifactsDir $zipName
$zipSigPath = "$zipPath.sig"
if (-not (Test-Path $zipPath)) {
    Write-Error "Expected ZIP not found: $zipPath"
    exit 1
}
if (-not (Test-Path $zipSigPath)) {
    Write-Error "Expected ZIP signature not found: $zipSigPath"
    exit 1
}

$url = [string]$manifest.url
if (-not $url) {
    Write-Error "latest.json is missing the url field."
    exit 1
}

$signatureUrl = [string]$manifest.signature_url
if (-not $signatureUrl) {
    Write-Error "latest.json is missing the signature_url field."
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

if (-not $signatureUrl.EndsWith("$zipName.sig")) {
    Write-Error "latest.json signature_url does not end with $zipName.sig."
    exit 1
}

$appPath = $null
$appSigPath = $null
$runtimeId = [string]$manifest.runtime_id
$appUrl = [string]$manifest.app_url
$appSignatureUrl = [string]$manifest.app_signature_url
if ($runtimeId -or $appUrl -or $appSignatureUrl) {
    if (-not $runtimeId) {
        Write-Error "latest.json app-only fields are incomplete: runtime_id is required when publishing an app-only ZIP."
        exit 1
    }
    if (-not $appUrl) {
        Write-Error "latest.json app-only fields are incomplete: app_url is required when publishing an app-only ZIP."
        exit 1
    }
    if (-not $appSignatureUrl) {
        Write-Error "latest.json app-only fields are incomplete: app_signature_url is required when publishing an app-only ZIP."
        exit 1
    }

    $appName = "$artifactNamePrefix$version-app.zip"
    $appPath = Join-Path $ArtifactsDir $appName
    $appSigPath = "$appPath.sig"
    if (-not (Test-Path $appPath)) {
        Write-Error "Expected app-only ZIP not found: $appPath"
        exit 1
    }
    if (-not (Test-Path $appSigPath)) {
        Write-Error "Expected app-only ZIP signature not found: $appSigPath"
        exit 1
    }

    $urlAppName = ""
    try {
        $appUri = [uri]$appUrl
        $urlAppName = [System.IO.Path]::GetFileName($appUri.AbsolutePath)
    } catch {
        $urlAppName = ""
    }
    if (-not $urlAppName) {
        $urlAppName = ($appUrl -split "\?")[0].Split("/")[-1]
    }
    if ($urlAppName -ne $appName) {
        Write-Error "latest.json app_url does not end with $appName (got $urlAppName)."
        exit 1
    }

    if (-not $appSignatureUrl.EndsWith("$appName.sig")) {
        Write-Error "latest.json app_signature_url does not end with $appName.sig."
        exit 1
    }
}

if (-not $Endpoint) { $Endpoint = $env:UPDATE_R2_ENDPOINT }
if (-not $Bucket) { $Bucket = $env:UPDATE_R2_BUCKET }
if (-not $AccessKey) { $AccessKey = $env:UPDATE_R2_ACCESS_KEY }
if (-not $SecretKey) { $SecretKey = $env:UPDATE_R2_SECRET_KEY }
if (-not $Region) { $Region = $env:UPDATE_R2_REGION }
if (-not $SessionToken) { $SessionToken = $env:UPDATE_R2_SESSION_TOKEN }
if (-not $Prefix) { $Prefix = $env:UPDATE_R2_PREFIX }
if (-not $Bucket) { $Bucket = Get-ChannelUpdateBucket -Channel $resolvedChannel }

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

Write-Host "Using channel '$resolvedChannel' with artifact prefix '$artifactPrefix' and bucket '$Bucket'"

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
    "--latest-sig", $latestSigPath,
    "--zip", $zipPath,
    "--zip-sig", $zipSigPath
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
if ($artifactPrefix) {
    $argsList += @("--artifact-prefix", $artifactPrefix)
}
if ($appPath -and $appSigPath) {
    $argsList += @("--app", $appPath, "--app-sig", $appSigPath)
}

& $python @argsList
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host "Upload complete."
