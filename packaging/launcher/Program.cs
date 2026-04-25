using System.Diagnostics;
using System.Drawing;
using System.IO.Compression;
using System.Collections.Generic;
using System.Net.Http;
using System.Security.Cryptography;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

static class Program
{
    private const string AppName = "MonitorSMS";
    private const string AppPrefix = "app-";
    private const string DefaultEntryExe = "MonitorSMS.exe";
    private const string ManifestEnv = "MONITOR_UPDATE_MANIFEST_URL";
    private const string SkipEnv = "MONITOR_SKIP_UPDATE";
    private const string CurrentFile = "current.json";
    private const string LastGoodFile = "last_good.json";
    private const string RuntimeDirName = "runtime";
    private const string StageDirName = "stage";
    private const string SignatureSuffix = ".sig";
    private const string UpdateSigningKeyResource = "MonitorSMSLauncher.update-signing-public-key.pem";
    private const string LauncherHealthPathEnv = "MONITOR_LAUNCHER_HEALTH_PATH";
    private const string LauncherHealthNonceEnv = "MONITOR_LAUNCHER_HEALTH_NONCE";
    private const string LauncherHealthVersionEnv = "MONITOR_LAUNCHER_HEALTH_VERSION";
    private const string LauncherRequireFreshDbEnv = "MONITOR_LAUNCHER_REQUIRE_FRESH_DB";
    private static readonly string BaselinePattern = "MonitorSMS-*.zip";
    private static readonly TimeSpan CandidateHealthWindow = TimeSpan.FromSeconds(60);

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
                WriteLastGood(runtimeDir, current.Version, Path.GetFileName(current.Path), logger);
            }
        }

        if (current is null)
        {
            current = TryMigrateLegacy(installDir, stateRoot, runtimeDir, logger);
        }

        if (current is not null)
        {
            EnsureLastGood(runtimeDir, current, logger);
        }

        var baselineZip = FindBaselineZip(installDir);
        if (current is null)
        {
            if (baselineZip is not null)
            {
                using var progress = new ProgressWindow("Installing MonitorSMS");
                progress.Show();
                progress.SetStatus("Installing baseline...");
                var baseline = InstallFromZip(baselineZip.Value.path, baselineZip.Value.version, installDir, runtimeDir, stageDir, DefaultEntryExe, cleanupZip: true, logger, progress);
                if (baseline is null)
                {
                    progress.CloseWindow();
                    ShowError("Baseline install failed. Check launcher.log for details.");
                    return 1;
                }
                PromoteInstalledApp(runtimeDir, baseline, rollbackFolderName: null, prune: false, logger);
                RemoveLegacyInstall(installDir, logger);
                progress.CloseWindow();
                return LaunchApp(Path.Combine(baseline.Path, DefaultEntryExe), installDir, Array.Empty<string>(), logger);
            }

            var manifestUrl = Environment.GetEnvironmentVariable(ManifestEnv);
            if (!string.IsNullOrWhiteSpace(manifestUrl))
            {
                var manifest = FetchManifest(manifestUrl, logger);
                if (manifest is not null)
                {
                    var installed = InstallFromManifest(manifest, installDir, runtimeDir, stageDir, current: null, logger);
                    if (installed is null)
                    {
                        ShowError("Update download failed and no baseline is available.");
                        return 1;
                    }
                    PromoteInstalledApp(runtimeDir, installed, rollbackFolderName: null, prune: false, logger);
                    RemoveLegacyInstall(installDir, logger);
                    return LaunchApp(Path.Combine(installed.Path, DefaultEntryExe), installDir, Array.Empty<string>(), logger);
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
                var installed = InstallFromManifest(manifest, installDir, runtimeDir, stageDir, current, logger);
                if (installed is null)
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
                var rollbackTarget = ReadLastGood(runtimeDir, logger);
                if (rollbackTarget is null || !IsValidInstalledApp(rollbackTarget.Path, DefaultEntryExe))
                {
                    rollbackTarget = current;
                }
                if (!PromoteCandidateAfterHealth(installed, rollbackTarget, installDir, runtimeDir, stageDir, logger))
                {
                    ShowError("Update rollback failed. Check launcher.log for details.");
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

    private static InstalledApp? InstallFromManifest(
        UpdateManifest manifest,
        string installDir,
        string runtimeDir,
        string stageDir,
        InstalledApp? current,
        LauncherLogger logger)
    {
        using var progress = new ProgressWindow("Updating MonitorSMS");
        progress.Show();
        logger.Info(
            manifest.Patch is null
                ? $"Preparing update install for version {manifest.Version} using full ZIP only."
                : $"Preparing update install for version {manifest.Version}; patch baseline is {manifest.Patch.FromVersion}.");
        InstalledApp? installed = null;
        if (current is not null &&
            manifest.Patch is not null &&
            string.Equals(current.Version, manifest.Patch.FromVersion, StringComparison.OrdinalIgnoreCase))
        {
            logger.Info($"Installed version {current.Version} matches patch baseline {manifest.Patch.FromVersion}; attempting patch update.");
            installed = InstallFromPatch(manifest, manifest.Patch, current, installDir, runtimeDir, stageDir, logger, progress);
            if (installed is not null)
            {
                progress.CloseWindow();
                return installed;
            }

            logger.Warn($"Patch update from {manifest.Patch.FromVersion} to {manifest.Version} failed; falling back to full ZIP.");
        }
        else if (current is not null && manifest.Patch is not null)
        {
            logger.Info($"Installed version {current.Version} does not match patch baseline {manifest.Patch.FromVersion}; using full ZIP.");
        }
        else if (current is null)
        {
            logger.Info("No installed runtime version is available for patch eligibility; using full ZIP.");
        }

        var fullArtifact = new UpdateArtifact(manifest.Url, manifest.Sha256, manifest.SignatureUrl);
        installed = InstallFromZipArtifact(fullArtifact, "full update", manifest.Version, installDir, runtimeDir, stageDir, manifest.EntryExe, logger, progress);
        progress.CloseWindow();
        return installed;
    }

    private static InstalledApp? InstallFromZipArtifact(
        UpdateArtifact artifact,
        string label,
        string version,
        string installDir,
        string runtimeDir,
        string stageDir,
        string entryExe,
        LauncherLogger logger,
        ProgressWindow? progress)
    {
        var download = DownloadVerifiedArtifact(artifact, label, stageDir, logger, progress);
        if (download is null)
        {
            return null;
        }

        progress?.SetStatus("Extracting update...");
        logger.Info($"Applying {label} for target version {version} using entry executable {entryExe}.");
        return InstallFromZip(download, version, installDir, runtimeDir, stageDir, entryExe, cleanupZip: true, logger, progress);
    }

    private static InstalledApp? InstallFromPatch(
        UpdateManifest manifest,
        PatchArtifact patch,
        InstalledApp current,
        string installDir,
        string runtimeDir,
        string stageDir,
        LauncherLogger logger,
        ProgressWindow? progress)
    {
        logger.Info($"Starting patch install from version {current.Version} to {manifest.Version} using {patch.Url}.");
        var download = DownloadVerifiedArtifact(
            new UpdateArtifact(patch.Url, patch.Sha256, patch.SignatureUrl),
            "patch update",
            stageDir,
            logger,
            progress);
        if (download is null)
        {
            return null;
        }

        try
        {
            progress?.SetStatus("Applying patch update...");
            return InstallFromPatchZip(download, manifest.Version, patch.FromVersion, current, runtimeDir, stageDir, logger, progress);
        }
        finally
        {
            SafeDelete(download);
        }
    }

    private static string? DownloadVerifiedArtifact(
        UpdateArtifact artifact,
        string label,
        string stageDir,
        LauncherLogger logger,
        ProgressWindow? progress)
    {
        logger.Info($"Downloading {label} from {artifact.Url}.");
        progress?.SetStatus($"Downloading {label}...");
        var download = DownloadToStage(artifact.Url, stageDir, logger, progress);
        if (download is null)
        {
            return null;
        }

        logger.Info($"Downloaded {label} to temporary file {download}.");
        progress?.SetStatus("Verifying signature...");
        progress?.SetIndeterminate();
        if (!VerifyFileSignature(download, artifact.SignatureUrl, logger))
        {
            SafeDelete(download);
            return null;
        }
        logger.Info($"Verified detached signature for {label}.");

        if (!string.IsNullOrWhiteSpace(artifact.Sha256))
        {
            progress?.SetStatus("Verifying download...");
            progress?.SetIndeterminate();
            var digest = Sha256File(download);
            if (!digest.Equals(artifact.Sha256, StringComparison.OrdinalIgnoreCase))
            {
                logger.Warn("SHA256 mismatch, skipping update.");
                SafeDelete(download);
                return null;
            }
            logger.Info($"Verified SHA256 for {label}: {digest}.");
        }
        else
        {
            logger.Info($"No SHA256 was provided for {label}; signature verification only.");
        }

        return download;
    }

    private static InstalledApp? InstallFromPatchZip(
        string patchZipPath,
        string version,
        string expectedFromVersion,
        InstalledApp current,
        string runtimeDir,
        string stageDir,
        LauncherLogger logger,
        ProgressWindow? progress)
    {
        InstalledApp? installed = null;
        string? stageRoot = null;
        string? targetDir = null;
        try
        {
            CloseRunningApp(DefaultEntryExe, logger);
            Directory.CreateDirectory(stageDir);
            stageRoot = Path.Combine(stageDir, Guid.NewGuid().ToString("N"));
            var extractRoot = Path.Combine(stageRoot, "extract");
            Directory.CreateDirectory(extractRoot);
            ExtractZipWithProgress(patchZipPath, extractRoot, progress, logger);

            var patchMetadata = ReadPatchMetadata(extractRoot, logger);
            if (patchMetadata is null)
            {
                return null;
            }
            logger.Info(
                $"Loaded patch metadata from {patchMetadata.FromVersion} to {patchMetadata.ToVersion} with {patchMetadata.DeletePaths.Length} delete path(s).");

            if (!string.Equals(patchMetadata.FromVersion, expectedFromVersion, StringComparison.OrdinalIgnoreCase) ||
                !string.Equals(patchMetadata.FromVersion, current.Version, StringComparison.OrdinalIgnoreCase))
            {
                logger.Warn($"Patch baseline version mismatch. Expected {expectedFromVersion}, found {patchMetadata.FromVersion}.");
                return null;
            }

            if (!string.Equals(patchMetadata.ToVersion, version, StringComparison.OrdinalIgnoreCase))
            {
                logger.Warn($"Patch target version mismatch. Expected {version}, found {patchMetadata.ToVersion}.");
                return null;
            }

            targetDir = Path.Combine(runtimeDir, $"{AppPrefix}{version}");
            if (Directory.Exists(targetDir))
            {
                Directory.Delete(targetDir, recursive: true);
            }

            progress?.SetStatus("Preparing base files...");
            progress?.SetIndeterminate();
            logger.Info($"Copying existing runtime from {current.Path} into candidate folder {targetDir}.");
            DirectoryCopy(current.Path, targetDir, true);

            progress?.SetStatus("Applying patch files...");
            progress?.SetIndeterminate();
            var overlaidFiles = OverlayDirectory(extractRoot, targetDir, logger);
            var deletedPaths = ApplyDeletePaths(targetDir, patchMetadata.DeletePaths, logger);
            logger.Info($"Applied {overlaidFiles} patched file(s) and removed {deletedPaths} stale path(s) for version {version}.");

            var entryExe = patchMetadata.EntryExe;
            if (string.IsNullOrWhiteSpace(entryExe))
            {
                logger.Warn("Patch metadata is missing entry_exe.");
                return null;
            }

            if (!IsValidInstalledApp(targetDir, entryExe))
            {
                logger.Warn($"Patched payload missing {entryExe} or _internal.");
                return null;
            }

            logger.Info($"Installed patched version {version} into {targetDir}");
            installed = new InstalledApp(version, targetDir);
            return installed;
        }
        catch (Exception ex)
        {
            logger.Warn($"Patch install failed: {ex.Message}");
            return null;
        }
        finally
        {
            if (installed is null && targetDir is not null)
            {
                try
                {
                    if (Directory.Exists(targetDir))
                    {
                        logger.Warn($"Removing incomplete patched candidate folder {targetDir}.");
                        Directory.Delete(targetDir, recursive: true);
                    }
                }
                catch
                {
                }
            }

            if (stageRoot is not null)
            {
                try
                {
                    logger.Info($"Cleaning patch staging folder {stageRoot}.");
                    Directory.Delete(stageRoot, recursive: true);
                }
                catch
                {
                }
            }
        }
    }

    private static PatchPackage? ReadPatchMetadata(string extractRoot, LauncherLogger logger)
    {
        var patchMetadataPath = Path.Combine(extractRoot, "patch.json");
        if (!File.Exists(patchMetadataPath))
        {
            logger.Warn("Patch payload is missing patch.json.");
            return null;
        }

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(patchMetadataPath, Encoding.UTF8));
            var root = doc.RootElement;
            var fromVersion = root.TryGetProperty("from_version", out var fromElement) ? fromElement.GetString() : null;
            var toVersion = root.TryGetProperty("to_version", out var toElement) ? toElement.GetString() : null;
            var entryExe = root.TryGetProperty("entry_exe", out var entryElement) ? entryElement.GetString() : null;
            if (string.IsNullOrWhiteSpace(fromVersion) || string.IsNullOrWhiteSpace(toVersion) || string.IsNullOrWhiteSpace(entryExe))
            {
                logger.Warn("Patch metadata is missing from_version, to_version, or entry_exe.");
                return null;
            }

            var deletePaths = new List<string>();
            if (root.TryGetProperty("delete_paths", out var deleteElement))
            {
                if (deleteElement.ValueKind != JsonValueKind.Array)
                {
                    logger.Warn("Patch metadata delete_paths is not an array.");
                    return null;
                }

                foreach (var item in deleteElement.EnumerateArray())
                {
                    if (item.ValueKind != JsonValueKind.String)
                    {
                        logger.Warn("Patch metadata delete_paths contains a non-string entry.");
                        return null;
                    }

                    var deletePath = item.GetString();
                    if (!string.IsNullOrWhiteSpace(deletePath))
                    {
                        deletePaths.Add(deletePath);
                    }
                }
            }

            logger.Info(
                $"Patch metadata validated for {fromVersion} -> {toVersion} with entry executable {entryExe} and {deletePaths.Count} delete path(s).");
            return new PatchPackage(fromVersion!, toVersion!, entryExe!, deletePaths.ToArray());
        }
        catch (Exception ex)
        {
            logger.Warn($"Failed to read patch metadata: {ex.Message}");
            return null;
        }
    }

    private static int OverlayDirectory(string sourceRoot, string targetRoot, LauncherLogger logger)
    {
        var copiedFiles = 0;
        foreach (var file in Directory.GetFiles(sourceRoot, "*", SearchOption.AllDirectories))
        {
            var relativePath = Path.GetRelativePath(sourceRoot, file);
            if (string.Equals(relativePath, "patch.json", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var destination = ResolveRelativePathWithinRoot(targetRoot, relativePath);
            if (destination is null)
            {
                logger.Warn($"Patch file rejected due to invalid relative path: {relativePath}");
                throw new InvalidDataException($"Patch file escapes runtime directory: {relativePath}");
            }

            var destinationDir = Path.GetDirectoryName(destination);
            if (!string.IsNullOrEmpty(destinationDir))
            {
                Directory.CreateDirectory(destinationDir);
            }

            File.Copy(file, destination, overwrite: true);
            copiedFiles++;
        }

        return copiedFiles;
    }

    private static int ApplyDeletePaths(string targetRoot, string[] deletePaths, LauncherLogger logger)
    {
        var removedPaths = 0;
        Array.Sort(deletePaths, (left, right) =>
        {
            var leftDepth = CountPathDepth(left);
            var rightDepth = CountPathDepth(right);
            return rightDepth.CompareTo(leftDepth);
        });

        foreach (var deletePath in deletePaths)
        {
            var fullPath = ResolveRelativePathWithinRoot(targetRoot, deletePath);
            if (fullPath is null)
            {
                logger.Warn($"Patch delete path rejected due to invalid relative path: {deletePath}");
                throw new InvalidDataException($"Patch delete path escapes runtime directory: {deletePath}");
            }

            if (File.Exists(fullPath))
            {
                File.Delete(fullPath);
                removedPaths++;
                continue;
            }

            if (Directory.Exists(fullPath))
            {
                Directory.Delete(fullPath, recursive: true);
                removedPaths++;
            }
        }

        return removedPaths;
    }

    private static int CountPathDepth(string relativePath)
    {
        var depth = 0;
        foreach (var character in relativePath)
        {
            if (character == '/' || character == '\\')
            {
                depth++;
            }
        }

        return depth;
    }

    private static string? ResolveRelativePathWithinRoot(string rootPath, string relativePath)
    {
        if (string.IsNullOrWhiteSpace(relativePath) || Path.IsPathRooted(relativePath))
        {
            return null;
        }

        var fullPath = Path.GetFullPath(Path.Combine(rootPath, relativePath));
        return IsPathWithinRoot(rootPath, fullPath) ? fullPath : null;
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
            PatchArtifact? patch = null;
            var patchFromVersion = root.TryGetProperty("patch_from_version", out var patchFromElement) ? patchFromElement.GetString() : null;
            var patchUrl = root.TryGetProperty("patch_url", out var patchUrlElement) ? patchUrlElement.GetString() : null;
            if (!string.IsNullOrWhiteSpace(patchFromVersion) || !string.IsNullOrWhiteSpace(patchUrl))
            {
                if (string.IsNullOrWhiteSpace(patchFromVersion) || string.IsNullOrWhiteSpace(patchUrl))
                {
                    logger.Warn("Manifest patch fields are incomplete; ignoring patch artifact.");
                }
                else
                {
                    var patchSha = root.TryGetProperty("patch_sha256", out var patchShaElement) ? patchShaElement.GetString() : null;
                    var patchSignatureUrl = root.TryGetProperty("patch_signature_url", out var patchSignatureElement) ? patchSignatureElement.GetString() : null;
                    patch = new PatchArtifact(
                        patchFromVersion!,
                        patchUrl!,
                        string.IsNullOrWhiteSpace(patchSha) ? null : patchSha,
                        string.IsNullOrWhiteSpace(patchSignatureUrl) ? BuildSignatureUrl(patchUrl!) : patchSignatureUrl!);
                }
            }

            return new UpdateManifest(
                version,
                download!,
                string.IsNullOrWhiteSpace(sha) ? null : sha,
                string.IsNullOrWhiteSpace(entry) ? DefaultEntryExe : entry!,
                string.IsNullOrWhiteSpace(downloadSignature) ? BuildSignatureUrl(download!) : downloadSignature!,
                patch
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

    private static InstalledApp? InstallFromZip(
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
        InstalledApp? installed = null;
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
                return null;
            }

            var sourceExe = Path.Combine(payloadRoot, entryExe);
            var sourceInternal = Path.Combine(payloadRoot, "_internal");
            if (!File.Exists(sourceExe) || !Directory.Exists(sourceInternal))
            {
                logger.Warn("Extracted payload missing MonitorSMS.exe or _internal.");
                return null;
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

            logger.Info($"Installed version {version} into {targetDir}");
            installed = new InstalledApp(version, targetDir);
            return installed;
        }
        catch (Exception ex)
        {
            logger.Warn($"Install failed: {ex.Message}");
            return null;
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
            if (cleanupZip && installed is not null)
            {
                SafeDelete(zipPath);
            }
        }
    }

    private static bool PromoteCandidateAfterHealth(
        InstalledApp candidate,
        InstalledApp previousGood,
        string installDir,
        string runtimeDir,
        string stageDir,
        LauncherLogger logger)
    {
        var candidateExe = Path.Combine(candidate.Path, DefaultEntryExe);
        logger.Info($"Launching candidate version {candidate.Version} for health verification.");
        var health = LaunchAndWaitForCandidateHealth(candidate, candidateExe, installDir, stageDir, logger);
        if (health.Succeeded)
        {
            logger.Info($"Candidate version {candidate.Version} passed the {CandidateHealthWindow.TotalSeconds:0}-second health window.");
            PromoteInstalledApp(
                runtimeDir,
                candidate,
                rollbackFolderName: Path.GetFileName(previousGood.Path),
                prune: true,
                logger);
            RemoveLegacyInstall(installDir, logger);
            SafeDelete(health.MarkerPath);
            return true;
        }

        logger.Warn($"Candidate version {candidate.Version} failed health verification: {health.Reason}");
        StopProcessTree(health.Process, logger);
        WriteCurrent(runtimeDir, previousGood.Version, Path.GetFileName(previousGood.Path), logger);
        WriteLastGood(runtimeDir, previousGood.Version, Path.GetFileName(previousGood.Path), logger);

        var rollbackExe = Path.Combine(previousGood.Path, DefaultEntryExe);
        logger.Warn($"Rolling back to last good version {previousGood.Version} at {previousGood.Path}.");
        return LaunchApp(rollbackExe, installDir, Array.Empty<string>(), logger) == 0;
    }

    private static CandidateHealthResult LaunchAndWaitForCandidateHealth(
        InstalledApp candidate,
        string candidateExe,
        string installDir,
        string stageDir,
        LauncherLogger logger)
    {
        Directory.CreateDirectory(stageDir);
        var healthDir = Path.Combine(stageDir, "health");
        Directory.CreateDirectory(healthDir);
        var nonce = Guid.NewGuid().ToString("N");
        var markerPath = Path.Combine(healthDir, $"candidate-health-{nonce}.json");
        SafeDelete(markerPath);

        var launchedAt = DateTimeOffset.UtcNow;
        var env = new Dictionary<string, string>
        {
            [LauncherHealthPathEnv] = markerPath,
            [LauncherHealthNonceEnv] = nonce,
            [LauncherHealthVersionEnv] = candidate.Version,
            [LauncherRequireFreshDbEnv] = "1"
        };
        var process = StartAppProcess(candidateExe, installDir, Array.Empty<string>(), logger, env);
        if (process is null)
        {
            return new CandidateHealthResult(false, "Candidate process failed to start.", null, markerPath);
        }

        var deadline = launchedAt + CandidateHealthWindow;
        var healthySeen = false;
        var lastReason = "Health marker was not written.";
        while (DateTimeOffset.UtcNow < deadline)
        {
            Application.DoEvents();
            if (File.Exists(markerPath))
            {
                var marker = ReadCandidateHealthMarker(markerPath, candidate.Version, nonce, launchedAt, requireFreshDb: true, logger);
                if (marker.State == HealthMarkerState.Invalid || marker.State == HealthMarkerState.Unhealthy)
                {
                    return new CandidateHealthResult(false, marker.Reason, process, markerPath);
                }
                if (marker.State == HealthMarkerState.Healthy)
                {
                    healthySeen = true;
                    lastReason = marker.Reason;
                }
            }

            if (process.HasExited)
            {
                return new CandidateHealthResult(false, $"Candidate process exited before promotion. {lastReason}", process, markerPath);
            }
            Thread.Sleep(500);
        }

        if (!healthySeen)
        {
            return new CandidateHealthResult(false, lastReason, process, markerPath);
        }
        if (process.HasExited)
        {
            return new CandidateHealthResult(false, "Candidate process exited at the end of the health window.", process, markerPath);
        }
        return new CandidateHealthResult(true, "Candidate stayed healthy through the promotion window.", process, markerPath);
    }

    private static HealthMarkerResult ReadCandidateHealthMarker(
        string markerPath,
        string expectedVersion,
        string expectedNonce,
        DateTimeOffset launchedAt,
        bool requireFreshDb,
        LauncherLogger logger)
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(markerPath, Encoding.UTF8));
            var root = doc.RootElement;
            var version = root.TryGetProperty("version", out var versionElement) ? versionElement.GetString() : null;
            var nonce = root.TryGetProperty("nonce", out var nonceElement) ? nonceElement.GetString() : null;
            if (!string.Equals(version, expectedVersion, StringComparison.OrdinalIgnoreCase))
            {
                return new HealthMarkerResult(HealthMarkerState.Invalid, "Health marker version did not match the candidate version.");
            }
            if (!string.Equals(nonce, expectedNonce, StringComparison.Ordinal))
            {
                return new HealthMarkerResult(HealthMarkerState.Invalid, "Health marker nonce did not match this launch.");
            }

            if (!root.TryGetProperty("reported_at_utc", out var reportedAtElement) ||
                !DateTimeOffset.TryParse(reportedAtElement.GetString(), out var reportedAt))
            {
                return new HealthMarkerResult(HealthMarkerState.Invalid, "Health marker is missing a valid reported_at_utc value.");
            }
            if (reportedAt < launchedAt.AddSeconds(-5))
            {
                return new HealthMarkerResult(HealthMarkerState.Invalid, "Health marker was older than this candidate launch.");
            }

            var status = root.TryGetProperty("status", out var statusElement) ? statusElement.GetString() : null;
            var reason = root.TryGetProperty("reason", out var reasonElement) ? reasonElement.GetString() : null;
            if (string.Equals(status, "unhealthy", StringComparison.OrdinalIgnoreCase))
            {
                return new HealthMarkerResult(HealthMarkerState.Unhealthy, string.IsNullOrWhiteSpace(reason) ? "Candidate app reported unhealthy startup." : reason!);
            }
            if (!string.Equals(status, "healthy", StringComparison.OrdinalIgnoreCase))
            {
                return new HealthMarkerResult(HealthMarkerState.Invalid, "Health marker status was not healthy.");
            }

            if (requireFreshDb)
            {
                var freshEstaciones = root.TryGetProperty("fresh_estaciones", out var estacionesElement) &&
                    estacionesElement.ValueKind == JsonValueKind.True;
                var freshReportes = root.TryGetProperty("fresh_reportes", out var reportesElement) &&
                    reportesElement.ValueKind == JsonValueKind.True;
                if (!freshEstaciones || !freshReportes)
                {
                    return new HealthMarkerResult(HealthMarkerState.Unhealthy, "Candidate did not freshly download estaciones.db and reportes.db.");
                }
            }

            return new HealthMarkerResult(HealthMarkerState.Healthy, string.IsNullOrWhiteSpace(reason) ? "Candidate reported healthy startup." : reason!);
        }
        catch (IOException ex)
        {
            logger.Warn($"Unable to read candidate health marker yet: {ex.Message}");
            return new HealthMarkerResult(HealthMarkerState.Pending, "Health marker is not readable yet.");
        }
        catch (JsonException ex)
        {
            logger.Warn($"Candidate health marker is not valid JSON yet: {ex.Message}");
            return new HealthMarkerResult(HealthMarkerState.Pending, "Health marker is not parseable yet.");
        }
        catch (Exception ex)
        {
            return new HealthMarkerResult(HealthMarkerState.Invalid, $"Health marker rejected: {ex.Message}");
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
        return StartAppProcess(appExe, installDir, args, logger, environment: null) is null ? 1 : 0;
    }

    private static Process? StartAppProcess(
        string appExe,
        string installDir,
        string[] args,
        LauncherLogger logger,
        IReadOnlyDictionary<string, string>? environment)
    {
        if (!File.Exists(appExe))
        {
            logger.Error($"Executable not found: {appExe}");
            return null;
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
            if (environment is not null)
            {
                foreach (var item in environment)
                {
                    startInfo.Environment[item.Key] = item.Value;
                }
            }
            return Process.Start(startInfo);
        }
        catch (Exception ex)
        {
            logger.Error($"Failed to launch app: {ex.Message}");
            return null;
        }
    }

    private static void StopProcessTree(Process? process, LauncherLogger logger)
    {
        if (process is null)
        {
            return;
        }
        try
        {
            if (!process.HasExited)
            {
                logger.Warn($"Stopping failed candidate process (PID {process.Id}).");
                process.Kill(entireProcessTree: true);
                process.WaitForExit(5000);
            }
        }
        catch (Exception ex)
        {
            logger.Warn($"Failed to stop candidate process: {ex.Message}");
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

    private static void WriteLastGood(string runtimeDir, string version, string folderName, LauncherLogger logger)
    {
        try
        {
            Directory.CreateDirectory(runtimeDir);
            var payload = JsonSerializer.Serialize(new
            {
                version,
                path = folderName,
                promoted_at_utc = DateTimeOffset.UtcNow.ToString("O")
            });
            File.WriteAllText(Path.Combine(runtimeDir, LastGoodFile), payload);
        }
        catch (Exception ex)
        {
            logger.Warn($"Failed to write last_good.json: {ex.Message}");
        }
    }

    private static void PromoteInstalledApp(
        string runtimeDir,
        InstalledApp app,
        string? rollbackFolderName,
        bool prune,
        LauncherLogger logger)
    {
        var folderName = Path.GetFileName(app.Path);
        WriteCurrent(runtimeDir, app.Version, folderName, logger);
        WriteLastGood(runtimeDir, app.Version, folderName, logger);
        if (prune)
        {
            PruneRuntimeVersions(runtimeDir, folderName, rollbackFolderName, logger);
        }
    }

    private static void EnsureLastGood(string runtimeDir, InstalledApp current, LauncherLogger logger)
    {
        var lastGood = ReadLastGood(runtimeDir, logger);
        if (lastGood is not null && IsValidInstalledApp(lastGood.Path, DefaultEntryExe))
        {
            return;
        }

        logger.Info($"Seeding last_good.json from current version {current.Version}.");
        WriteLastGood(runtimeDir, current.Version, Path.GetFileName(current.Path), logger);
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

    private static InstalledApp? ReadLastGood(string runtimeDir, LauncherLogger logger)
    {
        var path = Path.Combine(runtimeDir, LastGoodFile);
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
            logger.Warn($"Failed to read last_good.json: {ex.Message}");
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

    private static void PruneRuntimeVersions(string runtimeDir, string currentFolderName, string? rollbackFolderName, LauncherLogger logger)
    {
        if (!Directory.Exists(runtimeDir))
        {
            return;
        }

        rollbackFolderName = ResolveRollbackFolder(runtimeDir, currentFolderName, rollbackFolderName);
        var keepFolders = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            currentFolderName
        };
        if (!string.IsNullOrWhiteSpace(rollbackFolderName))
        {
            keepFolders.Add(rollbackFolderName);
        }

        foreach (var dir in Directory.GetDirectories(runtimeDir, $"{AppPrefix}*"))
        {
            var name = Path.GetFileName(dir);
            if (!string.IsNullOrWhiteSpace(name) && keepFolders.Contains(name))
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

    private static string? ResolveRollbackFolder(string runtimeDir, string currentFolderName, string? requestedRollbackFolderName)
    {
        if (!string.IsNullOrWhiteSpace(requestedRollbackFolderName))
        {
            var requestedPath = Path.Combine(runtimeDir, requestedRollbackFolderName);
            if (!string.Equals(requestedRollbackFolderName, currentFolderName, StringComparison.OrdinalIgnoreCase) &&
                IsValidInstalledApp(requestedPath, DefaultEntryExe))
            {
                return requestedRollbackFolderName;
            }
        }

        var currentVersion = currentFolderName.StartsWith(AppPrefix, StringComparison.OrdinalIgnoreCase)
            ? currentFolderName[AppPrefix.Length..]
            : "";
        InstalledApp? bestPrevious = null;
        InstalledApp? bestFallback = null;
        foreach (var app in ScanInstalled(runtimeDir))
        {
            var folderName = Path.GetFileName(app.Path);
            if (string.Equals(folderName, currentFolderName, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            if (bestFallback is null || CompareVersions(app.Version, bestFallback.Version) > 0)
            {
                bestFallback = app;
            }
            if (!string.IsNullOrWhiteSpace(currentVersion) && CompareVersions(app.Version, currentVersion) < 0)
            {
                if (bestPrevious is null || CompareVersions(app.Version, bestPrevious.Version) > 0)
                {
                    bestPrevious = app;
                }
            }
        }

        var selected = bestPrevious ?? bestFallback;
        return selected is null ? null : Path.GetFileName(selected.Path);
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
            WriteLastGood(runtimeDir, version, Path.GetFileName(targetDir), logger);
            PruneRuntimeVersions(runtimeDir, Path.GetFileName(targetDir), rollbackFolderName: null, logger);
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

    private enum HealthMarkerState
    {
        Pending,
        Healthy,
        Unhealthy,
        Invalid
    }

    private sealed record CandidateHealthResult(bool Succeeded, string Reason, Process? Process, string MarkerPath);
    private sealed record HealthMarkerResult(HealthMarkerState State, string Reason);
    private sealed record InstalledApp(string Version, string Path);
    private sealed record UpdateArtifact(string Url, string? Sha256, string SignatureUrl);
    private sealed record PatchArtifact(string FromVersion, string Url, string? Sha256, string SignatureUrl);
    private sealed record PatchPackage(string FromVersion, string ToVersion, string EntryExe, string[] DeletePaths);
    private sealed record UpdateManifest(string Version, string Url, string? Sha256, string EntryExe, string SignatureUrl, PatchArtifact? Patch);
}
