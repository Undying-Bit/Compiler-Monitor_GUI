param(
    [string]$PythonExe = "",
    [string]$SourceRoot = ""
)

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
$versionFile = Join-Path $PSScriptRoot "version_info_app.txt"
$manifestFile = Join-Path $PSScriptRoot "app.manifest"
$distPath = $paths.DistPath
$workPath = $paths.PyinstallerBuildPath
$specPath = $paths.PyinstallerSpecPath

$entry = Join-Path $root "src\station_monitor\main.py"

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
