from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROGRAM = ROOT / "packaging" / "launcher" / "Program.cs"
MAKE_UPDATE = ROOT / "packaging" / "make-update.ps1"


class LauncherSourceGuardsTest(unittest.TestCase):
    def test_launcher_source_contains_signature_and_traversal_guards(self) -> None:
        source = PROGRAM.read_text(encoding="utf-8")

        self.assertIn("VerifyFileSignature(download, artifact.SignatureUrl, logger)", source)
        self.assertIn("Manifest signature verification failed.", source)
        self.assertIn("JsonDocument.Parse(StripUtf8Bom(payload))", source)
        self.assertIn("Zip entry rejected due to path traversal", source)
        self.assertIn("CompareVersions(manifest.Version, current.Version) > 0", source)
        self.assertIn('root.TryGetProperty("runtime_id"', source)
        self.assertIn('root.TryGetProperty("app_url"', source)
        self.assertIn("Installed runtime_id matches manifest runtime_id", source)
        self.assertIn("does not match manifest runtime_id", source)
        self.assertIn("Preparing update install for version", source)
        self.assertIn("Computed runtime_id", source)
        self.assertIn("App-only update for version", source)
        self.assertIn("Applied app-only update contents", source)
        self.assertIn('LocalDataSubdirEnv = "MONITOR_LOCAL_DATA_SUBDIR"', source)
        self.assertIn('UpdateArtifactPrefixEnv = "MONITOR_UPDATE_ARTIFACT_PREFIX"', source)
        self.assertIn("ResolveLocalDataSubdir()", source)
        self.assertIn("ResolveUpdateArtifactPrefix()", source)
        self.assertLess(source.index("LoadDotEnv(installDir)"), source.index("ResolveLocalDataSubdir()"))
        self.assertIn("FindBaselineZip(installDir, artifactPrefix)", source)
        self.assertIn('LastGoodFile = "last_good.json"', source)
        self.assertIn('LauncherHealthPathEnv = "MONITOR_LAUNCHER_HEALTH_PATH"', source)
        self.assertIn("CandidateHealthWindow = TimeSpan.FromSeconds(60)", source)
        self.assertIn("PromoteCandidateAfterHealth(installed, rollbackTarget", source)
        self.assertIn("WriteLastGood(runtimeDir, app.Version, folderName, logger)", source)
        self.assertIn("PruneRuntimeVersions(runtimeDir, folderName, rollbackFolderName, logger)", source)
        self.assertIn("Candidate did not freshly download estaciones.db and reportes.db.", source)
        self.assertNotIn("PruneRuntimeVersions(runtimeDir, Path.GetFileName(targetDir), logger)", source)
        self.assertNotIn("patch_from_version", source)
        self.assertNotIn("PatchArtifact", source)
        self.assertNotIn("patch.json", source)

    def test_update_manifest_is_written_without_bom(self) -> None:
        source = MAKE_UPDATE.read_text(encoding="utf-8")

        self.assertIn("System.Text.UTF8Encoding($false)", source)
        self.assertIn("Computed runtime_id", source)
        self.assertIn("Built app-only ZIP", source)
        self.assertIn("app_signature_url", source)
        self.assertNotIn("Set-Content -Path $manifestPath -Encoding UTF8", source)
        self.assertNotIn("patch_from_version", source)


if __name__ == "__main__":
    unittest.main()
