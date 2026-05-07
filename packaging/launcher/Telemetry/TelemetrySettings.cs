using System;

namespace MonitorSMSLauncher.Telemetry;

public sealed record TelemetrySettings(
    bool Enabled,
    string? Endpoint,
    string? ApiKey,
    int BatchSize,
    int TimeoutSeconds)
{
    private const string EnabledEnv = "MONITOR_TELEMETRY_ENABLED";
    private const string EndpointEnv = "MONITOR_TELEMETRY_ENDPOINT";
    private const string ApiKeyEnv = "MONITOR_TELEMETRY_API_KEY";
    private const string BatchSizeEnv = "MONITOR_TELEMETRY_BATCH_SIZE";
    private const string TimeoutSecondsEnv = "MONITOR_TELEMETRY_TIMEOUT_SECONDS";

    public static TelemetrySettings FromEnvironment()
    {
        return new TelemetrySettings(
            ParseBool(Environment.GetEnvironmentVariable(EnabledEnv)),
            Normalize(Environment.GetEnvironmentVariable(EndpointEnv)),
            Normalize(Environment.GetEnvironmentVariable(ApiKeyEnv)),
            ParsePositiveInt(Environment.GetEnvironmentVariable(BatchSizeEnv), 10),
            ParsePositiveInt(Environment.GetEnvironmentVariable(TimeoutSecondsEnv), 4));
    }

    private static bool ParseBool(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        return value.Trim().ToLowerInvariant() is "1" or "true" or "yes" or "on";
    }

    private static int ParsePositiveInt(string? value, int fallback)
    {
        if (int.TryParse(value, out var parsed) && parsed > 0)
        {
            return parsed;
        }

        return fallback;
    }

    private static string? Normalize(string? value)
    {
        return string.IsNullOrWhiteSpace(value) ? null : value.Trim();
    }
}
