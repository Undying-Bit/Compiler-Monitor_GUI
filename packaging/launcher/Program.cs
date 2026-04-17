using System.Diagnostics;
using System.Drawing;
using System.IO.Compression;
using System.Net.Http;
using System.Security.Cryptography;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows.Forms;

static class Program
{
    private const string AppName = "MonitorSMS";
    private const string AppPrefix = "app-";
    private const string DefaultEntryExe = "MonitorSMS.exe";
    private const string ManifestEnv = "MONITOR_UPDATE_MANIFEST_URL";
    private const string SkipEnv = "MONITOR_SKIP_UPDATE";
    private const string CurrentFile = "current.json";
    private const string RuntimeDirName = "runtime";
    private const string StageDirName = "stage";
    private const string SignatureSuffix = ".sig";
    private const string UpdateSigningKeyResource = "MonitorSMSLauncher.update-signing-public-key.pem";
    private static readonly string BaselinePattern = "MonitorSMS-*.zip";

    [STAThread]
    public static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        var installDir = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var stateRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppName);
        var runtimeDir = Path.Combine(stateRoot, RuntimeDirName);
        var stageDir = Path.Combine(stateRoot, StageDirName);
        var logger = new LauncherLogger(installDir, stateRoot);

        LoadDotEnv(installDir, logger);
        logger.Info($"Launcher install directory: {installDir}");
        logger.Info($"Launcher state directory: {stateRoot}");
        logger.Info($"Launcher runtime directory: {runtimeDir}");
        logger.Info($"Launcher stage directory: {stageDir}");

        InstalledApp? current = ReadCurrent(runtimeDir, logger);
        if (current is not null && !IsValidInstalledApp(current.Path, DefaultEntryExe))
        {
            logger.Warn($"Current app folder is missing or invalid: {current.Path}");
            current = null;
        }

        if (current is null)
        {
            var scanned = ScanInstalled(runtimeDir);
            current = PickLatest(scanned);
            if (current is not null)
            {
                WriteCurrent(runtimeDir, current.Version, Path.GetFileName(current.Path), logger);
            }
        }

        if (current is null)
        {
            current = TryMigrateLegacy(installDir, stateRoot, runtimeDir, logger);
        }

        var baselineZip = FindBaselineZip(installDir);
        if (current is null)
        {
            if (baselineZip is not null)
            {
                using var progress = new ProgressWindow("Installing MonitorSMS");
                progress.Show();
                progress.SetStatus("Installing baseline...");
                if (!InstallFromZip(baselineZip.Value.path, baselineZip.Value.version, installDir, runtimeDir, stageDir, DefaultEntryExe, cleanupZip: true, logger, progress))
                {
                    progress.CloseWindow();
                    ShowError("Baseline install failed. Check launcher.log for details.");
                    return 1;
                }
                progress.CloseWindow();
                return 0;
            }

            var manifestUrl = Environment.GetEnvironmentVariable(ManifestEnv);
            if (!string.IsNullOrWhiteSpace(manifestUrl))
            {
                var manifest = FetchManifest(manifestUrl, logger);
                if (manifest is not null)
                {
                    if (!InstallFromManifest(manifest, installDir, runtimeDir, stageDir, logger))
                    {
                        ShowError("Update download failed and no baseline is available.");
                        return 1;
                    }
                    return 0;
                }
            }

            ShowError("No installed app found and no baseline ZIP available.");
            return 1;
        }

        var currentExe = Path.Combine(current.Path, DefaultEntryExe);

        if (IsTruthy(Environment.GetEnvironmentVariable(SkipEnv)))
        {
            return LaunchApp(currentExe, installDir, args, logger);
        }

        var updateUrl = Environment.GetEnvironmentVariable(ManifestEnv);
        if (!string.IsNullOrWhiteSpace(updateUrl))
        {
            var manifest = FetchManifest(updateUrl, logger);
            if (manifest is not null && CompareVersions(manifest.Version, current.Version) > 0)
            {
                logger.Info($"Cloud version is newer: {manifest.Version} (installed {current.Version})");
                if (!InstallFromManifest(manifest, installDir, runtimeDir, stageDir, logger))
                {
                    var choice = MessageBox.Show(
                        "Update failed. Launch existing version?",
                        "MonitorSMS",
                        MessageBoxButtons.YesNo,
                        MessageBoxIcon.Error);
                    if (choice == DialogResult.Yes)
                    {
                        return LaunchApp(currentExe, installDir, args, logger);
                    }
                    return 1;
                }
                return 0;
            }
            logger.Info("No newer update available.");
        }
        else
        {
            logger.Warn($"{ManifestEnv} not set; skipping update check.");
        }

        return LaunchApp(currentExe, installDir, args, logger);
    }

    private static bool InstallFromManifest(UpdateManifest manifest, string installDir, string runtimeDir, string stageDir, LauncherLogger logger)
    {
        using var progress = new ProgressWindow("Updating MonitorSMS");
        progress.Show();
        progress.SetStatus("Downloading update...");
        var download = DownloadToStage(manifest.Url, stageDir, logger, progress);
        if (download is null)
        {
            progress.CloseWindow();
            return false;
        }

        progress.SetStatus("Verifying signature...");
        progress.SetIndeterminate();
        if (!VerifyFileSignature(download, manifest.SignatureUrl, logger))
        {
            SafeDelete(download);
            progress.CloseWindow();
            return false;
        }

        if (!string.IsNullOrWhiteSpace(manifest.Sha256))
        {
            progress.SetStatus("Verifying download...");
            progress.SetIndeterminate();
            var digest = Sha256File(download);
            if (!digest.Equals(manifest.Sha256, StringComparison.OrdinalIgnoreCase))
            {
                logger.Warn("SHA256 mismatch, skipping update.");
                SafeDelete(download);
                progress.CloseWindow();
                return false;
            }
        }

        progress.SetStatus("Extracting update...");
        var ok = InstallFromZip(download, manifest.Version, installDir, runtimeDir, stageDir, manifest.EntryExe, cleanupZip: true, logger, progress);
        progress.CloseWindow();
        return ok;
    }

    private static (string version, string path)? FindBaselineZip(string installDir)
    {
        var files = Directory.GetFiles(installDir, BaselinePattern, SearchOption.TopDirectoryOnly);
        if (files.Length == 0)
        {
            return null;
        }

        string? bestVersion = null;
        string? bestPath = null;
        foreach (var file in files)
        {
            var name = Path.GetFileNameWithoutExtension(file);
            if (!name.StartsWith("MonitorSMS-", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            var version = name["MonitorSMS-".Length..];
            if (string.IsNullOrWhiteSpace(version))
            {
                continue;
            }
            if (bestVersion is null || CompareVersions(version, bestVersion) > 0)
            {
                bestVersion = version;
                bestPath = file;
            }
        }

        return bestPath is null ? null : (bestVersion!, bestPath);
    }

    private static string? GetBaselineVersion(string installDir)
    {
        var baseline = FindBaselineZip(installDir);
        return baseline?.version;
    }

    private static UpdateManifest? FetchManifest(string url, LauncherLogger logger)
    {
        try
        {
            using var client = CreateHttpClient(TimeSpan.FromSeconds(10));
            var payload = client.GetByteArrayAsync(url).GetAwaiter().GetResult();
            var signatureUrl = BuildSignatureUrl(url);
            var signature = client.GetByteArrayAsync(signatureUrl).GetAwaiter().GetResult();
            if (!VerifyDataSignature(payload, signature, logger))
            {
                logger.Warn("Manifest signature verification failed.");
                return null;
            }

            using var doc = JsonDocument.Parse(StripUtf8Bom(payload));
            var root = doc.RootElement;
            var version = root.TryGetProperty("version", out var v) ? v.GetString() : null;
            var download = root.TryGetProperty("url", out var u) ? u.GetString() : null;
            if (string.IsNullOrWhiteSpace(version) || string.IsNullOrWhiteSpace(download))
            {
                logger.Warn("Manifest missing required fields: version/url");
                return null;
            }
            var sha = root.TryGetProperty("sha256", out var s) ? s.GetString() : null;
            var entry = root.TryGetProperty("entry_exe", out var e) ? e.GetString() : null;
            var downloadSignature = root.TryGetProperty("signature_url", out var sigUrl) ? sigUrl.GetString() : null;
            return new UpdateManifest(
                version,
                download!,
                string.IsNullOrWhiteSpace(sha) ? null : sha,
                string.IsNullOrWhiteSpace(entry) ? DefaultEntryExe : entry!,
                string.IsNullOrWhiteSpace(downloadSignature) ? BuildSignatureUrl(download!) : downloadSignature!
            );
        }
        catch (Exception ex)
        {
            logger.Warn($"Failed to fetch manifest: {ex.Message}");
            return null;
        }
    }

    private static ReadOnlyMemory<byte> StripUtf8Bom(byte[] payload)
    {
        if (payload.Length >= 3 && payload[0] == 0xEF && payload[1] == 0xBB && payload[2] == 0xBF)
        {
            return payload.AsMemory(3);
        }

        return payload;
    }

    private static HttpClient CreateHttpClient(TimeSpan timeout)
    {
        var client = new HttpClient
        {
            Timeout = timeout
        };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("MonitorSMSLauncher/1.0");
        return client;
    }

    private static string BuildSignatureUrl(string url)
    {
        var uri = new Uri(url);
        var builder = new UriBuilder(uri)
        {
            Path = uri.AbsolutePath + SignatureSuffix
        };
        return builder.Uri.ToString();
    }

    private static bool VerifyFileSignature(string path, string signatureUrl, LauncherLogger logger)
    {
        try
        {
            using var client = CreateHttpClient(TimeSpan.FromSeconds(30));
            var signature = client.GetByteArrayAsync(signatureUrl).GetAwaiter().GetResult();
            using var rsa = LoadUpdateSigningKey(logger);
            if (rsa is null)
            {
                return false;
            }

            using var stream = File.OpenRead(path);
            return rsa.VerifyData(stream, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        }
        catch (Exception ex)
        {
            logger.Warn($"Failed to verify detached signature for {path}: {ex.Message}");
            return false;
        }
    }

    private static bool VerifyDataSignature(byte[] payload, byte[] signature, LauncherLogger logger)
    {
        try
        {
            using var rsa = LoadUpdateSigningKey(logger);
            if (rsa is null)
            {
                return false;
            }
            return rsa.VerifyData(payload, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        }
        catch (Exception ex)
        {
            logger.Warn($"Failed to verify detached signature: {ex.Message}");
            return false;
        }
    }

    private static RSA? LoadUpdateSigningKey(LauncherLogger logger)
    {
        try
        {
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(UpdateSigningKeyResource);
            if (stream is null)
            {
                logger.Warn("Embedded update signing public key is missing.");
                return null;
            }

            using var reader = new StreamReader(stream, Encoding.UTF8);
            var pem = reader.ReadToEnd();
            if (string.IsNullOrWhiteSpace(pem))
            {
                logger.Warn("Embedded update signing public key is empty.");
                return null;
            }

            var rsa = RSA.Create();
            rsa.ImportFromPem(pem);
            return rsa;
        }
        catch (Exception ex)
        {
            logger.Warn($"Unable to load embedded update signing public key: {ex.Message}");
            return null;
        }
    }

    private static bool InstallFromZip(
        string zipPath,
        string version,
        string installDir,
        string runtimeDir,
        string stageDir,
        string entryExe,
        bool cleanupZip,
        LauncherLogger logger,
        ProgressWindow? progress)
    {
        var succeeded = false;
        string? stageRoot = null;
        try
        {
            CloseRunningApp(entryExe, logger);
            Directory.CreateDirectory(stageDir);
            stageRoot = Path.Combine(stageDir, Guid.NewGuid().ToString("N"));
            var extractRoot = Path.Combine(stageRoot, "extract");
            Directory.CreateDirectory(extractRoot);
            ExtractZipWithProgress(zipPath, extractRoot, progress, logger);

            var payloadRoot = ResolvePayloadRoot(extractRoot, entryExe);
            if (payloadRoot is null)
            {
                logger.Warn($"Extracted payload missing {entryExe}.");
                return false;
            }

            var sourceExe = Path.Combine(payloadRoot, entryExe);
            var sourceInternal = Path.Combine(payloadRoot, "_internal");
            if (!File.Exists(sourceExe) || !Directory.Exists(sourceInternal))
            {
                logger.Warn("Extracted payload missing MonitorSMS.exe or _internal.");
                return false;
            }

            var targetDir = Path.Combine(runtimeDir, $"{AppPrefix}{version}");
            var destExe = Path.Combine(targetDir, entryExe);
            var destInternal = Path.Combine(targetDir, "_internal");
            if (Directory.Exists(targetDir))
            {
                Directory.Delete(targetDir, recursive: true);
            }
            progress?.SetStatus("Installing files...");
            progress?.SetIndeterminate();
            Directory.CreateDirectory(targetDir);
            DirectoryCopy(sourceInternal, destInternal, true);
            File.Copy(sourceExe, destExe, overwrite: true);

            WriteCurrent(runtimeDir, version, Path.GetFileName(targetDir), logger);
            PruneRuntimeVersions(runtimeDir, Path.GetFileName(targetDir), logger);
            RemoveLegacyInstall(installDir, logger);
            logger.Info($"Installed version {version} into {targetDir}");
            LaunchApp(destExe, installDir, Array.Empty<string>(), logger);
            succeeded = true;
            return true;
        }
        catch (Exception ex)
        {
            logger.Warn($"Install failed: {ex.Message}");
            return false;
        }
        finally
        {
            if (stageRoot is not null)
            {
                try
                {
                    Directory.Delete(stageRoot, recursive: true);
                }
                catch
                {
                }
            }
            if (cleanupZip && succeeded)
            {
                SafeDelete(zipPath);
            }
        }
    }

    private static string? ResolvePayloadRoot(string extractRoot, string entryExe)
    {
        if (File.Exists(Path.Combine(extractRoot, entryExe)))
        {
            return extractRoot;
        }

        var childDirs = Directory.GetDirectories(extractRoot);
        if (childDirs.Length == 1 && File.Exists(Path.Combine(childDirs[0], entryExe)))
        {
            return childDirs[0];
        }

        return null;
    }

    private static void CloseRunningApp(string entryExe, LauncherLogger logger)
    {
        var processName = Path.GetFileNameWithoutExtension(entryExe);
        foreach (var process in Process.GetProcessesByName(processName))
        {
            try
            {
                logger.Info($"Closing running app (PID {process.Id}).");
                process.Kill(entireProcessTree: true);
                process.WaitForExit(5000);
            }
            catch (Exception ex)
            {
                logger.Warn($"Failed to close app process: {ex.Message}");
            }
        }
    }

    private static int LaunchApp(string appExe, string installDir, string[] args, LauncherLogger logger)
    {
        if (!File.Exists(appExe))
        {
            logger.Error($"Executable not found: {appExe}");
            return 1;
        }
        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = appExe,
                WorkingDirectory = installDir,
                UseShellExecute = false
            };
            foreach (var arg in args)
            {
                startInfo.ArgumentList.Add(arg);
            }
            Process.Start(startInfo);
            return 0;
        }
        catch (Exception ex)
        {
            logger.Error($"Failed to launch app: {ex.Message}");
            return 1;
        }
    }

    private static string? DownloadToStage(string url, string stageDir, LauncherLogger logger, ProgressWindow? progress)
    {
        try
        {
            Directory.CreateDirectory(stageDir);
            using var client = CreateHttpClient(TimeSpan.FromMinutes(5));
            using var response = client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead).GetAwaiter().GetResult();
            response.EnsureSuccessStatusCode();

            var tempFile = Path.Combine(stageDir, $"download_{Guid.NewGuid():N}.zip");
            var total = response.Content.Headers.ContentLength;
            if (total.HasValue)
            {
                progress?.SetProgress(0, total.Value);
            }
            else
            {
                progress?.SetIndeterminate();
            }

            using var input = response.Content.ReadAsStream();
            using var output = File.Create(tempFile);
            var buffer = new byte[81920];
            long readTotal = 0;
            int read;
            while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
            {
                output.Write(buffer, 0, read);
                readTotal += read;
                if (total.HasValue)
                {
                    progress?.SetProgress(readTotal, total.Value);
                }
            }
            return tempFile;
        }
        catch (Exception ex)
        {
            logger.Warn($"Download failed: {ex.Message}");
            return null;
        }
    }

    private static void ExtractZipWithProgress(string zipPath, string extractRoot, ProgressWindow? progress, LauncherLogger logger)
    {
        using var archive = ZipFile.OpenRead(zipPath);
        var totalEntries = archive.Entries.Count;
        var completed = 0;
        var normalizedRoot = Path.GetFullPath(extractRoot);

        foreach (var entry in archive.Entries)
        {
            var destPath = Path.GetFullPath(Path.Combine(extractRoot, entry.FullName));
            if (!IsPathWithinRoot(normalizedRoot, destPath))
            {
                logger.Warn($"Zip entry rejected due to path traversal: {entry.FullName}");
                throw new InvalidDataException($"Zip entry escapes staging directory: {entry.FullName}");
            }

            if (string.IsNullOrEmpty(entry.Name))
            {
                Directory.CreateDirectory(destPath);
                continue;
            }

            var destDir = Path.GetDirectoryName(destPath);
            if (!string.IsNullOrEmpty(destDir))
            {
                Directory.CreateDirectory(destDir);
            }

            entry.ExtractToFile(destPath, overwrite: true);
            completed++;
            progress?.SetProgress(completed, totalEntries);
        }
    }

    private static bool IsPathWithinRoot(string rootPath, string candidatePath)
    {
        var normalizedRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(rootPath));
        var normalizedCandidate = Path.TrimEndingDirectorySeparator(Path.GetFullPath(candidatePath));
        if (string.Equals(normalizedRoot, normalizedCandidate, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return normalizedCandidate.StartsWith(
            normalizedRoot + Path.DirectorySeparatorChar,
            StringComparison.OrdinalIgnoreCase);
    }

    private static string Sha256File(string path)
    {
        using var sha = SHA256.Create();
        using var stream = File.OpenRead(path);
        var hash = sha.ComputeHash(stream);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private static void WriteCurrent(string runtimeDir, string version, string folderName, LauncherLogger logger)
    {
        try
        {
            Directory.CreateDirectory(runtimeDir);
            var payload = JsonSerializer.Serialize(new { version, path = folderName });
            File.WriteAllText(Path.Combine(runtimeDir, CurrentFile), payload);
        }
        catch (Exception ex)
        {
            logger.Warn($"Failed to write current.json: {ex.Message}");
        }
    }

    private static InstalledApp? ReadCurrent(string runtimeDir, LauncherLogger logger)
    {
        var path = Path.Combine(runtimeDir, CurrentFile);
        if (!File.Exists(path))
        {
            return null;
        }
        try
        {
            var json = File.ReadAllText(path);
            var doc = JsonDocument.Parse(json);
            var version = doc.RootElement.TryGetProperty("version", out var v) ? v.GetString() : null;
            var relPath = doc.RootElement.TryGetProperty("path", out var p) ? p.GetString() : null;
            if (string.IsNullOrWhiteSpace(version))
            {
                return null;
            }

            if (string.IsNullOrWhiteSpace(relPath))
            {
                relPath = $"{AppPrefix}{version}";
            }

            if (!string.IsNullOrWhiteSpace(relPath) && Path.IsPathRooted(relPath))
            {
                relPath = Path.GetFileName(relPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
            }

            if (string.IsNullOrWhiteSpace(relPath))
            {
                relPath = $"{AppPrefix}{version}";
            }

            var fullPath = Path.Combine(runtimeDir, relPath);
            return new InstalledApp(version, fullPath);
        }
        catch (Exception ex)
        {
            logger.Warn($"Failed to read current.json: {ex.Message}");
            return null;
        }
    }

    private static string? ReadLegacyVersion(string stateRoot, LauncherLogger logger)
    {
        var path = Path.Combine(stateRoot, CurrentFile);
        if (!File.Exists(path))
        {
            return null;
        }
        try
        {
            var json = File.ReadAllText(path);
            var doc = JsonDocument.Parse(json);
            if (doc.RootElement.TryGetProperty("version", out var v))
            {
                var version = v.GetString();
                return string.IsNullOrWhiteSpace(version) ? null : version;
            }
            return null;
        }
        catch (Exception ex)
        {
            logger.Warn($"Failed to read legacy current.json: {ex.Message}");
            return null;
        }
    }

    private static bool IsValidInstalledApp(string appDir, string entryExe)
    {
        return File.Exists(Path.Combine(appDir, entryExe)) &&
            Directory.Exists(Path.Combine(appDir, "_internal"));
    }

    private static List<InstalledApp> ScanInstalled(string runtimeDir)
    {
        var apps = new List<InstalledApp>();
        if (!Directory.Exists(runtimeDir))
        {
            return apps;
        }

        foreach (var dir in Directory.GetDirectories(runtimeDir, $"{AppPrefix}*"))
        {
            var name = Path.GetFileName(dir);
            if (string.IsNullOrWhiteSpace(name) || !name.StartsWith(AppPrefix, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            var version = name[AppPrefix.Length..];
            if (string.IsNullOrWhiteSpace(version))
            {
                continue;
            }
            if (!IsValidInstalledApp(dir, DefaultEntryExe))
            {
                continue;
            }
            apps.Add(new InstalledApp(version, dir));
        }

        return apps;
    }

    private static InstalledApp? PickLatest(List<InstalledApp> installed)
    {
        InstalledApp? best = null;
        foreach (var app in installed)
        {
            if (best is null || CompareVersions(app.Version, best.Version) > 0)
            {
                best = app;
            }
        }
        return best;
    }

    private static void PruneRuntimeVersions(string runtimeDir, string keepFolderName, LauncherLogger logger)
    {
        if (!Directory.Exists(runtimeDir))
        {
            return;
        }

        foreach (var dir in Directory.GetDirectories(runtimeDir, $"{AppPrefix}*"))
        {
            var name = Path.GetFileName(dir);
            if (string.Equals(name, keepFolderName, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            try
            {
                Directory.Delete(dir, recursive: true);
            }
            catch (Exception ex)
            {
                logger.Warn($"Failed to remove old runtime folder {dir}: {ex.Message}");
            }
        }
    }

    private static void RemoveLegacyInstall(string installDir, LauncherLogger logger)
    {
        var legacyExe = Path.Combine(installDir, DefaultEntryExe);
        var legacyInternal = Path.Combine(installDir, "_internal");

        try
        {
            if (Directory.Exists(legacyInternal))
            {
                Directory.Delete(legacyInternal, recursive: true);
            }
        }
        catch (Exception ex)
        {
            logger.Warn($"Failed to remove legacy _internal folder: {ex.Message}");
        }

        try
        {
            if (File.Exists(legacyExe))
            {
                File.Delete(legacyExe);
            }
        }
        catch (Exception ex)
        {
            logger.Warn($"Failed to remove legacy exe: {ex.Message}");
        }
    }

    private static InstalledApp? TryMigrateLegacy(string installDir, string stateRoot, string runtimeDir, LauncherLogger logger)
    {
        var legacyExe = Path.Combine(installDir, DefaultEntryExe);
        var legacyInternal = Path.Combine(installDir, "_internal");
        if (!File.Exists(legacyExe) || !Directory.Exists(legacyInternal))
        {
            return null;
        }

        try
        {
            CloseRunningApp(DefaultEntryExe, logger);
            var version = ReadLegacyVersion(stateRoot, logger) ?? GetBaselineVersion(installDir) ?? "0.0.0";
            var targetDir = Path.Combine(runtimeDir, $"{AppPrefix}{version}");
            if (Directory.Exists(targetDir))
            {
                Directory.Delete(targetDir, recursive: true);
            }
            Directory.CreateDirectory(targetDir);

            var destExe = Path.Combine(targetDir, DefaultEntryExe);
            var destInternal = Path.Combine(targetDir, "_internal");
            DirectoryCopy(legacyInternal, destInternal, true);
            File.Copy(legacyExe, destExe, overwrite: true);

            if (!IsValidInstalledApp(targetDir, DefaultEntryExe))
            {
                logger.Warn("Legacy migration produced an invalid app layout.");
                return null;
            }

            WriteCurrent(runtimeDir, version, Path.GetFileName(targetDir), logger);
            PruneRuntimeVersions(runtimeDir, Path.GetFileName(targetDir), logger);
            RemoveLegacyInstall(installDir, logger);
            logger.Info($"Migrated legacy install to {targetDir}");
            return new InstalledApp(version, targetDir);
        }
        catch (Exception ex)
        {
            logger.Warn($"Legacy migration failed: {ex.Message}");
            return null;
        }
    }

    private static int CompareVersions(string left, string right)
    {
        var leftParts = SplitVersion(left);
        var rightParts = SplitVersion(right);
        var max = Math.Max(leftParts.Count, rightParts.Count);
        for (var i = 0; i < max; i++)
        {
            var l = i < leftParts.Count ? leftParts[i] : (isNumber: true, number: 0, text: "");
            var r = i < rightParts.Count ? rightParts[i] : (isNumber: true, number: 0, text: "");
            if (l.isNumber && r.isNumber)
            {
                var cmp = l.number.CompareTo(r.number);
                if (cmp != 0) return cmp;
            }
            else if (!l.isNumber && !r.isNumber)
            {
                var cmp = string.Compare(l.text, r.text, StringComparison.OrdinalIgnoreCase);
                if (cmp != 0) return cmp;
            }
            else
            {
                return l.isNumber ? 1 : -1;
            }
        }
        return 0;
    }

    private static List<(bool isNumber, int number, string text)> SplitVersion(string version)
    {
        var parts = new List<(bool, int, string)>();
        foreach (var part in Regex.Split(version, @"[.\-+_]", RegexOptions.Compiled))
        {
            if (string.IsNullOrWhiteSpace(part))
            {
                continue;
            }
            if (int.TryParse(part, out var number))
            {
                parts.Add((true, number, ""));
            }
            else
            {
                parts.Add((false, 0, part));
            }
        }
        return parts;
    }

    private static bool IsTruthy(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return false;
        return value.Trim().ToLowerInvariant() is "1" or "true" or "yes" or "on";
    }

    private static void LoadDotEnv(string installDir, LauncherLogger logger)
    {
        var envPath = Path.Combine(installDir, ".env");
        if (!File.Exists(envPath))
        {
            return;
        }
        try
        {
            foreach (var raw in File.ReadAllLines(envPath))
            {
                var line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#") || !line.Contains('='))
                {
                    continue;
                }
                var idx = line.IndexOf('=');
                var key = line[..idx].Trim();
                if (key.Length == 0 || Environment.GetEnvironmentVariable(key) is not null)
                {
                    continue;
                }
                var value = line[(idx + 1)..].Trim();
                value = StripWrappedQuotes(value);
                Environment.SetEnvironmentVariable(key, value);
            }
        }
        catch (Exception ex)
        {
            logger.Warn($"Failed to load .env: {ex.Message}");
        }
    }

    private static string StripWrappedQuotes(string value)
    {
        if (value.Length >= 2)
        {
            if ((value.StartsWith('"') && value.EndsWith('"')) || (value.StartsWith('\'') && value.EndsWith('\'')))
            {
                return value.Substring(1, value.Length - 2);
            }
        }
        return value;
    }

    private static void SafeDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
        }
    }

    private static void DirectoryCopy(string sourceDir, string destDir, bool copySubdirs)
    {
        var dir = new DirectoryInfo(sourceDir);
        if (!dir.Exists)
        {
            throw new DirectoryNotFoundException($"Source directory not found: {sourceDir}");
        }

        Directory.CreateDirectory(destDir);

        foreach (var file in dir.GetFiles())
        {
            var targetFile = Path.Combine(destDir, file.Name);
            file.CopyTo(targetFile, true);
        }

        if (!copySubdirs)
        {
            return;
        }

        foreach (var subdir in dir.GetDirectories())
        {
            var targetSubdir = Path.Combine(destDir, subdir.Name);
            DirectoryCopy(subdir.FullName, targetSubdir, true);
        }
    }

    private static void ShowError(string message)
    {
        MessageBox.Show(message, "MonitorSMS", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }

    private sealed class ProgressWindow : Form
    {
        private readonly Label _status;
        private readonly ProgressBar _bar;

        public ProgressWindow(string title)
        {
            Text = title;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ControlBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(420, 110);

            _status = new Label
            {
                AutoSize = false,
                Text = "Working...",
                Location = new Point(16, 14),
                Size = new Size(388, 32)
            };

            _bar = new ProgressBar
            {
                Location = new Point(16, 56),
                Size = new Size(388, 20),
                Style = ProgressBarStyle.Marquee,
                MarqueeAnimationSpeed = 30
            };

            Controls.Add(_status);
            Controls.Add(_bar);
            TopMost = true;
        }

        public void SetStatus(string text)
        {
            _status.Text = text;
            Application.DoEvents();
        }

        public void SetIndeterminate()
        {
            if (_bar.Style != ProgressBarStyle.Marquee)
            {
                _bar.Style = ProgressBarStyle.Marquee;
                _bar.MarqueeAnimationSpeed = 30;
            }
            Application.DoEvents();
        }

        public void SetProgress(long current, long total)
        {
            if (total <= 0)
            {
                SetIndeterminate();
                return;
            }

            if (_bar.Style != ProgressBarStyle.Blocks)
            {
                _bar.Style = ProgressBarStyle.Blocks;
                _bar.Minimum = 0;
                _bar.Maximum = 100;
            }

            var percent = (int)Math.Clamp((current * 100) / total, 0, 100);
            _bar.Value = percent;
            Application.DoEvents();
        }

        public void CloseWindow()
        {
            Close();
            Application.DoEvents();
        }
    }

    private sealed class LauncherLogger
    {
        private readonly string _logFile;

        public LauncherLogger(string installDir, string stateDir)
        {
            var logDir = Path.Combine(stateDir, "logs");
            try
            {
                Directory.CreateDirectory(logDir);
                _logFile = Path.Combine(logDir, "launcher.log");
                return;
            }
            catch
            {
            }

            var fallback = Path.Combine(installDir, "logs");
            try
            {
                Directory.CreateDirectory(fallback);
                _logFile = Path.Combine(fallback, "launcher.log");
            }
            catch
            {
                _logFile = Path.Combine(installDir, "launcher.log");
            }
        }

        public void Info(string message) => Write("INFO", message);
        public void Warn(string message) => Write("WARN", message);
        public void Error(string message) => Write("ERROR", message);

        private void Write(string level, string message)
        {
            try
            {
                var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} | {level} | {message}{Environment.NewLine}";
                File.AppendAllText(_logFile, line, Encoding.UTF8);
            }
            catch
            {
            }
        }
    }

    private sealed record InstalledApp(string Version, string Path);
    private sealed record UpdateManifest(string Version, string Url, string? Sha256, string EntryExe, string SignatureUrl);
}
