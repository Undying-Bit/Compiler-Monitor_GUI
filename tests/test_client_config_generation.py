from __future__ import annotations

import os
import shutil
import subprocess
import unittest
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "packaging" / "new-client-config.ps1"


class ClientConfigGenerationTest(unittest.TestCase):
    def _run_config(self, output_path: Path, *extra_args: str, env: dict[str, str] | None = None) -> None:
        run_env = os.environ.copy()
        run_env.update(
            {
                "MONITOR_PRIMARY_BASE_URL": "https://updates.example.com/data",
                "MONITOR_BACKUP_BASE_URL": "https://backup.example.com/data",
                "MONITOR_UPDATE_MANIFEST_URL": "https://updates.example.com/updates/latest.json",
            }
        )
        if env:
            run_env.update(env)

        subprocess.run(
            [
                "powershell",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(SCRIPT),
                "-OutputPath",
                str(output_path),
                *extra_args,
            ],
            check=True,
            cwd=ROOT,
            env=run_env,
        )

    def test_generated_installer_config_contains_only_safe_allowlist(self) -> None:
        scratch_root = ROOT / ".tmp" / "test-client-config"
        output_dir = scratch_root / uuid.uuid4().hex
        output_dir.mkdir(parents=True, exist_ok=True)
        self.addCleanup(lambda: shutil.rmtree(output_dir, ignore_errors=True))
        output_path = output_dir / ".env"
        env = os.environ.copy()
        env.update(
            {
                "MONITOR_PRIMARY_BASE_URL": "https://updates.example.com/data",
                "MONITOR_BACKUP_BASE_URL": "https://backup.example.com/data",
                "MONITOR_UPDATE_MANIFEST_URL": "https://updates.example.com/updates/latest.json",
                "MONITOR_R2_ACCESS_KEY": "SHOULD_NOT_LEAK",
                "MONITOR_R2_SECRET_KEY": "TOP_SECRET",
                "UPDATE_R2_ACCESS_KEY": "UPLOAD_ONLY",
            }
        )

        self._run_config(output_path, env=env)

        rendered = output_path.read_text(encoding="utf-8")
        self.assertIn("MONITOR_PRIMARY_BASE_URL=https://updates.example.com/data", rendered)
        self.assertIn("MONITOR_UPDATE_MANIFEST_URL=https://updates.example.com/updates/latest.json", rendered)
        self.assertNotIn("MONITOR_R2_ACCESS_KEY", rendered)
        self.assertNotIn("MONITOR_R2_SECRET_KEY", rendered)
        self.assertNotIn("UPDATE_R2_ACCESS_KEY", rendered)
        self.assertNotIn("SHOULD_NOT_LEAK", rendered)
        self.assertNotIn("TOP_SECRET", rendered)

    def test_debug_panel_visible_accepts_powershell_file_string_arguments(self) -> None:
        scratch_root = ROOT / ".tmp" / "test-client-config"
        output_dir = scratch_root / uuid.uuid4().hex
        output_dir.mkdir(parents=True, exist_ok=True)
        self.addCleanup(lambda: shutil.rmtree(output_dir, ignore_errors=True))

        cases = {
            "false": "false",
            "true": "true",
            "0": "false",
            "1": "true",
        }
        for raw_value, expected in cases.items():
            with self.subTest(raw_value=raw_value):
                output_path = output_dir / f"{raw_value}.env"
                self._run_config(output_path, "-DebugPanelVisible", raw_value)

                rendered = output_path.read_text(encoding="utf-8")
                self.assertIn(f"MONITOR_DEBUG_PANEL_VISIBLE={expected}", rendered)


if __name__ == "__main__":
    unittest.main()
