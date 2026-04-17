$ErrorActionPreference = "Stop"

function Initialize-PackagingWrapper {
  param(
    [string]$ScriptRoot,
    [string]$LocalEnvPath = ""
  )

  $packagingRoot = Split-Path -Parent $ScriptRoot
  $repoRoot = Split-Path -Parent $packagingRoot
  Set-Location -Path $repoRoot

  if (-not $LocalEnvPath) {
    $LocalEnvPath = Join-Path $packagingRoot "local.env"
  }

  Import-LocalEnv -Path $LocalEnvPath

  return [pscustomobject]@{
    PackagingRoot = $packagingRoot
    RepoRoot = $repoRoot
    LocalEnvPath = $LocalEnvPath
  }
}

function Import-LocalEnv {
  param(
    [string]$Path
  )

  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
    return
  }

  foreach ($raw in Get-Content -LiteralPath $Path) {
    $line = $raw.Trim()
    if ($line.Length -eq 0 -or $line.StartsWith("#")) {
      continue
    }

    $idx = $line.IndexOf("=")
    if ($idx -le 0) {
      throw "Invalid local env line in ${Path}: expected KEY=value."
    }

    $name = $line.Substring(0, $idx).Trim()
    $value = $line.Substring($idx + 1).Trim()
    if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
      throw "Invalid local env variable name in ${Path}: $name"
    }

    if ($value.Length -ge 2) {
      $value = ($value -replace '\s+#.*$', '').Trim()
      if ($value.Length -ge 2) {
        $first = $value.Substring(0, 1)
        $last = $value.Substring($value.Length - 1, 1)
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
          $value = $value.Substring(1, $value.Length - 2)
        }
      }
    }

    $existing = [Environment]::GetEnvironmentVariable($name, "Process")
    if ([string]::IsNullOrWhiteSpace($existing)) {
      [Environment]::SetEnvironmentVariable($name, $value, "Process")
    }
  }
}

function Get-WrapperEnv {
  param(
    [string]$Name
  )

  $value = [Environment]::GetEnvironmentVariable($Name, "Process")
  if ($null -eq $value) {
    return ""
  }

  return [string]$value
}

function Test-WrapperEnvPresent {
  param(
    [string]$Name
  )

  return -not [string]::IsNullOrWhiteSpace((Get-WrapperEnv -Name $Name))
}

function Assert-RequiredEnv {
  param(
    [string[]]$Names
  )

  $missing = @()
  foreach ($name in $Names) {
    if (-not (Test-WrapperEnvPresent -Name $name)) {
      $missing += $name
    }
  }

  if ($missing.Count -gt 0) {
    $joined = $missing -join ", "
    throw "Missing required configuration: $joined. Set these in the process environment or packaging\local.env."
  }
}

function Resolve-UpdateBaseUrl {
  $baseUrl = (Get-WrapperEnv -Name "MONITOR_UPDATE_BASE_URL").Trim()
  if ($baseUrl) {
    return $baseUrl.TrimEnd("/")
  }

  $manifestUrl = (Get-WrapperEnv -Name "MONITOR_UPDATE_MANIFEST_URL").Trim()
  if (-not $manifestUrl) {
    return ""
  }

  if ($manifestUrl -notmatch '/latest\.json$') {
    throw "MONITOR_UPDATE_BASE_URL is required because MONITOR_UPDATE_MANIFEST_URL does not end with /latest.json."
  }

  $derived = $manifestUrl.Substring(0, $manifestUrl.Length - "/latest.json".Length).TrimEnd("/")
  [Environment]::SetEnvironmentVariable("MONITOR_UPDATE_BASE_URL", $derived, "Process")
  return $derived
}

function New-SourceArgs {
  param(
    [string]$SourceRoot = ""
  )

  if ($SourceRoot) {
    return @("-SourceRoot", $SourceRoot)
  }

  return @()
}

function Add-OptionalArgFromEnv {
  param(
    [object[]]$Arguments,
    [string]$ParameterName,
    [string]$EnvName
  )

  $value = Get-WrapperEnv -Name $EnvName
  if ([string]::IsNullOrWhiteSpace($value)) {
    return $Arguments
  }

  return @($Arguments + @("-$ParameterName", $value))
}

function Invoke-PackagingScript {
  param(
    [string]$ScriptPath,
    [object[]]$Arguments = @()
  )

  Write-Host ""
  Write-Host ">>> $ScriptPath $($Arguments -join ' ')"
  powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code ${LASTEXITCODE}: $ScriptPath"
  }
}

function Register-CompletionAlertType {
  if ("Win32Flash" -as [type]) {
    return
  }

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32Flash {
  [StructLayout(LayoutKind.Sequential)]
  public struct FLASHWINFO {
    public UInt32 cbSize;
    public IntPtr hwnd;
    public UInt32 dwFlags;
    public UInt32 uCount;
    public UInt32 dwTimeout;
  }
  [DllImport("user32.dll")]
  public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);
}
"@
}

function Invoke-WindowFlash {
  param(
    [int]$Count = 6
  )

  try {
    Register-CompletionAlertType
    $hwnd = (Get-Process -Id $pid).MainWindowHandle
    if ($hwnd -ne [IntPtr]::Zero) {
      $info = New-Object Win32Flash+FLASHWINFO
      $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($info)
      $info.hwnd = $hwnd
      $info.dwFlags = 3
      $info.uCount = [uint32]$Count
      $info.dwTimeout = 0
      [Win32Flash]::FlashWindowEx([ref]$info) | Out-Null
    }
  } catch {
  }
}

function Invoke-CompletionAlert {
  param(
    [bool]$Success
  )

  try {
    if ($Success) {
      [console]::Beep(880, 250)
      Start-Sleep -Milliseconds 120
      [console]::Beep(1175, 250)
    } else {
      [console]::Beep(300, 600)
    }
  } catch {
  }

  Invoke-WindowFlash
}
