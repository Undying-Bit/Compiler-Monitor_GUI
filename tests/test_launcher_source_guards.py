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
        self.assertIn('root.TryGetProperty("patch_from_version"', source)
        self.assertIn("Patch update from", source)
        self.assertIn("Installed version {current.Version} matches patch baseline", source)
        self.assertIn("does not match patch baseline", source)
        self.assertIn("Preparing update install for version", source)
        self.assertIn("Applied {overlaidFiles} patched file(s) and removed {deletedPaths} stale path(s)", source)
        self.assertIn('Path.Combine(extractRoot, "patch.json")', source)
        self.assertIn("Patch delete path rejected due to invalid relative path", source)
        self.assertIn('LastGoodFile = "last_good.json"', source)
        self.assertIn('LauncherHealthPathEnv = "MONITOR_LAUNCHER_HEALTH_PATH"', source)
        self.assertIn("CandidateHealthWindow = TimeSpan.FromSeconds(60)", source)
        self.assertIn("PromoteCandidateAfterHealth(installed, rollbackTarget", source)
        self.assertIn("WriteLastGood(runtimeDir, app.Version, folderName, logger)", source)
        self.assertIn("PruneRuntimeVersions(runtimeDir, folderName, rollbackFolderName, logger)", source)
        self.assertIn("Candidate did not freshly download estaciones.db and reportes.db.", source)
        self.assertNotIn("PruneRuntimeVersions(runtimeDir, Path.GetFileName(targetDir), logger)", source)

    def test_update_manifest_is_written_without_bom(self) -> None:
        source = MAKE_UPDATE.read_text(encoding="utf-8")

        self.assertIn("System.Text.UTF8Encoding($false)", source)
        self.assertIn("No previous full artifact found for version", source)
        self.assertIn("Patch diff includes", source)
        self.assertNotIn("Set-Content -Path $manifestPath -Encoding UTF8", source)


if __name__ == "__main__":
    unittest.main()
