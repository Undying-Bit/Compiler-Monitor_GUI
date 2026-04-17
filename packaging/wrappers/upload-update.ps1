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
    "UPDATE_R2_ENDPOINT",
    "UPDATE_R2_BUCKET",
    "UPDATE_R2_ACCESS_KEY",
    "UPDATE_R2_SECRET_KEY"
  )

  $uploadArgs = New-SourceArgs -SourceRoot $SourceRoot
  Invoke-PackagingScript -ScriptPath (Join-Path $context.PackagingRoot "upload-update.ps1") -Arguments $uploadArgs

  $success = $true
} catch {
  $success = $false
  throw
} finally {
  Invoke-CompletionAlert -Success:$success
}
