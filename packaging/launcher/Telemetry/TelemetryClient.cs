using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;

namespace MonitorSMSLauncher.Telemetry;

public sealed class TelemetryClient
{
    private readonly TelemetrySettings _settings;
    private readonly Action<string>? _warn;

    public TelemetryClient(TelemetrySettings settings, Action<string>? warn = null)
    {
        _settings = settings;
        _warn = warn;
    }

    public bool SendBatch(IReadOnlyList<string> eventJsonLines)
    {
        if (eventJsonLines.Count == 0 || string.IsNullOrWhiteSpace(_settings.Endpoint))
        {
            return true;
        }

        try
        {
            using var client = new HttpClient
            {
                Timeout = TimeSpan.FromSeconds(Math.Max(1, _settings.TimeoutSeconds))
            };
            using var request = new HttpRequestMessage(HttpMethod.Post, _settings.Endpoint);
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            if (!string.IsNullOrWhiteSpace(_settings.ApiKey))
            {
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _settings.ApiKey);
            }

            request.Content = new StringContent(
                "{\"events\":[" + string.Join(",", eventJsonLines) + "]}",
                Encoding.UTF8,
                "application/json");

            using var response = client.Send(request);
            if ((int)response.StatusCode >= 200 && (int)response.StatusCode <= 299)
            {
                return true;
            }

            _warn?.Invoke($"Telemetry flush failed with HTTP {(int)response.StatusCode}.");
            return false;
        }
        catch (Exception ex)
        {
            _warn?.Invoke($"Telemetry flush failed before completion. {ex.GetType().Name}: {ex.Message}");
            return false;
        }
    }
}
