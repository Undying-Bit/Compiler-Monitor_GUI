using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace MonitorSMSLauncher.Telemetry;

public sealed record TelemetryIdentity(
    [property: JsonPropertyName("installation_id")] string InstallationId,
    [property: JsonPropertyName("created_at")] string CreatedAt)
{
    private const string IdentityFileName = "identity.json";
    private const string InvalidIdentityFileName = "identity.invalid.json";

    public static TelemetryIdentity LoadOrCreate(string telemetryDir, Action<string>? warn = null)
    {
        try
        {
            Directory.CreateDirectory(telemetryDir);
            var path = Path.Combine(telemetryDir, IdentityFileName);
            if (File.Exists(path))
            {
                try
                {
                    var identity = JsonSerializer.Deserialize<TelemetryIdentity>(File.ReadAllText(path));
                    if (identity is not null && Guid.TryParse(identity.InstallationId, out _))
                    {
                        return identity;
                    }

                    throw new InvalidDataException("identity.json is missing a valid installation_id.");
                }
                catch (Exception ex)
                {
                    warn?.Invoke($"Telemetry identity is invalid; rotating file. {ex.Message}");
                    MoveAside(path, Path.Combine(telemetryDir, InvalidIdentityFileName), warn);
                }
            }

            var created = new TelemetryIdentity(Guid.NewGuid().ToString(), DateTimeOffset.UtcNow.ToString("O"));
            File.WriteAllText(path, JsonSerializer.Serialize(created));
            return created;
        }
        catch (Exception ex)
        {
            warn?.Invoke($"Telemetry identity persistence failed; using transient installation_id. {ex.Message}");
            return new TelemetryIdentity(Guid.NewGuid().ToString(), DateTimeOffset.UtcNow.ToString("O"));
        }
    }

    private static void MoveAside(string sourcePath, string destinationPath, Action<string>? warn)
    {
        try
        {
            if (File.Exists(destinationPath))
            {
                File.Delete(destinationPath);
            }

            File.Move(sourcePath, destinationPath);
        }
        catch (Exception ex)
        {
            warn?.Invoke($"Failed to preserve invalid telemetry identity file. {ex.Message}");
        }
    }
}
