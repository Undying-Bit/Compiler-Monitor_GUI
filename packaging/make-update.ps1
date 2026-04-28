param(
    [string]$Version = "",
    [string]$BaseUrl = "https://example.com",
    [string]$SigningKeyPath = "",
    [string]$EntryExe = "MonitorSMS.exe",
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

function Get-RelativePath {
    param(
        [string]$RootPath,
        [string]$TargetPath
    )

    $normalizedRoot = [System.IO.Path]::GetFullPath($RootPath)
    $normalizedTarget = [System.IO.Path]::GetFullPath($TargetPath)
    if (-not $normalizedRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $normalizedRoot += [System.IO.Path]::DirectorySeparatorChar
    }

    $rootUri = [System.Uri]$normalizedRoot
    $targetUri = [System.Uri]$normalizedTarget
    return [System.Uri]::UnescapeDataString($rootUri.MakeRelativeUri($targetUri).ToString()).Replace('\', '/')
}

function Write-Utf8NoBomFile {
    param(
        [string]$Path,
        [string]$Content
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Invoke-Signer {
    param(
        [string]$SignerProjectPath,
        [string]$InputPath,
        [string]$KeyPath,
        [string]$OutputPath
    )

    $dotnetArgs = @(
        "run",
        "--project", $SignerProjectPath,
        "--",
        "sign",
        "--input", $InputPath,
        "--key", $KeyPath,
        "--output", $OutputPath
    )
    dotnet @dotnetArgs
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

function Get-RuntimeInventory {
    param([string]$AppRoot)

    $runtimeRoot = Join-Path $AppRoot "_internal"
    if (-not (Test-Path $runtimeRoot)) {
        throw "Runtime folder not found: $runtimeRoot"
    }

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($file in Get-ChildItem -Path $runtimeRoot -File -Recurse) {
        $relativePath = Get-RelativePath -RootPath $AppRoot -TargetPath $file.FullName
        if (
            $relativePath.StartsWith("_internal/station_monitor_assets/", [System.StringComparison]::OrdinalIgnoreCase) -or
            $relativePath.Equals("_internal/base_library.zip", [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            continue
        }

        $entries.Add([pscustomobject]@{
            RelativePath = $relativePath
            Sha256       = (Get-FileHash -Algorithm SHA256 $file.FullName).Hash.ToLowerInvariant()
        })
    }

    return $entries | Sort-Object RelativePath
}

function Get-RuntimeId {
    param([string]$AppRoot)

    $runtimeEntries = Get-RuntimeInventory -AppRoot $AppRoot
    $builder = New-Object System.Text.StringBuilder
    foreach ($entry in $runtimeEntries) {
        [void]$builder.Append($entry.RelativePath)
        [void]$builder.Append([char]0)
        [void]$builder.Append($entry.Sha256)
        [void]$builder.Append("`n")
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($builder.ToString())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return [System.BitConverter]::ToString($hash).Replace("-", "").ToLowerInvariant()
}

function New-AppOnlyArtifact {
    param(
        [string]$AppRoot,
        [string]$Version,
        [string]$ArtifactsPath,
        [string]$TrimmedBaseUrl,
        [string]$SignerProjectPath,
        [string]$KeyPath,
        [string]$EntryExeName,
        [string]$ArtifactNamePrefix
    )

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("monitor_app_only_" + [System.Guid]::NewGuid().ToString("N"))
    $packageRoot = Join-Path $tempRoot "app"
    $appZipName = "$ArtifactNamePrefix$Version-app.zip"
    $appZipPath = Join-Path $ArtifactsPath $appZipName
    $appSignaturePath = "$appZipPath.sig"

    try {
        if (Test-Path $appZipPath) {
            Remove-Item $appZipPath -Force
        }
        if (Test-Path $appSignaturePath) {
            Remove-Item $appSignaturePath -Force
        }

        New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
        $sourceExe = Join-Path $AppRoot $EntryExeName
        if (-not (Test-Path $sourceExe)) {
            throw "App entry executable not found: $sourceExe"
        }

        Copy-Item -Path $sourceExe -Destination (Join-Path $packageRoot $EntryExeName) -Force
        $assetSource = Join-Path $AppRoot "_internal\station_monitor_assets"
        $assetTarget = Join-Path $packageRoot "_internal\station_monitor_assets"
        $baseLibrarySource = Join-Path $AppRoot "_internal\base_library.zip"
        $baseLibraryTarget = Join-Path $packageRoot "_internal\base_library.zip"
        $assetCount = 0
        $baseLibraryCount = 0
        if (Test-Path $assetSource) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $assetTarget) -Force | Out-Null
            Copy-Item -Path $assetSource -Destination $assetTarget -Recurse -Force
            $assetCount = @(Get-ChildItem -Path $assetSource -File -Recurse).Count
        }
        else {
            throw "App asset folder not found: $assetSource"
        }
        if (Test-Path $baseLibrarySource) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $baseLibraryTarget) -Force | Out-Null
            Copy-Item -Path $baseLibrarySource -Destination $baseLibraryTarget -Force
            $baseLibraryCount = 1
        }
        else {
            throw "App payload file not found: $baseLibrarySource"
        }

        Compress-Archive -Path (Join-Path $packageRoot "*") -DestinationPath $appZipPath
        $appHash = (Get-FileHash -Algorithm SHA256 $appZipPath).Hash.ToLowerInvariant()
        Invoke-Signer -SignerProjectPath $SignerProjectPath -InputPath $appZipPath -KeyPath $KeyPath -OutputPath $appSignaturePath

        return [pscustomobject]@{
            ZipPath       = $appZipPath
            SignaturePath = $appSignaturePath
            Url           = "$TrimmedBaseUrl/$appZipName"
            Sha256        = $appHash
            FileCount     = $assetCount + $baseLibraryCount + 1
        }
    }
    finally {
        if (Test-Path $tempRoot) {
            Remove-Item $tempRoot -Recurse -Force
        }
    }
}

$root = $paths.SourceRoot
$distDir = Join-Path $paths.DistPath "MonitorSMS"
$signerProject = Join-Path $PSScriptRoot "signer\MonitorSMSSigner.csproj"

if (-not (Test-Path $distDir)) {
    Write-Error "dist\\MonitorSMS not found. Build the app first."
    exit 1
}

if (-not (Test-Path $signerProject)) {
    Write-Error "Signer project not found: $signerProject"
    exit 1
}

if (-not $SigningKeyPath) {
    $SigningKeyPath = $env:MONITOR_UPDATE_SIGNING_KEY_PATH
}
if (-not $SigningKeyPath) {
    Write-Error "Signing key not configured. Set MONITOR_UPDATE_SIGNING_KEY_PATH or pass -SigningKeyPath."
    exit 1
}

try {
    $SigningKeyPath = (Resolve-Path $SigningKeyPath -ErrorAction Stop).Path
}
catch {
    Write-Error "Signing key not found: $SigningKeyPath"
    exit 1
}

if (-not $Version) {
    $line = Select-String -Path (Join-Path $root "pyproject.toml") -Pattern '^version\s*=' | Select-Object -First 1
    if ($null -eq $line) {
        Write-Error "Unable to find version in pyproject.toml."
        exit 1
    }
    $Version = ($line.Line -replace 'version\s*=\s*"(.*)"', '$1').Trim()
}

$artifactsRoot = $paths.ArtifactsPath
$outDir = Get-VersionArtifactsPath -ArtifactsRoot $artifactsRoot -Version $Version -ArtifactPrefix $artifactPrefix
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$manifestsDir = Join-Path $artifactsRoot "manifests"
New-Item -ItemType Directory -Path $manifestsDir -Force | Out-Null

$trimmedBaseUrl = $BaseUrl.TrimEnd("/")
$zipName = "$artifactNamePrefix$Version.zip"
$zipPath = Join-Path $outDir $zipName
$zipSignaturePath = "$zipPath.sig"
$appZipName = "$artifactNamePrefix$Version-app.zip"
$appZipPath = Join-Path $outDir $appZipName
$appSignaturePath = "$appZipPath.sig"
$manifestPath = Join-Path $outDir "latest.json"
$manifestSignaturePath = "$manifestPath.sig"
$archivedManifestPath = Join-Path $manifestsDir "$artifactNamePrefix$Version.json"
$archivedManifestSignaturePath = "$archivedManifestPath.sig"

Write-Host "Using channel '$resolvedChannel' with artifact prefix '$artifactNamePrefix'"

foreach ($artifact in @($zipPath, $zipSignaturePath, $appZipPath, $appSignaturePath, $manifestPath, $manifestSignaturePath)) {
    if (Test-Path $artifact) {
        Remove-Item $artifact -Force
    }
}

Compress-Archive -Path (Join-Path $distDir "*") -DestinationPath $zipPath
$fullHash = (Get-FileHash -Algorithm SHA256 $zipPath).Hash.ToLowerInvariant()
$fullSignatureUrl = "$trimmedBaseUrl/$zipName.sig"
Write-Host "Built full update ZIP for version $Version at $zipPath"

$runtimeId = Get-RuntimeId -AppRoot $distDir
$runtimeFileCount = @(Get-RuntimeInventory -AppRoot $distDir).Count
Write-Host "Computed runtime_id $runtimeId from $runtimeFileCount runtime file(s)"

$appArtifact = New-AppOnlyArtifact `
    -AppRoot $distDir `
    -Version $Version `
    -ArtifactsPath $outDir `
    -TrimmedBaseUrl $trimmedBaseUrl `
    -SignerProjectPath $signerProject `
    -KeyPath $SigningKeyPath `
    -EntryExeName $EntryExe `
    -ArtifactNamePrefix $artifactNamePrefix
Write-Host "Built app-only ZIP with $($appArtifact.FileCount) file(s) at $($appArtifact.ZipPath)"

$manifestObject = [ordered]@{
    version           = $Version
    url               = "$trimmedBaseUrl/$zipName"
    sha256            = $fullHash
    entry_exe         = $EntryExe
    signature_url     = $fullSignatureUrl
    runtime_id        = $runtimeId
    app_url           = $appArtifact.Url
    app_sha256        = $appArtifact.Sha256
    app_signature_url = "$trimmedBaseUrl/$appZipName.sig"
}

$manifest = $manifestObject | ConvertTo-Json -Depth 5
Write-Utf8NoBomFile -Path $manifestPath -Content ($manifest + [Environment]::NewLine)
Write-Host "Wrote update manifest for version $Version to $manifestPath"

Invoke-Signer -SignerProjectPath $signerProject -InputPath $zipPath -KeyPath $SigningKeyPath -OutputPath $zipSignaturePath
Invoke-Signer -SignerProjectPath $signerProject -InputPath $appZipPath -KeyPath $SigningKeyPath -OutputPath $appSignaturePath
Invoke-Signer -SignerProjectPath $signerProject -InputPath $manifestPath -KeyPath $SigningKeyPath -OutputPath $manifestSignaturePath
Write-Host "Signed full ZIP, app-only ZIP, and manifest artifacts"

Copy-Item -Path $manifestPath -Destination $archivedManifestPath -Force
Copy-Item -Path $manifestSignaturePath -Destination $archivedManifestSignaturePath -Force

Write-Host "Wrote $zipPath"
Write-Host "Wrote $zipSignaturePath"
Write-Host "Wrote $appZipPath"
Write-Host "Wrote $appSignaturePath"
Write-Host "Wrote $manifestPath"
Write-Host "Wrote $manifestSignaturePath"
Write-Host "Archived $archivedManifestPath"
Write-Host "Archived $archivedManifestSignaturePath"
