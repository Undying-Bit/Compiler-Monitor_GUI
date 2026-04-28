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
  . (Join-Path $context.PackagingRoot "channel.ps1")
  . (Join-Path $context.PackagingRoot "paths.ps1")

  $resolvedChannel = Resolve-MonitorChannel -Channel (Get-WrapperEnv -Name "MONITOR_RELEASE_CHANNEL")
  [Environment]::SetEnvironmentVariable("MONITOR_RELEASE_CHANNEL", $resolvedChannel, "Process")

  $channelArg = @("-Channel", $resolvedChannel)
  $paths = Get-CompilePaths -SourceRoot $SourceRoot
  $artifactPrefix = Get-ChannelArtifactPrefix -Channel $resolvedChannel

  $versionLine = Select-String -Path (Join-Path $paths.SourceRoot "pyproject.toml") -Pattern '^version\s*=' | Select-Object -First 1
  if (-not $versionLine) {
    throw "Unable to find version in pyproject.toml."
  }
  $version = ($versionLine.Line -replace 'version\s*=\s*"(.*)"', '$1').Trim()
  $versionArtifactsDir = Get-VersionArtifactsPath -ArtifactsRoot $paths.ArtifactsPath -Version $version -ArtifactPrefix $artifactPrefix

  $frameworkLauncherDir = Join-Path $paths.DistPath "MonitorSMSLauncher-framework-dependent"
  $selfContainedLauncherDir = Join-Path $paths.DistPath "MonitorSMSLauncher-selfcontained"
  $frameworkLauncherExe = Join-Path $frameworkLauncherDir "MonitorSMSLauncher.exe"
  $selfContainedLauncherExe = Join-Path $selfContainedLauncherDir "MonitorSMSLauncher.exe"

  $frameworkMsiPath = Join-Path $versionArtifactsDir ("${artifactPrefix}MonitorSMS-$version.msi")
  $selfContainedMsiPath = Join-Path $versionArtifactsDir ("${artifactPrefix}MonitorSMS-$version-selfcontained.msi")
  $downloadSetupPath = Join-Path $versionArtifactsDir ("${artifactPrefix}MonitorSMS-$version-setup-download-runtime.exe")
  $embeddedSetupPath = Join-Path $versionArtifactsDir ("${artifactPrefix}MonitorSMS-$version-setup-embedded-runtime.exe")

  Write-Host "Channel: $resolvedChannel"
  Write-Host "Version: $version"
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
  $launcherFrameworkArgs = @(
    "-FrameworkDependent",
    "-OutputDir", $frameworkLauncherDir,
    "-UpdateSigningPublicKeyPath", (Get-WrapperEnv -Name "MONITOR_UPDATE_SIGNING_PUBLIC_KEY_PATH")
  ) + $sourceArgs
  Invoke-PackagingScript -ScriptPath (Join-Path $context.PackagingRoot "build-launcher.ps1") -Arguments $launcherFrameworkArgs

  $updateArgs = @(
    "-BaseUrl", $updateBaseUrl,
    "-SigningKeyPath", (Get-WrapperEnv -Name "MONITOR_UPDATE_SIGNING_KEY_PATH")
  ) + $sourceArgs + $channelArg
  Invoke-PackagingScript -ScriptPath (Join-Path $context.PackagingRoot "make-update.ps1") -Arguments $updateArgs

  $msiArgs = @(
    "-ManifestUrl", (Get-WrapperEnv -Name "MONITOR_UPDATE_MANIFEST_URL"),
    "-PrimaryBaseUrl", (Get-WrapperEnv -Name "MONITOR_PRIMARY_BASE_URL")
  )
  $msiArgs = Add-OptionalArgFromEnv -Arguments $msiArgs -ParameterName "BackupBaseUrl" -EnvName "MONITOR_BACKUP_BASE_URL"
  $msiArgs = Add-OptionalArgFromEnv -Arguments $msiArgs -ParameterName "EstacionesKey" -EnvName "MONITOR_KEY_ESTACIONES"
  $msiArgs = Add-OptionalArgFromEnv -Arguments $msiArgs -ParameterName "ReportesKey" -EnvName "MONITOR_KEY_REPORTES"
  $msiArgs = Add-OptionalArgFromEnv -Arguments $msiArgs -ParameterName "DebugPanelVisible" -EnvName "MONITOR_DEBUG_PANEL_VISIBLE"

  $frameworkMsiArgs = @(
    "-LauncherExe", $frameworkLauncherExe,
    "-Output", $frameworkMsiPath
  ) + $msiArgs + $sourceArgs + $channelArg
  Invoke-PackagingScript -ScriptPath (Join-Path $context.PackagingRoot "build-msi.ps1") -Arguments $frameworkMsiArgs

  $launcherSelfContainedArgs = @(
    "-OutputDir", $selfContainedLauncherDir,
    "-UpdateSigningPublicKeyPath", (Get-WrapperEnv -Name "MONITOR_UPDATE_SIGNING_PUBLIC_KEY_PATH")
  ) + $sourceArgs
  Invoke-PackagingScript -ScriptPath (Join-Path $context.PackagingRoot "build-launcher.ps1") -Arguments $launcherSelfContainedArgs

  $selfContainedMsiArgs = @(
    "-AllowSelfContained",
    "-LauncherExe", $selfContainedLauncherExe,
    "-Output", $selfContainedMsiPath
  ) + $msiArgs + $sourceArgs + $channelArg
  Invoke-PackagingScript -ScriptPath (Join-Path $context.PackagingRoot "build-msi.ps1") -Arguments $selfContainedMsiArgs

  $runtimeSha256 = (Get-WrapperEnv -Name "MONITOR_NET8_RUNTIME_SHA256").Trim()
  $strictBundle = $resolvedChannel -eq "release"

  if (-not $runtimeSha256) {
    if ($strictBundle) {
      throw "MONITOR_NET8_RUNTIME_SHA256 is required for release bundle builds."
    }

    Write-Warning "MONITOR_NET8_RUNTIME_SHA256 is not set; skipping setup EXE bundle builds for development channel."
  } else {
    $bundleBaseArgs = @(
      "-MsiPath", $frameworkMsiPath,
      "-RuntimeSha256", $runtimeSha256
    ) + $sourceArgs + $channelArg

    $downloadBundleArgs = @(
      "-Output", $downloadSetupPath
    ) + $bundleBaseArgs

    $embeddedBundleArgs = @(
      "-EmbedNet8Runtime",
      "-Output", $embeddedSetupPath
    ) + $bundleBaseArgs

    try {
      Invoke-PackagingScript -ScriptPath (Join-Path $context.PackagingRoot "build-bundle.ps1") -Arguments $downloadBundleArgs
      Invoke-PackagingScript -ScriptPath (Join-Path $context.PackagingRoot "build-bundle.ps1") -Arguments $embeddedBundleArgs
    } catch {
      if ($strictBundle) {
        throw
      }

      Write-Warning "Setup EXE bundle build failed for development channel. Continuing with MSI artifacts only."
      Write-Warning $_
    }
  }

  $success = $true
} catch {
  $success = $false
  throw
} finally {
  Invoke-CompletionAlert -Success:$success
}
