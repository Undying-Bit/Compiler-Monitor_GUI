using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace MonitorSMSLauncher.Telemetry;

public sealed record TelemetryEvent(
    [property: JsonPropertyName("event")] string Event,
    [property: JsonPropertyName("installation_id")] string InstallationId,
    [property: JsonPropertyName("session_id")] string LauncherSessionId,
    [property: JsonPropertyName("timestamp")] string Timestamp,
    [property: JsonPropertyName("app_version")] string AppVersion,
    [property: JsonPropertyName("channel")] string Channel,
    [property: JsonPropertyName("launcher_version")] string? LauncherVersion,
    [property: JsonPropertyName("user_name")] string? UserName,
    [property: JsonPropertyName("user_domain")] string? UserDomain,
    [property: JsonPropertyName("os_description")] string? OsDescription,
    [property: JsonPropertyName("os_architecture")] string? OsArchitecture,
    [property: JsonPropertyName("payload")] IReadOnlyDictionary<string, object?> Payload)
{
    private static readonly HashSet<string> AllowedEvents = new(StringComparer.Ordinal)
    {
        "launcher_started",
        "first_run_after_install",
        "launcher_update_check_failed",
        "launcher_update_install_completed",
        "launcher_update_install_failed",
        "launcher_app_only_update_completed",
        "launcher_app_only_update_failed",
        "launcher_rollback_completed",
        "launcher_rollback_failed",
        "launcher_app_launch_failed"
    };

    public static bool IsAllowed(string eventName)
    {
        return AllowedEvents.Contains(eventName ?? string.Empty);
    }
}
