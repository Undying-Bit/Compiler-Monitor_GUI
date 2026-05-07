param(
    [string]$OutputPath = "",
    [string]$Channel = "",
    [string]$ManifestUrl = "",
    [string]$PrimaryBaseUrl = "",
    [string]$BackupBaseUrl = "",
    [string]$EstacionesKey = "",
    [string]$ReportesKey = "",
    [string]$DebugPanelVisible = "",
    [string]$LocalDataSubdir = "",
    [string]$UpdateArtifactPrefix = "",
    [string]$TelemetryEnabled = "",
    [string]$TelemetryEndpoint = "",
    [string]$TelemetryApiKey = "",
    [string]$TelemetryBatchSize = "",
    [string]$TelemetryTimeoutSeconds = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "channel.ps1")

function Get-ResolvedValue {
    param(
        [string]$ExplicitValue,
        [string]$EnvName,
        [string]$DefaultValue = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitValue)) {
        return $ExplicitValue
    }

    $item = Get-Item -Path "Env:$EnvName" -ErrorAction SilentlyContinue
    if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace($item.Value)) {
        return [string]$item.Value
    }

    return $DefaultValue
}

function ConvertTo-BoolText {
    param(
        [object]$Value,
        [string]$Name
    )

    if ($Value -is [bool]) {
        return $Value.ToString().ToLowerInvariant()
    }

    $text = ([string]$Value).Trim()
    switch -Regex ($text) {
        '^(?i:true|1)$' { return "true" }
        '^(?i:false|0)$' { return "false" }
    }

    Write-Error "$Name must be a boolean value: true, false, 1, or 0."
    exit 1
}

function ConvertTo-PositiveIntText {
    param(
        [object]$Value,
        [string]$Name
    )

    $text = ([string]$Value).Trim()
    $parsed = 0
    if ([int]::TryParse($text, [ref]$parsed) -and $parsed -gt 0) {
        return $parsed.ToString()
    }

    Write-Error "$Name must be a positive integer."
    exit 1
}

if (-not $OutputPath) {
    $compileRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
    $OutputPath = Join-Path $compileRoot ".tmp\client-config\.env"
}

$resolvedChannel = Resolve-MonitorChannel -Channel $Channel
$resolvedManifestUrl = Get-ResolvedValue -ExplicitValue $ManifestUrl -EnvName "MONITOR_UPDATE_MANIFEST_URL"
$resolvedPrimaryBaseUrl = Get-ResolvedValue -ExplicitValue $PrimaryBaseUrl -EnvName "MONITOR_PRIMARY_BASE_URL"
$resolvedBackupBaseUrl = Get-ResolvedValue -ExplicitValue $BackupBaseUrl -EnvName "MONITOR_BACKUP_BASE_URL"
$resolvedEstacionesKey = Get-ResolvedValue -ExplicitValue $EstacionesKey -EnvName "MONITOR_KEY_ESTACIONES" -DefaultValue "estaciones.db"
$resolvedReportesKey = Get-ResolvedValue -ExplicitValue $ReportesKey -EnvName "MONITOR_KEY_REPORTES" -DefaultValue "reportes.db"
$defaultLocalDataSubdir = Get-ChannelLocalDataSubdir -Channel $resolvedChannel
$resolvedLocalDataSubdir = Get-ResolvedValue -ExplicitValue $LocalDataSubdir -EnvName "MONITOR_LOCAL_DATA_SUBDIR" -DefaultValue $defaultLocalDataSubdir
$defaultArtifactPrefix = Get-ChannelArtifactPrefix -Channel $resolvedChannel
$resolvedUpdateArtifactPrefix = Get-ResolvedValue -ExplicitValue $UpdateArtifactPrefix -EnvName "MONITOR_UPDATE_ARTIFACT_PREFIX" -DefaultValue $defaultArtifactPrefix
$resolvedTelemetryEndpoint = Get-ResolvedValue -ExplicitValue $TelemetryEndpoint -EnvName "MONITOR_TELEMETRY_ENDPOINT"
$resolvedTelemetryApiKey = Get-ResolvedValue -ExplicitValue $TelemetryApiKey -EnvName "MONITOR_TELEMETRY_API_KEY"

