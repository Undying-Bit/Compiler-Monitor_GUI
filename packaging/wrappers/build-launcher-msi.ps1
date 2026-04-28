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
  Assert-RequiredEnv -Names @("MONITOR_UPDATE_SIGNING_PUBLIC_KEY_PATH")

  $sourceArgs = New-SourceArgs -SourceRoot $SourceRoot
  $launcherArgs = @(
    "-FrameworkDependent",
    "-UpdateSigningPublicKeyPath", (Get-WrapperEnv -Name "MONITOR_UPDATE_SIGNING_PUBLIC_KEY_PATH")
  ) + $sourceArgs
  Invoke-PackagingScript -ScriptPath (Join-Path $context.PackagingRoot "build-launcher.ps1") -Arguments $launcherArgs

  $success = $true
} catch {
  $success = $false
  throw
} finally {
  Invoke-CompletionAlert -Success:$success
}
