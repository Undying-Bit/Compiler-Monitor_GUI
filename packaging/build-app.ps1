param(
    [string]$PythonExe = "",
    [string]$SourceRoot = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "paths.ps1")
$paths = Get-CompilePaths -SourceRoot $SourceRoot

$root = $paths.SourceRoot
$venvPython = Join-Path $root ".venv\Scripts\python.exe"

if (-not $PythonExe) {
    if (Test-Path $venvPython) {
        $PythonExe = $venvPython
    } else {
        $PythonExe = "python"
    }
}

$iconPath = Join-Path $PSScriptRoot "app.ico"
$generatedDir = Join-Path $paths.CompileRoot ".tmp\generated"
$versionFile = Join-Path $generatedDir "version_info_app.txt"
$manifestFile = Join-Path $PSScriptRoot "app.manifest"
$distPath = $paths.DistPath
$workPath = $paths.PyinstallerBuildPath
$specPath = $paths.PyinstallerSpecPath

$entry = Join-Path $root "src\station_monitor\main.py"

$pyproject = Join-Path $root "pyproject.toml"
$versionLine = Select-String -Path $pyproject -Pattern '^version\s*=' | Select-Object -First 1
if (-not $versionLine) {
    Write-Error "Unable to find version in $pyproject."
    exit 1
}
$version = ($versionLine.Line -replace 'version\s*=\s*"(.*)"', '$1').Trim()
$numeric = ($version -split '[^0-9.]')[0]
$parts = $numeric -split '\.'
if ($parts.Count -lt 3) {
    $parts = @($parts + @(0,0,0)) | Select-Object -First 3
} else {
    $parts = $parts | Select-Object -First 3
}
$fileVer = "$($parts[0]), $($parts[1]), $($parts[2]), 0"

if (-not (Test-Path $generatedDir)) {
    New-Item -ItemType Directory -Path $generatedDir -Force | Out-Null
}

@"
VSVersionInfo(
  ffi=FixedFileInfo(
    filevers=($fileVer),
    prodvers=($fileVer),
    mask=0x3F,
    flags=0x0,
    OS=0x40004,
    fileType=0x1,
    subtype=0x0,
    date=(0, 0)
  ),
  kids=[
    StringFileInfo(
      [
        StringTable(
          "040904B0",
          [
            StringStruct("CompanyName", "CIRES A.C."),
            StringStruct("FileDescription", "Monitor SMS"),
            StringStruct("FileVersion", "$version"),
            StringStruct("InternalName", "MonitorSMS"),
            StringStruct("OriginalFilename", "MonitorSMS.exe"),
            StringStruct("ProductName", "Monitor SMS"),
            StringStruct("ProductVersion", "$version"),
          ],
        )
      ]
    ),
    VarFileInfo([VarStruct("Translation", [0x0409, 0x04B0])]),
  ],
)
"@ | Set-Content -Path $versionFile -Encoding UTF8

$excludeModules = @(
    "PySide6.QtWebEngine",
    "PySide6.QtWebEngineCore",
    "PySide6.QtWebEngineQuick",
    "PySide6.QtWebEngineWidgets",
    "PySide6.QtWebChannel",
    "PySide6.QtQml",
    "PySide6.QtQuick",
    "PySide6.QtQuickWidgets",
    "PySide6.QtMultimedia",
    "PySide6.QtMultimediaWidgets",
    "PySide6.QtPdf",
    "PySide6.QtPdfWidgets",
    "PySide6.QtOpenGL",
    "PySide6.QtOpenGLWidgets",
    "PySide6.Qt3DAnimation",
    "PySide6.Qt3DCore",
    "PySide6.Qt3DExtras",
    "PySide6.Qt3DInput",
    "PySide6.Qt3DLogic",
    "PySide6.Qt3DRender",
    "PySide6.QtCharts",
    "PySide6.QtDataVisualization",
    "PySide6.QtDesigner",
    "PySide6.QtHelp",
    "PySide6.QtLocation",
    "PySide6.QtPositioning",
    "PySide6.QtSensors",
    "PySide6.QtSerialPort",
    "PySide6.QtSvg",
    "PySide6.QtSvgWidgets",
    "PySide6.QtTextToSpeech",
    "PySide6.QtWebSockets",
    "PySide6.QtXml",
    "PySide6.QtXmlPatterns",
    "PySide6.QtRemoteObjects",
    "PySide6.QtScxml",
    "PySide6.QtStateMachine",
    "PySide6.QtNetworkAuth",
    "PySide6.QtSpatialAudio",
    "PySide6.QtConcurrent",
    "PySide6.QtPrintSupport",
    "PySide6.QtSql"
)

$args = @(
    "-m", "PyInstaller",
    "--noconfirm",
    "--clean",
    "--windowed",
    "--name", "MonitorSMS",
    "--paths", (Join-Path $root "src"),
    "--distpath", $distPath,
    "--workpath", $workPath,
    "--specpath", $specPath,
    "--version-file", $versionFile,
    "--manifest", $manifestFile,
    $entry
)

foreach ($module in $excludeModules) {
    $args += @("--exclude-module", $module)
}

if (Test-Path $iconPath) {
    $args += @("--add-data", "$iconPath;station_monitor_assets")
    $args += @("--icon", $iconPath)
}

& $PythonExe @args

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$appRoot = Join-Path $distPath "MonitorSMS"
$pysideRoot = Join-Path $appRoot "_internal\PySide6"
$translations = Join-Path $pysideRoot "translations"
$qml = Join-Path $pysideRoot "qml"
$pluginsRoot = Join-Path $pysideRoot "plugins"
$keepPlugins = @(
    "platforms",
    "styles",
    "imageformats",
    "iconengines",
    "platforminputcontexts",
    "tls"
)

if (Test-Path $translations) {
    Remove-Item -Path $translations -Recurse -Force
}

if (Test-Path $qml) {
    Remove-Item -Path $qml -Recurse -Force
}

if (Test-Path $pluginsRoot) {
    Get-ChildItem -Path $pluginsRoot -Directory | Where-Object {
        $keepPlugins -notcontains $_.Name
    } | ForEach-Object {
        Remove-Item -Path $_.FullName -Recurse -Force
    }
}
