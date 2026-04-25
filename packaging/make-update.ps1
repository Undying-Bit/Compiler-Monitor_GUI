param(
    [string]$Version = "",
    [string]$BaseUrl = "https://example.com",
    [string]$SigningKeyPath = "",
    [string]$EntryExe = "MonitorSMS.exe",
    [string]$SourceRoot = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "paths.ps1")
$paths = Get-CompilePaths -SourceRoot $SourceRoot

function Get-VersionParts {
    param([string]$VersionText)

    $parts = New-Object System.Collections.Generic.List[object]
    foreach ($part in [regex]::Split($VersionText, "[.\-+_]")) {
        if ([string]::IsNullOrWhiteSpace($part)) {
            continue
        }

        $number = 0
        if ([int]::TryParse($part, [ref]$number)) {
            $parts.Add([pscustomobject]@{
                    IsNumber = $true
                    Number   = $number
                    Text     = ""
                })
        }
        else {
            $parts.Add([pscustomobject]@{
                    IsNumber = $false
                    Number   = 0
                    Text     = $part
                })
        }
    }

    return $parts
}

function Compare-MonitorVersions {
    param(
        [string]$Left,
        [string]$Right
    )

    $leftParts = Get-VersionParts $Left
    $rightParts = Get-VersionParts $Right
    $max = [Math]::Max($leftParts.Count, $rightParts.Count)

    for ($index = 0; $index -lt $max; $index++) {
        $leftPart = if ($index -lt $leftParts.Count) { $leftParts[$index] } else { [pscustomobject]@{ IsNumber = $true; Number = 0; Text = "" } }
        $rightPart = if ($index -lt $rightParts.Count) { $rightParts[$index] } else { [pscustomobject]@{ IsNumber = $true; Number = 0; Text = "" } }

        if ($leftPart.IsNumber -and $rightPart.IsNumber) {
            if ($leftPart.Number -lt $rightPart.Number) { return -1 }
            if ($leftPart.Number -gt $rightPart.Number) { return 1 }
            continue
        }

        if (-not $leftPart.IsNumber -and -not $rightPart.IsNumber) {
            $cmp = [string]::Compare($leftPart.Text, $rightPart.Text, [System.StringComparison]::OrdinalIgnoreCase)
            if ($cmp -lt 0) { return -1 }
            if ($cmp -gt 0) { return 1 }
            continue
        }

        if ($leftPart.IsNumber) { return 1 }
        return -1
    }

    return 0
}

function Resolve-PayloadRoot {
    param(
        [string]$ExtractRoot,
        [string]$EntryExeName
    )

    if (Test-Path (Join-Path $ExtractRoot $EntryExeName)) {
        return $ExtractRoot
    }

    $childDirs = Get-ChildItem -Path $ExtractRoot -Directory
    if ($childDirs.Count -eq 1 -and (Test-Path (Join-Path $childDirs[0].FullName $EntryExeName))) {
        return $childDirs[0].FullName
    }

    throw "Extracted payload missing $EntryExeName."
}

function Get-FullArchiveVersion {
    param([string]$ArchiveName)

    if ($ArchiveName -notmatch '^MonitorSMS-(.+)\.zip$') {
        return $null
    }

    $version = $Matches[1]
    if ($version -match '^.+-to-.+-patch$') {
        return $null
    }

    return $version
}

function Get-PreviousFullArchive {
    param(
        [string]$ArtifactsPath,
        [string]$CurrentVersion
    )

    $best = $null
    foreach ($file in Get-ChildItem -Path $ArtifactsPath -Filter "MonitorSMS-*.zip" -File -ErrorAction SilentlyContinue) {
        $candidateVersion = Get-FullArchiveVersion -ArchiveName $file.Name
        if (-not $candidateVersion) {
            continue
        }
        if ($candidateVersion -eq $CurrentVersion) {
            continue
        }
        if ((Compare-MonitorVersions $candidateVersion $CurrentVersion) -ge 0) {
            continue
        }
        if ($null -eq $best -or (Compare-MonitorVersions $candidateVersion $best.Version) -gt 0) {
            $best = [pscustomobject]@{
                Version = $candidateVersion
                Path    = $file.FullName
            }
        }
    }

    return $best
}

function Get-FileInventory {
    param([string]$RootPath)

    $inventory = @{}
    foreach ($file in Get-ChildItem -Path $RootPath -File -Recurse) {
        $relative = Get-RelativePath -RootPath $RootPath -TargetPath $file.FullName
        $inventory[$relative] = $file.FullName
    }

    return $inventory
}

