from __future__ import annotations

import os
import shutil
import subprocess
import unittest
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WRAPPERS = ROOT / "packaging" / "wrappers"
MISSING_LOCAL_ENV = ROOT / ".tmp" / "test-wrapper-entrypoints" / "missing-local.env"

CONFIG_NAMES = {
    "MONITOR_UPDATE_SIGNING_PUBLIC_KEY_PATH",
    "MONITOR_UPDATE_SIGNING_KEY_PATH",
    "MONITOR_UPDATE_BASE_URL",
    "MONITOR_PRIMARY_BASE_URL",
    "MONITOR_BACKUP_BASE_URL",
    "MONITOR_UPDATE_MANIFEST_URL",
    "MONITOR_KEY_ESTACIONES",
    "MONITOR_KEY_REPORTES",
    "MONITOR_DEBUG_PANEL_VISIBLE",
    "UPDATE_R2_ENDPOINT",
    "UPDATE_R2_BUCKET",
    "UPDATE_R2_ACCESS_KEY",
    "UPDATE_R2_SECRET_KEY",
    "UPDATE_R2_REGION",
    "UPDATE_R2_SESSION_TOKEN",
    "UPDATE_R2_PREFIX",
    "UPDATE_R2_USE_SSL",
    "UPDATE_R2_VERIFY_TLS",
}


class WrapperEntrypointsTest(unittest.TestCase):
    def _clean_env(self) -> dict[str, str]:
        env = os.environ.copy()
        for name in CONFIG_NAMES:
            env.pop(name, None)
        return env

    def _run_wrapper_without_config(self, script_name: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(WRAPPERS / script_name),
                "-LocalEnvPath",
                str(MISSING_LOCAL_ENV),
            ],
            cwd=ROOT,
            env=self._clean_env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )

    def test_build_all_missing_config_fails_before_building_app(self) -> None:
        result = self._run_wrapper_without_config("build-all.ps1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing required configuration", result.stdout)
        self.assertIn("MONITOR_UPDATE_SIGNING_PUBLIC_KEY_PATH", result.stdout)
        self.assertIn("MONITOR_UPDATE_SIGNING_KEY_PATH", result.stdout)
        self.assertIn("MONITOR_PRIMARY_BASE_URL", result.stdout)
        self.assertIn("MONITOR_UPDATE_MANIFEST_URL", result.stdout)
        self.assertNotIn("build-app.ps1", result.stdout)
        self.assertNotIn("PyInstaller", result.stdout)

    def test_launcher_missing_public_key_fails_before_dotnet_publish(self) -> None:
        result = self._run_wrapper_without_config("build-launcher-msi.ps1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing required configuration", result.stdout)
        self.assertIn("MONITOR_UPDATE_SIGNING_PUBLIC_KEY_PATH", result.stdout)
        self.assertNotIn("build-launcher.ps1", result.stdout)
        self.assertNotIn("dotnet", result.stdout.lower())

    def test_upload_missing_credentials_fails_before_upload_script(self) -> None:
        result = self._run_wrapper_without_config("upload-update.ps1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing required configuration", result.stdout)
        self.assertIn("UPDATE_R2_ENDPOINT", result.stdout)
        self.assertIn("UPDATE_R2_BUCKET", result.stdout)
        self.assertIn("UPDATE_R2_ACCESS_KEY", result.stdout)
        self.assertIn("UPDATE_R2_SECRET_KEY", result.stdout)
        self.assertNotIn(">>>", result.stdout)
        self.assertNotIn("Upload complete", result.stdout)

    def test_root_batch_files_use_expected_wrappers_and_forward_args(self) -> None:
        expectations = {
            "run-build-all.bat": "packaging\\wrappers\\build-all.ps1",
            "run-build-launcher-msi.bat": "packaging\\wrappers\\build-launcher-msi.ps1",
            "run-upload-update.bat": "packaging\\wrappers\\upload-update.ps1",
        }

        for bat_name, wrapper_path in expectations.items():
            with self.subTest(bat_name=bat_name):
                content = (ROOT / bat_name).read_text(encoding="utf-8")
                self.assertIn("-NoProfile", content)
                self.assertIn(wrapper_path, content)
                self.assertIn("%*", content)

    def test_local_env_is_ignored_but_template_is_tracked_content(self) -> None:
        gitignore = (ROOT / ".gitignore").read_text(encoding="utf-8")
        template = (ROOT / "packaging" / "local.env.template").read_text(encoding="utf-8")

        self.assertIn("/packaging/local.env", gitignore)
        self.assertIn("MONITOR_UPDATE_SIGNING_PUBLIC_KEY_PATH=", template)
        self.assertIn("UPDATE_R2_SECRET_KEY=", template)

    def test_common_loads_local_env_without_overriding_process_env(self) -> None:
        scratch_root = ROOT / ".tmp" / "test-wrapper-entrypoints"
        work_dir = scratch_root / uuid.uuid4().hex
        work_dir.mkdir(parents=True, exist_ok=True)
        self.addCleanup(lambda: shutil.rmtree(work_dir, ignore_errors=True))

        local_env = work_dir / "local.env"
        local_env.write_text(
            "\n".join(
                [
                    "# local wrapper config",
                    "MONITOR_PRIMARY_BASE_URL=https://local.example/data",
                    'MONITOR_UPDATE_MANIFEST_URL="https://local.example/updates/latest.json" # comment',
                    "MONITOR_UPDATE_SIGNING_PUBLIC_KEY_PATH='.tmp\\signer-test\\monitor-update-public.pem'",
                ]
            ),
            encoding="utf-8",
        )

        env = self._clean_env()
        env["MONITOR_PRIMARY_BASE_URL"] = "https://process.example/data"
        command = (
            f". '{WRAPPERS / 'common.ps1'}'; "
            f"Initialize-PackagingWrapper -ScriptRoot '{WRAPPERS}' -LocalEnvPath '{local_env}' | Out-Null; "
            "$base = Resolve-UpdateBaseUrl; "
            "Write-Output \"PRIMARY=$env:MONITOR_PRIMARY_BASE_URL\"; "
            "Write-Output \"MANIFEST=$env:MONITOR_UPDATE_MANIFEST_URL\"; "
            "Write-Output \"BASE=$base\"; "
            "Write-Output \"KEY=$env:MONITOR_UPDATE_SIGNING_PUBLIC_KEY_PATH\""
        )

        result = subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                command,
            ],
            cwd=ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=True,
        )

        self.assertIn("PRIMARY=https://process.example/data", result.stdout)
        self.assertIn("MANIFEST=https://local.example/updates/latest.json", result.stdout)
        self.assertIn("BASE=https://local.example/updates", result.stdout)
        self.assertIn("KEY=.tmp\\signer-test\\monitor-update-public.pem", result.stdout)


if __name__ == "__main__":
    unittest.main()
