$ReleaseChannelName = "release"
$DevelopmentChannelName = "development"

$ReleaseMsiUpgradeCode = "{7F2FCA2E-0E1A-4E65-90C1-7D8C5B7A01C2}"
$DevelopmentMsiUpgradeCode = "{35D98827-D52A-4933-BFAD-BEE20CD8737E}"

$ReleaseBundleUpgradeCode = "{F24697B9-AECB-4296-9821-9C3D50A23A9F}"
$DevelopmentBundleUpgradeCode = "{C762CB50-7734-4C3A-A0D8-EBA77EC9A5A5}"

function Resolve-MonitorChannel {
    param(
        [string]$Channel = ""
    )

    $resolved = $Channel
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $resolved = $env:MONITOR_RELEASE_CHANNEL
    }
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $resolved = $ReleaseChannelName
    }

    $normalized = $resolved.Trim().ToLowerInvariant()
    if ($normalized -notin @($ReleaseChannelName, $DevelopmentChannelName)) {
        throw "Invalid channel '$resolved'. Expected '$ReleaseChannelName' or '$DevelopmentChannelName'."
    }
    return $normalized
}

function Get-ChannelArtifactPrefix {
    param([string]$Channel)
    if ($Channel -eq $DevelopmentChannelName) { return "development_" }
    return ""
}

function Get-ChannelArtifactNamePrefix {
    param([string]$Channel)
    return "$(Get-ChannelArtifactPrefix -Channel $Channel)MonitorSMS-"
}

function Get-ChannelProductDisplayName {
    param([string]$Channel)
    if ($Channel -eq $DevelopmentChannelName) { return "Monitor SMS Development" }
    return "Monitor SMS"
}

function Get-ChannelInstallFolderName {
    param([string]$Channel)
    if ($Channel -eq $DevelopmentChannelName) { return "MonitorSMS-Development" }
    return "MonitorSMS"
}

function Get-ChannelProgramMenuFolderName {
    param([string]$Channel)
    return Get-ChannelProductDisplayName -Channel $Channel
}

function Get-ChannelDesktopShortcutName {
    param([string]$Channel)
    return Get-ChannelProductDisplayName -Channel $Channel
}

function Get-ChannelLocalDataSubdir {
    param([string]$Channel)
    if ($Channel -eq $DevelopmentChannelName) { return "MonitorSMS-Development" }
    return "MonitorSMS"
}

function Get-ChannelUpdateBucket {
    param([string]$Channel)
    if ($Channel -eq $DevelopmentChannelName) { return "development-updates" }
    return "monitor-updates"
}

function Get-ChannelDataBucket {
    param([string]$Channel)
    if ($Channel -eq $DevelopmentChannelName) { return "development-db" }
    return "reportes-db"
}

function Get-ChannelMsiUpgradeCode {
    param([string]$Channel)
    if ($Channel -eq $DevelopmentChannelName) { return $DevelopmentMsiUpgradeCode }
    return $ReleaseMsiUpgradeCode
}

function Get-ChannelBundleUpgradeCode {
    param([string]$Channel)
    if ($Channel -eq $DevelopmentChannelName) { return $DevelopmentBundleUpgradeCode }
    return $ReleaseBundleUpgradeCode
}
