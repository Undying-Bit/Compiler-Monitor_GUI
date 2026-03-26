param(
  [string]$SourceRoot = ""
)

$ErrorActionPreference = "Stop"

# Run from the repo root (one level above /packaging).
$packagingRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $packagingRoot
Set-Location -Path $repoRoot

if (-not ("Win32Flash" -as [type])) {
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
    $hwnd = (Get-Process -Id $pid).MainWindowHandle
    if ($hwnd -ne [IntPtr]::Zero) {
      $info = New-Object Win32Flash+FLASHWINFO
      $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($info)
      $info.hwnd = $hwnd
      $info.dwFlags = 3  # FLASHW_ALL
      $info.uCount = [uint32]$Count
      $info.dwTimeout = 0
      [Win32Flash]::FlashWindowEx([ref]$info) | Out-Null
    }
  } catch {
    # Non-fatal: flashing is best-effort.
  }
}

function Invoke-CompletionAlert {
  param(
    [bool]$Success
  )
  if ($Success) {
    [console]::Beep(880, 250)
    Start-Sleep -Milliseconds 120
    [console]::Beep(1175, 250)
  } else {
    [console]::Beep(300, 600)
  }
  Invoke-WindowFlash
}

$success = $false
try {
  $sourceArgs = @()
  if ($SourceRoot) {
    $sourceArgs = @("-SourceRoot", $SourceRoot)
  }
  powershell -ExecutionPolicy Bypass -File (Join-Path $packagingRoot "upload-update.ps1") @sourceArgs
  $success = $true
} catch {
  $success = $false
  throw
} finally {
  Invoke-CompletionAlert -Success:$success
}
