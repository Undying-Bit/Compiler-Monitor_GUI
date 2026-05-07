using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;

namespace MonitorSMSLauncher.Telemetry;

public sealed class TelemetryQueue
{
    private readonly string _queuePath;
    private readonly string _invalidQueuePath;
    private readonly int _maxLines;
    private readonly Action<string>? _warn;
    private readonly object _gate = new();

    public TelemetryQueue(string queuePath, int maxLines, Action<string>? warn = null)
    {
        _queuePath = queuePath;
        _invalidQueuePath = Path.Combine(
            Path.GetDirectoryName(queuePath) ?? string.Empty,
            "launcher_queue.invalid.jsonl");
        _maxLines = Math.Max(1, maxLines);
        _warn = warn;
    }

    public void Enqueue(string eventJson)
    {
        lock (_gate)
        {
            var lines = ReadValidatedLines();
            lines.Add(eventJson);
            if (lines.Count > _maxLines)
            {
                lines = lines.Skip(lines.Count - _maxLines).ToList();
            }

            WriteLines(lines);
        }
    }

    public IReadOnlyList<string> ReadBatch(int maxCount)
    {
        lock (_gate)
        {
            return ReadValidatedLines()
                .Take(Math.Max(1, maxCount))
                .ToArray();
        }
    }

    public void RemoveBatch(int count)
    {
        if (count <= 0)
        {
            return;
        }

        lock (_gate)
        {
            var lines = ReadValidatedLines();
            if (lines.Count <= count)
            {
                DeleteQueueFile();
                return;
            }

            WriteLines(lines.Skip(count).ToList());
        }
    }

    private List<string> ReadValidatedLines()
    {
        try
        {
            if (!File.Exists(_queuePath))
            {
                return new List<string>();
            }

            var lines = File.ReadAllLines(_queuePath, Encoding.UTF8)
                .Where(line => !string.IsNullOrWhiteSpace(line))
                .ToList();

            foreach (var line in lines)
            {
                using var _ = JsonDocument.Parse(line);
            }

            return lines;
        }
        catch (Exception ex)
        {
            _warn?.Invoke($"Telemetry queue is corrupt; resetting queue. {ex.Message}");
            MoveAsideCorruptQueue();
            return new List<string>();
        }
    }

    private void WriteLines(IReadOnlyList<string> lines)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_queuePath) ?? string.Empty);
        if (lines.Count == 0)
        {
            DeleteQueueFile();
            return;
        }

        File.WriteAllLines(_queuePath, lines, Encoding.UTF8);
    }

    private void DeleteQueueFile()
    {
        try
        {
            if (File.Exists(_queuePath))
            {
                File.Delete(_queuePath);
            }
        }
        catch (Exception ex)
        {
            _warn?.Invoke($"Failed to delete telemetry queue file. {ex.Message}");
        }
    }

    private void MoveAsideCorruptQueue()
    {
        try
        {
            if (!File.Exists(_queuePath))
            {
                return;
            }

            Directory.CreateDirectory(Path.GetDirectoryName(_queuePath) ?? string.Empty);
            if (File.Exists(_invalidQueuePath))
            {
                File.Delete(_invalidQueuePath);
            }

            File.Move(_queuePath, _invalidQueuePath);
        }
        catch (Exception ex)
        {
            _warn?.Invoke($"Failed to preserve invalid telemetry queue. {ex.Message}");
        }
    }
}
