using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace MonitorSMSLauncher.Telemetry;

public sealed class TelemetryService
{
    private const int MaxQueueLines = 1000;
    private const int MaxStringLength = 256;
    private const int MaxPayloadBytes = 4096;
    private static readonly IReadOnlyDictionary<string, object?> EmptyPayload = new Dictionary<string, object?>();
    private static readonly string[] SensitiveKeyFragments =
    {
        "path",
        "token",
        "secret",
        "key",
        "password"
    };

    private readonly bool _enabled;
    private readonly TelemetrySettings _settings;
    private readonly TelemetryQueue _queue;
    private readonly TelemetryClient _client;
    private readonly string _installationId;
    private readonly string _launcherSessionId;
    private readonly string _launcherVersion;
    private readonly string _channel;
    private string _appVersion;
    private readonly string? _userName;
    private readonly string? _userDomain;
    private readonly string? _osDescription;
    private readonly string? _osArchitecture;
    private readonly Action<string> _warn;

    public TelemetryService(
        TelemetrySettings settings,
        string stateRoot,
        string launcherVersion,
        string channel,
        Action<string>? warn = null)
    {
        _settings = settings;
        _warn = warn ?? (_ => { });

        var telemetryDir = Path.Combine(stateRoot, "telemetry");
        Directory.CreateDirectory(telemetryDir);

        var identity = TelemetryIdentity.LoadOrCreate(telemetryDir, _warn);
        _installationId = identity.InstallationId;
        _launcherSessionId = Guid.NewGuid().ToString();
        _launcherVersion = string.IsNullOrWhiteSpace(launcherVersion) ? "unknown" : launcherVersion.Trim();
        _appVersion = _launcherVersion;
        _channel = string.IsNullOrWhiteSpace(channel) ? "release" : channel.Trim().ToLowerInvariant();
        _userName = NormalizeHostValue(Environment.UserName);
        _userDomain = NormalizeHostValue(Environment.UserDomainName);
        _osDescription = NormalizeHostValue(RuntimeInformation.OSDescription);
        _osArchitecture = NormalizeHostValue(RuntimeInformation.OSArchitecture.ToString());
        _queue = new TelemetryQueue(Path.Combine(telemetryDir, "launcher_queue.jsonl"), MaxQueueLines, _warn);
        _client = new TelemetryClient(settings, _warn);

        if (settings.Enabled && string.IsNullOrWhiteSpace(settings.Endpoint))
        {
            _warn("Telemetry is enabled but MONITOR_TELEMETRY_ENDPOINT is empty; telemetry is disabled.");
        }

        _enabled = settings.Enabled && !string.IsNullOrWhiteSpace(settings.Endpoint);
    }

    public void Record(string eventName, object? payload = null)
    {
        if (!_enabled)
        {
            return;
        }

        try
        {
            if (!TelemetryEvent.IsAllowed(eventName))
            {
                _warn($"Ignoring unsupported telemetry event '{eventName}'.");
                return;
            }

            var telemetryEvent = new TelemetryEvent(
                eventName,
                _installationId,
                _launcherSessionId,
                DateTimeOffset.UtcNow.ToString("O"),
                _appVersion,
                _channel,
                _launcherVersion,
                _userName,
                _userDomain,
                _osDescription,
                _osArchitecture,
                SanitizePayload(payload));

            _queue.Enqueue(JsonSerializer.Serialize(telemetryEvent));
            FlushBestEffort();
        }
        catch (Exception ex)
        {
            _warn($"Telemetry record failed. {ex.GetType().Name}: {ex.Message}");
        }
    }

    public void SetAppVersion(string? appVersion)
    {
        var normalized = NormalizeHostValue(appVersion);
        _appVersion = string.IsNullOrWhiteSpace(normalized) ? _launcherVersion : normalized;
    }

    public void FlushBestEffort()
    {
        if (!_enabled)
        {
            return;
        }

        try
        {
            var batchSize = Math.Max(1, _settings.BatchSize);
            while (true)
            {
                var batch = _queue.ReadBatch(batchSize);
                if (batch.Count == 0)
                {
                    return;
                }

                if (!_client.SendBatch(batch))
                {
                    return;
                }

                _queue.RemoveBatch(batch.Count);
            }
        }
        catch (Exception ex)
        {
            _warn($"Telemetry flush failed. {ex.GetType().Name}: {ex.Message}");
        }
    }

    private IReadOnlyDictionary<string, object?> SanitizePayload(object? payload)
    {
        if (payload is null)
        {
            return EmptyPayload;
        }

        try
        {
            var element = JsonSerializer.SerializeToElement(payload);
            if (element.ValueKind != JsonValueKind.Object)
            {
                return EmptyPayload;
            }

            var sanitized = SanitizeObject(element);
            if (sanitized.Count == 0)
            {
                return EmptyPayload;
            }

            if (JsonSerializer.SerializeToUtf8Bytes(sanitized).Length > MaxPayloadBytes)
            {
                _warn("Telemetry payload exceeded the size limit and was dropped.");
                return EmptyPayload;
            }

            return sanitized;
        }
        catch (Exception ex)
        {
            _warn($"Telemetry payload sanitization failed. {ex.GetType().Name}: {ex.Message}");
            return EmptyPayload;
        }
    }

    private static Dictionary<string, object?> SanitizeObject(JsonElement element)
    {
        var sanitized = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
        {
            if (ContainsSensitiveFragment(property.Name))
            {
                continue;
            }

            sanitized[property.Name] = SanitizeValue(property.Value);
        }

        return sanitized;
    }

    private static object? SanitizeValue(JsonElement element)
    {
        return element.ValueKind switch
        {
            JsonValueKind.Object => SanitizeObject(element),
            JsonValueKind.Array => SanitizeArray(element),
            JsonValueKind.String => Truncate(element.GetString()),
            JsonValueKind.Number => SanitizeNumber(element),
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => null
        };
    }

    private static List<object?> SanitizeArray(JsonElement element)
    {
        var values = new List<object?>();
        foreach (var item in element.EnumerateArray())
        {
            values.Add(SanitizeValue(item));
        }

        return values;
    }

    private static object? SanitizeNumber(JsonElement element)
    {
        if (element.TryGetInt64(out var longValue))
        {
            return longValue;
        }

        if (element.TryGetDecimal(out var decimalValue))
        {
            return decimalValue;
        }

        if (element.TryGetDouble(out var doubleValue))
        {
            return doubleValue;
        }

        return Truncate(element.GetRawText());
    }

    private static string? Truncate(string? value)
    {
        if (value is null || value.Length <= MaxStringLength)
        {
            return value;
        }

        return value[..MaxStringLength];
    }

    private static string? NormalizeHostValue(string? value)
    {
        var trimmed = value?.Trim();
        return string.IsNullOrWhiteSpace(trimmed) ? null : Truncate(trimmed);
    }

    private static bool ContainsSensitiveFragment(string key)
    {
        foreach (var fragment in SensitiveKeyFragments)
        {
            if (key.Contains(fragment, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }
}
