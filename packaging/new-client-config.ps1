param(
    [string]$OutputPath = "",
    [string]$ManifestUrl = "",
    [string]$PrimaryBaseUrl = "",
    [string]$BackupBaseUrl = "",
    [string]$EstacionesKey = "",
    [string]$ReportesKey = "",
    [string]$DebugPanelVisible = ""
)

$ErrorActionPreference = "Stop"

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

if (-not $OutputPath) {
    $compileRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
    $OutputPath = Join-Path $compileRoot ".tmp\client-config\.env"
}

$resolvedManifestUrl = Get-ResolvedValue -ExplicitValue $ManifestUrl -EnvName "MONITOR_UPDATE_MANIFEST_URL"
$resolvedPrimaryBaseUrl = Get-ResolvedValue -ExplicitValue $PrimaryBaseUrl -EnvName "MONITOR_PRIMARY_BASE_URL"
$resolvedBackupBaseUrl = Get-ResolvedValue -ExplicitValue $BackupBaseUrl -EnvName "MONITOR_BACKUP_BASE_URL"
$resolvedEstacionesKey = Get-ResolvedValue -ExplicitValue $EstacionesKey -EnvName "MONITOR_KEY_ESTACIONES" -DefaultValue "estaciones.db"
$resolvedReportesKey = Get-ResolvedValue -ExplicitValue $ReportesKey -EnvName "MONITOR_KEY_REPORTES" -DefaultValue "reportes.db"

if ($PSBoundParameters.ContainsKey("DebugPanelVisible")) {
    $resolvedDebugPanelVisible = ConvertTo-BoolText -Value $DebugPanelVisible -Name "DebugPanelVisible"
} else {
    $debugPanelEnv = Get-ResolvedValue -ExplicitValue "" -EnvName "MONITOR_DEBUG_PANEL_VISIBLE" -DefaultValue "false"
    $resolvedDebugPanelVisible = ConvertTo-BoolText -Value $debugPanelEnv -Name "MONITOR_DEBUG_PANEL_VISIBLE"
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
    "MONITOR_PRIMARY_BASE_URL=$resolvedPrimaryBaseUrl"
    "MONITOR_BACKUP_BASE_URL=$resolvedBackupBaseUrl"
    "MONITOR_KEY_ESTACIONES=$resolvedEstacionesKey"
    "MONITOR_KEY_REPORTES=$resolvedReportesKey"
    "MONITOR_UPDATE_MANIFEST_URL=$resolvedManifestUrl"
    "MONITOR_DEBUG_PANEL_VISIBLE=$resolvedDebugPanelVisible"
)

$lines | Set-Content -Path $OutputPath -Encoding UTF8
Write-Host "Wrote sanitized client config to $OutputPath"
