param(
  [string]$SourceRoot = "",
  [string]$LocalEnvPath = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")

$success = $false
try {
  $context = Initialize-PackagingWrapper -ScriptRoot $PSScriptRoot -LocalEnvPath $LocalEnvPath
  Assert-RequiredEnv -Names @(
    "MONITOR_UPDATE_SIGNING_PUBLIC_KEY_PATH",
    "MONITOR_UPDATE_SIGNING_KEY_PATH",
    "MONITOR_PRIMARY_BASE_URL",
    "MONITOR_UPDATE_MANIFEST_URL"
  )

  $updateBaseUrl = Resolve-UpdateBaseUrl
  if (-not $updateBaseUrl) {
    throw "MONITOR_UPDATE_BASE_URL is required. Set it directly or set MONITOR_UPDATE_MANIFEST_URL ending with /latest.json."
  }

  $sourceArgs = New-SourceArgs -SourceRoot $SourceRoot

  Invoke-PackagingScript -ScriptPath (Join-Path $context.PackagingRoot "build-app.ps1") -Arguments $sourceArgs
  $launcherArgs = @(
    "-FrameworkDependent",
    "-UpdateSigningPublicKeyPath", (Get-WrapperEnv -Name "MONITOR_UPDATE_SIGNING_PUBLIC_KEY_PATH")
  ) + $sourceArgs
  Invoke-PackagingScript -ScriptPath (Join-Path $context.PackagingRoot "build-launcher.ps1") -Arguments $launcherArgs

  $updateArgs = @(
    "-BaseUrl", $updateBaseUrl,
    "-SigningKeyPath", (Get-WrapperEnv -Name "MONITOR_UPDATE_SIGNING_KEY_PATH")
  ) + $sourceArgs
  Invoke-PackagingScript -ScriptPath (Join-Path $context.PackagingRoot "make-update.ps1") -Arguments $updateArgs

  $msiArgs = @(
    "-ManifestUrl", (Get-WrapperEnv -Name "MONITOR_UPDATE_MANIFEST_URL"),
    "-PrimaryBaseUrl", (Get-WrapperEnv -Name "MONITOR_PRIMARY_BASE_URL")
  )
  $msiArgs = Add-OptionalArgFromEnv -Arguments $msiArgs -ParameterName "BackupBaseUrl" -EnvName "MONITOR_BACKUP_BASE_URL"
  $msiArgs = Add-OptionalArgFromEnv -Arguments $msiArgs -ParameterName "EstacionesKey" -EnvName "MONITOR_KEY_ESTACIONES"
  $msiArgs = Add-OptionalArgFromEnv -Arguments $msiArgs -ParameterName "ReportesKey" -EnvName "MONITOR_KEY_REPORTES"
  $msiArgs = Add-OptionalArgFromEnv -Arguments $msiArgs -ParameterName "DebugPanelVisible" -EnvName "MONITOR_DEBUG_PANEL_VISIBLE"
  Invoke-PackagingScript -ScriptPath (Join-Path $context.PackagingRoot "build-msi.ps1") -Arguments @($msiArgs + $sourceArgs)

  $success = $true
} catch {
  $success = $false
  throw
} finally {
  Invoke-CompletionAlert -Success:$success
}