function Get-DirectoryInventory {
    param([string]$RootPath)

    $directories = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($dir in Get-ChildItem -Path $RootPath -Directory -Recurse) {
        $relative = Get-RelativePath -RootPath $RootPath -TargetPath $dir.FullName
        if (-not [string]::IsNullOrWhiteSpace($relative)) {
            [void]$directories.Add($relative)
        }
    }

    return $directories
}

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

function New-PatchArtifact {
    param(
        [string]$PreviousZipPath,
        [string]$FromVersion,
        [string]$ToVersion,
        [string]$EntryExeName,
        [string]$CurrentDistDir,
        [string]$ArtifactsPath,
        [string]$TrimmedBaseUrl,
        [string]$SignerProjectPath,
        [string]$KeyPath
    )

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("monitor_patch_" + [System.Guid]::NewGuid().ToString("N"))
    $previousExtract = Join-Path $tempRoot "previous"
    $patchRoot = Join-Path $tempRoot "patch"
    $patchZipName = "MonitorSMS-$FromVersion-to-$ToVersion-patch.zip"
    $patchZipPath = Join-Path $ArtifactsPath $patchZipName
    $patchSignaturePath = "$patchZipPath.sig"

    try {
        if (Test-Path $patchZipPath) {
            Remove-Item $patchZipPath -Force
        }
        if (Test-Path $patchSignaturePath) {
            Remove-Item $patchSignaturePath -Force
        }

        New-Item -ItemType Directory -Path $previousExtract -Force | Out-Null
        New-Item -ItemType Directory -Path $patchRoot -Force | Out-Null

        Expand-Archive -Path $PreviousZipPath -DestinationPath $previousExtract -Force
        $previousRoot = Resolve-PayloadRoot -ExtractRoot $previousExtract -EntryExeName $EntryExeName
        Write-Host "Building patch artifact from $FromVersion to $ToVersion using baseline $PreviousZipPath"

        $currentFiles = Get-FileInventory -RootPath $CurrentDistDir
        $previousFiles = Get-FileInventory -RootPath $previousRoot
        $currentDirs = Get-DirectoryInventory -RootPath $CurrentDistDir
        $previousDirs = Get-DirectoryInventory -RootPath $previousRoot

        $copiedFiles = 0
        foreach ($relativePath in $currentFiles.Keys) {
            $copyFile = $false
            if (-not $previousFiles.ContainsKey($relativePath)) {
                $copyFile = $true
            }
            else {
                $currentHash = (Get-FileHash -Algorithm SHA256 $currentFiles[$relativePath]).Hash
                $previousHash = (Get-FileHash -Algorithm SHA256 $previousFiles[$relativePath]).Hash
                if (-not $currentHash.Equals($previousHash, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $copyFile = $true
                }
            }

            if ($copyFile) {
                $destination = Join-Path $patchRoot ($relativePath -replace '/', '\')
                $destinationDir = Split-Path -Parent $destination
                if ($destinationDir) {
                    New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
                }
                Copy-Item -Path $currentFiles[$relativePath] -Destination $destination -Force
                $copiedFiles++
            }
        }

        $deletePaths = New-Object System.Collections.Generic.List[string]
        foreach ($relativePath in $previousFiles.Keys) {
            if (-not $currentFiles.ContainsKey($relativePath)) {
                $deletePaths.Add($relativePath)
            }
        }
        foreach ($relativePath in $previousDirs) {
            if (-not $currentDirs.Contains($relativePath)) {
                $deletePaths.Add($relativePath)
            }
        }

        $uniqueDeletePaths = $deletePaths.ToArray() |
            Sort-Object -Unique
        Write-Host "Patch diff includes $copiedFiles changed/new file(s) and $($uniqueDeletePaths.Count) delete path(s)"

        $patchMetadata = [ordered]@{
            from_version = $FromVersion
            to_version   = $ToVersion
            entry_exe    = $EntryExeName
            delete_paths = @($uniqueDeletePaths)
        } | ConvertTo-Json -Depth 5

        Write-Utf8NoBomFile -Path (Join-Path $patchRoot "patch.json") -Content ($patchMetadata + [Environment]::NewLine)

        Compress-Archive -Path (Join-Path $patchRoot "*") -DestinationPath $patchZipPath
        $patchHash = (Get-FileHash -Algorithm SHA256 $patchZipPath).Hash.ToLowerInvariant()
        Invoke-Signer -SignerProjectPath $SignerProjectPath -InputPath $patchZipPath -KeyPath $KeyPath -OutputPath $patchSignaturePath

        return [pscustomobject]@{
            FromVersion   = $FromVersion
            ZipPath       = $patchZipPath
            SignaturePath = $patchSignaturePath
            Url           = "$TrimmedBaseUrl/$patchZipName"
            Sha256        = $patchHash
            SignatureUrl  = "$TrimmedBaseUrl/$patchZipName.sig"
            FileCount     = $copiedFiles
            DeleteCount   = $uniqueDeletePaths.Count
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

$outDir = $paths.ArtifactsPath
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$manifestsDir = Join-Path $outDir "manifests"
New-Item -ItemType Directory -Path $manifestsDir -Force | Out-Null

$trimmedBaseUrl = $BaseUrl.TrimEnd("/")
$zipName = "MonitorSMS-$Version.zip"
$zipPath = Join-Path $outDir $zipName
$zipSignaturePath = "$zipPath.sig"
$manifestPath = Join-Path $outDir "latest.json"
$manifestSignaturePath = "$manifestPath.sig"
$archivedManifestPath = Join-Path $manifestsDir "MonitorSMS-$Version.json"
$archivedManifestSignaturePath = "$archivedManifestPath.sig"

foreach ($artifact in @($zipPath, $zipSignaturePath, $manifestPath, $manifestSignaturePath)) {
    if (Test-Path $artifact) {
        Remove-Item $artifact -Force
    }
}

$previousArchive = Get-PreviousFullArchive -ArtifactsPath $outDir -CurrentVersion $Version
if ($previousArchive) {
    Write-Host "Previous full artifact detected for patch generation: $($previousArchive.Version) at $($previousArchive.Path)"
}
else {
    Write-Host "No previous full artifact found for version $Version; publishing full ZIP only"
}

Compress-Archive -Path (Join-Path $distDir "*") -DestinationPath $zipPath
$hash = (Get-FileHash -Algorithm SHA256 $zipPath).Hash.ToLowerInvariant()
$signatureUrl = "$trimmedBaseUrl/$zipName.sig"
Write-Host "Built full update ZIP for version $Version at $zipPath"

$manifestObject = [ordered]@{
    version       = $Version
    url           = "$trimmedBaseUrl/$zipName"
    sha256        = $hash
    entry_exe     = $EntryExe
    signature_url = $signatureUrl
}

$patchArtifact = $null
if ($previousArchive) {
    try {
        $patchArtifact = New-PatchArtifact `
            -PreviousZipPath $previousArchive.Path `
            -FromVersion $previousArchive.Version `
            -ToVersion $Version `
            -EntryExeName $EntryExe `
            -CurrentDistDir $distDir `
            -ArtifactsPath $outDir `
            -TrimmedBaseUrl $trimmedBaseUrl `
            -SignerProjectPath $signerProject `
            -KeyPath $SigningKeyPath

        $manifestObject.patch_from_version = $patchArtifact.FromVersion
        $manifestObject.patch_url = $patchArtifact.Url
        $manifestObject.patch_sha256 = $patchArtifact.Sha256
        $manifestObject.patch_signature_url = $patchArtifact.SignatureUrl
        Write-Host "Patch artifact ready for manifest: $($patchArtifact.FromVersion) -> $Version with $($patchArtifact.FileCount) file(s) and $($patchArtifact.DeleteCount) delete path(s)"
    }
    catch {
        Write-Warning "Patch artifact generation failed: $_"
        $patchArtifact = $null
    }
}
else {
    Write-Host "Skipping patch artifact generation because there is no eligible previous full ZIP"
}

$manifest = $manifestObject | ConvertTo-Json -Depth 5
Write-Utf8NoBomFile -Path $manifestPath -Content ($manifest + [Environment]::NewLine)
Write-Host "Wrote update manifest for version $Version to $manifestPath"

Invoke-Signer -SignerProjectPath $signerProject -InputPath $zipPath -KeyPath $SigningKeyPath -OutputPath $zipSignaturePath
Invoke-Signer -SignerProjectPath $signerProject -InputPath $manifestPath -KeyPath $SigningKeyPath -OutputPath $manifestSignaturePath
Write-Host "Signed full ZIP and manifest artifacts"

Copy-Item -Path $manifestPath -Destination $archivedManifestPath -Force
Copy-Item -Path $manifestSignaturePath -Destination $archivedManifestSignaturePath -Force

Write-Host "Wrote $zipPath"
Write-Host "Wrote $zipSignaturePath"
Write-Host "Wrote $manifestPath"
Write-Host "Wrote $manifestSignaturePath"
if ($patchArtifact) {
    Write-Host "Wrote $($patchArtifact.ZipPath)"
    Write-Host "Wrote $($patchArtifact.SignaturePath)"
}
Write-Host "Archived $archivedManifestPath"
Write-Host "Archived $archivedManifestSignaturePath"