if ($PSBoundParameters.ContainsKey("DebugPanelVisible")) {
    $resolvedDebugPanelVisible = ConvertTo-BoolText -Value $DebugPanelVisible -Name "DebugPanelVisible"
} else {
    $debugPanelEnv = Get-ResolvedValue -ExplicitValue "" -EnvName "MONITOR_DEBUG_PANEL_VISIBLE" -DefaultValue "false"
    $resolvedDebugPanelVisible = ConvertTo-BoolText -Value $debugPanelEnv -Name "MONITOR_DEBUG_PANEL_VISIBLE"
}

if ($PSBoundParameters.ContainsKey("TelemetryEnabled")) {
    $resolvedTelemetryEnabled = ConvertTo-BoolText -Value $TelemetryEnabled -Name "TelemetryEnabled"
} else {
    $telemetryEnabledEnv = Get-ResolvedValue -ExplicitValue "" -EnvName "MONITOR_TELEMETRY_ENABLED" -DefaultValue "false"
    $resolvedTelemetryEnabled = ConvertTo-BoolText -Value $telemetryEnabledEnv -Name "MONITOR_TELEMETRY_ENABLED"
}

if ($PSBoundParameters.ContainsKey("TelemetryBatchSize")) {
    $resolvedTelemetryBatchSize = ConvertTo-PositiveIntText -Value $TelemetryBatchSize -Name "TelemetryBatchSize"
} else {
    $telemetryBatchSizeEnv = Get-ResolvedValue -ExplicitValue "" -EnvName "MONITOR_TELEMETRY_BATCH_SIZE" -DefaultValue "10"
    $resolvedTelemetryBatchSize = ConvertTo-PositiveIntText -Value $telemetryBatchSizeEnv -Name "MONITOR_TELEMETRY_BATCH_SIZE"
}

if ($PSBoundParameters.ContainsKey("TelemetryTimeoutSeconds")) {
    $resolvedTelemetryTimeoutSeconds = ConvertTo-PositiveIntText -Value $TelemetryTimeoutSeconds -Name "TelemetryTimeoutSeconds"
} else {
    $telemetryTimeoutEnv = Get-ResolvedValue -ExplicitValue "" -EnvName "MONITOR_TELEMETRY_TIMEOUT_SECONDS" -DefaultValue "4"
    $resolvedTelemetryTimeoutSeconds = ConvertTo-PositiveIntText -Value $telemetryTimeoutEnv -Name "MONITOR_TELEMETRY_TIMEOUT_SECONDS"
}

if ([string]::IsNullOrWhiteSpace($resolvedManifestUrl)) {
    Write-Error "MONITOR_UPDATE_MANIFEST_URL is required. Set it in the environment or pass -ManifestUrl."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($resolvedPrimaryBaseUrl)) {
    Write-Error "MONITOR_PRIMARY_BASE_URL is required. Set it in the environment or pass -PrimaryBaseUrl."
    exit 1
}

$outputDir = Split-Path -Parent $OutputPath
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$lines = @(
    "MONITOR_CHANNEL=$resolvedChannel"
    "MONITOR_LOCAL_DATA_SUBDIR=$resolvedLocalDataSubdir"
    "MONITOR_UPDATE_ARTIFACT_PREFIX=$resolvedUpdateArtifactPrefix"
    "MONITOR_PRIMARY_BASE_URL=$resolvedPrimaryBaseUrl"
    "MONITOR_BACKUP_BASE_URL=$resolvedBackupBaseUrl"
    "MONITOR_KEY_ESTACIONES=$resolvedEstacionesKey"
    "MONITOR_KEY_REPORTES=$resolvedReportesKey"
    "MONITOR_UPDATE_MANIFEST_URL=$resolvedManifestUrl"
    "MONITOR_DEBUG_PANEL_VISIBLE=$resolvedDebugPanelVisible"
    "MONITOR_TELEMETRY_ENABLED=$resolvedTelemetryEnabled"
    "MONITOR_TELEMETRY_ENDPOINT=$resolvedTelemetryEndpoint"
    "MONITOR_TELEMETRY_API_KEY=$resolvedTelemetryApiKey"
    "MONITOR_TELEMETRY_BATCH_SIZE=$resolvedTelemetryBatchSize"
    "MONITOR_TELEMETRY_TIMEOUT_SECONDS=$resolvedTelemetryTimeoutSeconds"
)

$lines | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host "Wrote sanitized client config to $OutputPath"
