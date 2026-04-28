from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class MakeUpdateScriptTest(unittest.TestCase):
    def test_make_update_archives_versioned_manifests_without_removing_older_versions(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            temp_root = Path(tmp)
            repo_root = temp_root / "repo"
            packaging_root = repo_root / "packaging"
            source_root = temp_root / "source"
            dist_root = repo_root / "dist" / "MonitorSMS"
            fake_bin = temp_root / "bin"
            key_path = temp_root / "monitor-update-private.pem"

            (packaging_root / "signer").mkdir(parents=True, exist_ok=True)
            dist_root.mkdir(parents=True, exist_ok=True)
            (dist_root / "_internal").mkdir(parents=True, exist_ok=True)
            (dist_root / "_internal" / "station_monitor_assets").mkdir(parents=True, exist_ok=True)
            (source_root / "src" / "station_monitor").mkdir(parents=True, exist_ok=True)
            fake_bin.mkdir(parents=True, exist_ok=True)

            shutil.copy2(ROOT / "packaging" / "make-update.ps1", packaging_root / "make-update.ps1")
            shutil.copy2(ROOT / "packaging" / "paths.ps1", packaging_root / "paths.ps1")
            shutil.copy2(ROOT / "packaging" / "channel.ps1", packaging_root / "channel.ps1")
            (packaging_root / "signer" / "MonitorSMSSigner.csproj").write_text("<Project />\n", encoding="utf-8")

            (dist_root / "MonitorSMS.exe").write_bytes(b"exe")
            (dist_root / "_internal" / "runtime.dll").write_text("runtime\n", encoding="utf-8")
            (dist_root / "_internal" / "station_monitor_assets" / "app.ico").write_text("icon-v1\n", encoding="utf-8")
            (source_root / "pyproject.toml").write_text('version = "0.0.0"\n', encoding="utf-8")
            (source_root / "src" / "station_monitor" / "main.py").write_text("print('ok')\n", encoding="utf-8")
            key_path.write_text("dummy-private-key\n", encoding="utf-8")

            fake_dotnet = fake_bin / "dotnet.cmd"
            fake_dotnet.write_text(
                "\n".join(
                    [
                        "@echo off",
                        "setlocal EnableDelayedExpansion",
                        'set "output="',
                        'set "input="',
                        ":loop",
                        'if "%~1"=="" goto done',
                        'if /I "%~1"=="--output" (',
                        '  set "output=%~2"',
                        "  shift",
                        ') else if /I "%~1"=="--input" (',
                        '  set "input=%~2"',
                        "  shift",
                        ")",
                        "shift",
                        "goto loop",
                        ":done",
                        "if not defined output exit /b 1",
                        '> "%output%" echo signed:!input!',
                        "exit /b 0",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            env = os.environ.copy()
            env["PATH"] = str(fake_bin) + os.pathsep + env.get("PATH", "")
            env["MONITOR_GUI_ROOT"] = str(source_root)

            self._run_make_update(repo_root, source_root, key_path, "0.2.10", env, channel="release")
            (dist_root / "MonitorSMS.exe").write_bytes(b"exe-v2")
            (dist_root / "_internal" / "station_monitor_assets" / "app.ico").write_text("icon-v2\n", encoding="utf-8")
            self._run_make_update(repo_root, source_root, key_path, "0.2.11", env, channel="release")

            artifacts_root = packaging_root / "artifacts"
            manifests_root = artifacts_root / "manifests"
            latest_artifacts_dir = artifacts_root / "MonitorSMS-0.2.11"
            app_zip = latest_artifacts_dir / "MonitorSMS-0.2.11-app.zip"
            app_zip_sig = latest_artifacts_dir / "MonitorSMS-0.2.11-app.zip.sig"

            self.assertTrue((latest_artifacts_dir / "latest.json").exists())
            self.assertTrue((latest_artifacts_dir / "latest.json.sig").exists())
            self.assertTrue((manifests_root / "MonitorSMS-0.2.10.json").exists())
            self.assertTrue((manifests_root / "MonitorSMS-0.2.10.json.sig").exists())
            self.assertTrue((manifests_root / "MonitorSMS-0.2.11.json").exists())
            self.assertTrue((manifests_root / "MonitorSMS-0.2.11.json.sig").exists())
            self.assertTrue(app_zip.exists())
            self.assertTrue(app_zip_sig.exists())

            latest_manifest = json.loads((latest_artifacts_dir / "latest.json").read_text(encoding="utf-8"))
            archived_old_manifest = json.loads((manifests_root / "MonitorSMS-0.2.10.json").read_text(encoding="utf-8"))
            archived_new_manifest = json.loads((manifests_root / "MonitorSMS-0.2.11.json").read_text(encoding="utf-8"))

            self.assertEqual(latest_manifest["version"], "0.2.11")
            self.assertEqual(archived_old_manifest["version"], "0.2.10")
            self.assertEqual(archived_new_manifest["version"], "0.2.11")
            self.assertIn("runtime_id", latest_manifest)
            self.assertEqual(archived_old_manifest["runtime_id"], archived_new_manifest["runtime_id"])
            self.assertEqual(
                latest_manifest["app_url"],
                "https://updates.example.com/updates/MonitorSMS-0.2.11-app.zip",
            )
            self.assertEqual(
                latest_manifest["app_signature_url"],
                "https://updates.example.com/updates/MonitorSMS-0.2.11-app.zip.sig",
            )
            self.assertEqual(len(latest_manifest["runtime_id"]), 64)

            with zipfile.ZipFile(app_zip) as archive:
                names = set(archive.namelist())
            self.assertIn("MonitorSMS.exe", names)
            self.assertIn("_internal/station_monitor_assets/app.ico", names)
            self.assertNotIn("_internal/runtime.dll", names)

    def test_make_update_development_channel_prefixes_versioned_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            temp_root = Path(tmp)
            repo_root = temp_root / "repo"
            packaging_root = repo_root / "packaging"
            source_root = temp_root / "source"
            dist_root = repo_root / "dist" / "MonitorSMS"
            fake_bin = temp_root / "bin"
            key_path = temp_root / "monitor-update-private.pem"

            (packaging_root / "signer").mkdir(parents=True, exist_ok=True)
            dist_root.mkdir(parents=True, exist_ok=True)
            (dist_root / "_internal").mkdir(parents=True, exist_ok=True)
            (dist_root / "_internal" / "station_monitor_assets").mkdir(parents=True, exist_ok=True)
            (source_root / "src" / "station_monitor").mkdir(parents=True, exist_ok=True)
            fake_bin.mkdir(parents=True, exist_ok=True)

            shutil.copy2(ROOT / "packaging" / "make-update.ps1", packaging_root / "make-update.ps1")
            shutil.copy2(ROOT / "packaging" / "paths.ps1", packaging_root / "paths.ps1")
            shutil.copy2(ROOT / "packaging" / "channel.ps1", packaging_root / "channel.ps1")
            (packaging_root / "signer" / "MonitorSMSSigner.csproj").write_text("<Project />\n", encoding="utf-8")

            (dist_root / "MonitorSMS.exe").write_bytes(b"exe")
            (dist_root / "_internal" / "runtime.dll").write_text("runtime\n", encoding="utf-8")
            (dist_root / "_internal" / "station_monitor_assets" / "app.ico").write_text("icon\n", encoding="utf-8")
            (source_root / "pyproject.toml").write_text('version = "0.0.0"\n', encoding="utf-8")
            (source_root / "src" / "station_monitor" / "main.py").write_text("print('ok')\n", encoding="utf-8")
            key_path.write_text("dummy-private-key\n", encoding="utf-8")

            fake_dotnet = fake_bin / "dotnet.cmd"
            fake_dotnet.write_text(
                "\n".join(
                    [
                        "@echo off",
                        "setlocal EnableDelayedExpansion",
                        'set "output="',
                        'set "input="',
                        ":loop",
                        'if "%~1"=="" goto done',
                        'if /I "%~1"=="--output" (',
                        '  set "output=%~2"',
                        "  shift",
                        ') else if /I "%~1"=="--input" (',
                        '  set "input=%~2"',
                        "  shift",
                        ")",
                        "shift",
                        "goto loop",
                        ":done",
                        "if not defined output exit /b 1",
                        '> "%output%" echo signed:!input!',
                        "exit /b 0",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            env = os.environ.copy()
            env["PATH"] = str(fake_bin) + os.pathsep + env.get("PATH", "")
            env["MONITOR_GUI_ROOT"] = str(source_root)

            self._run_make_update(repo_root, source_root, key_path, "0.2.14", env, channel="development")

            artifacts_root = packaging_root / "artifacts"
            manifests_root = artifacts_root / "manifests"
            latest_artifacts_dir = artifacts_root / "development_MonitorSMS-0.2.14"
            self.assertTrue((latest_artifacts_dir / "development_MonitorSMS-0.2.14.zip").exists())
            self.assertTrue((latest_artifacts_dir / "development_MonitorSMS-0.2.14.zip.sig").exists())
            self.assertTrue((latest_artifacts_dir / "development_MonitorSMS-0.2.14-app.zip").exists())
            self.assertTrue((latest_artifacts_dir / "development_MonitorSMS-0.2.14-app.zip.sig").exists())
            self.assertTrue((manifests_root / "development_MonitorSMS-0.2.14.json").exists())
            self.assertTrue((manifests_root / "development_MonitorSMS-0.2.14.json.sig").exists())

            latest_manifest = json.loads((latest_artifacts_dir / "latest.json").read_text(encoding="utf-8"))
            self.assertTrue(latest_manifest["url"].endswith("/development_MonitorSMS-0.2.14.zip"))
            self.assertTrue(latest_manifest["signature_url"].endswith("/development_MonitorSMS-0.2.14.zip.sig"))
            self.assertTrue(latest_manifest["app_url"].endswith("/development_MonitorSMS-0.2.14-app.zip"))
            self.assertTrue(latest_manifest["app_signature_url"].endswith("/development_MonitorSMS-0.2.14-app.zip.sig"))

    def _run_make_update(
        self,
        repo_root: Path,
        source_root: Path,
        key_path: Path,
        version: str,
        env: dict[str, str],
        *,
        channel: str,
    ) -> None:
        channel_arg = f"-Channel '{channel}'"
        result = subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                (
                    f"& '{repo_root / 'packaging' / 'make-update.ps1'}' "
                    f"-SigningKeyPath '{key_path}' "
                    "-BaseUrl 'https://updates.example.com/updates' "
                    f"{channel_arg} "
                    f"-Version '{version}'"
                ),
            ],
            cwd=repo_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("Archived", result.stdout)


if __name__ == "__main__":
    unittest.main()
