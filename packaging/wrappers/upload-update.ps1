param(
  [string]$SourceRoot = "",
  [string]$LocalEnvPath = "",
  [string]$Channel = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")

$success = $false
try {
  if ($Channel) {
    [Environment]::SetEnvironmentVariable("MONITOR_RELEASE_CHANNEL", $Channel, "Process")
  }
  $context = Initialize-PackagingWrapper -ScriptRoot $PSScriptRoot -LocalEnvPath $LocalEnvPath -Channel $Channel
  Assert-RequiredEnv -Names @(
    "UPDATE_R2_ENDPOINT",
    "UPDATE_R2_ACCESS_KEY",
    "UPDATE_R2_SECRET_KEY"
  )

  $uploadArgs = New-SourceArgs -SourceRoot $SourceRoot
  $resolvedChannel = (Get-WrapperEnv -Name "MONITOR_RELEASE_CHANNEL").Trim()
  if ($resolvedChannel) {
    $uploadArgs += @("-Channel", $resolvedChannel)
  }
  Invoke-PackagingScript -ScriptPath (Join-Path $context.PackagingRoot "upload-update.ps1") -Arguments $uploadArgs

  $success = $true
} catch {
  $success = $false
  throw
} finally {
  Invoke-CompletionAlert -Success:$success
}
