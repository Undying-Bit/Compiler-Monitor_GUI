from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROGRAM = ROOT / "packaging" / "launcher" / "Program.cs"
MAKE_UPDATE = ROOT / "packaging" / "make-update.ps1"


class LauncherSourceGuardsTest(unittest.TestCase):
    def test_launcher_source_contains_signature_and_traversal_guards(self) -> None:
        source = PROGRAM.read_text(encoding="utf-8")

        self.assertIn("VerifyFileSignature(download, manifest.SignatureUrl, logger)", source)
        self.assertIn("Manifest signature verification failed.", source)
        self.assertIn("JsonDocument.Parse(StripUtf8Bom(payload))", source)
        self.assertIn("Zip entry rejected due to path traversal", source)
        self.assertIn("CompareVersions(manifest.Version, current.Version) > 0", source)

    def test_update_manifest_is_written_without_bom(self) -> None:
        source = MAKE_UPDATE.read_text(encoding="utf-8")

        self.assertIn("System.Text.UTF8Encoding($false)", source)
        self.assertNotIn("Set-Content -Path $manifestPath -Encoding UTF8", source)


if __name__ == "__main__":
    unittest.main()
