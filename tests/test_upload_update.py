from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "packaging" / "upload_update.py"
SPEC = importlib.util.spec_from_file_location("monitor_upload_update", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
upload_update = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(upload_update)


class FakePaginator:
    def __init__(self, pages: list[dict[str, object]]) -> None:
        self.pages = pages
        self.calls: list[dict[str, object]] = []

    def paginate(self, **kwargs):
        self.calls.append(kwargs)
        return list(self.pages)


class FakeS3Client:
    def __init__(self, pages: list[dict[str, object]]) -> None:
        self.paginator = FakePaginator(pages)
        self.deleted_batches: list[dict[str, object]] = []
        self.uploads: list[dict[str, object]] = []
        self.actions: list[tuple[str, object]] = []

    def get_paginator(self, name: str) -> FakePaginator:
        if name != "list_objects_v2":
            raise AssertionError(f"Unexpected paginator: {name}")
        return self.paginator

    def delete_objects(self, *, Bucket: str, Delete: dict[str, object]) -> dict[str, object]:
        self.deleted_batches.append({"Bucket": Bucket, "Delete": Delete})
        self.actions.append(("delete", [item["Key"] for item in Delete["Objects"]]))
        return {"Deleted": Delete["Objects"]}

    def upload_file(self, filename: str, bucket: str, key: str, ExtraArgs: dict[str, object]) -> None:
        self.uploads.append(
            {
                "filename": filename,
                "bucket": bucket,
                "key": key,
                "extra_args": ExtraArgs,
            }
        )
        self.actions.append(("upload", key))


class ErroringDeleteClient(FakeS3Client):
    def delete_objects(self, *, Bucket: str, Delete: dict[str, object]) -> dict[str, object]:
        super().delete_objects(Bucket=Bucket, Delete=Delete)
        first_key = Delete["Objects"][0]["Key"]
        return {"Errors": [{"Key": first_key, "Message": "Access denied"}]}


class UploadUpdateTest(unittest.TestCase):
    def test_prune_update_artifacts_deletes_only_matching_top_level_keys_under_prefix(self) -> None:
        client = FakeS3Client(
            [
                {
                    "Contents": [
                        {"Key": "updates/latest.json"},
                        {"Key": "updates/latest.json.sig"},
                        {"Key": "updates/MonitorSMS-0.2.14.zip"},
                        {"Key": "updates/MonitorSMS-0.2.14.zip.sig"},
                        {"Key": "updates/MonitorSMS-0.2.13-to-0.2.14-patch.zip"},
                        {"Key": "updates/MonitorSMS-0.2.13-to-0.2.14-patch.zip.sig"},
                        {"Key": "updates/MonitorSMS-0.2.14.msi"},
                        {"Key": "updates/archive/latest.json"},
                        {"Key": "updates/archive/MonitorSMS-0.2.13.zip"},
                        {"Key": "data/latest.json"},
                        {"Key": "latest.json"},
                    ]
                }
            ]
        )

        deleted = upload_update.prune_update_artifacts(client, bucket="monitor-updates", prefix="updates")

        self.assertEqual(client.paginator.calls, [{"Bucket": "monitor-updates", "Prefix": "updates/"}])
        self.assertEqual(
            deleted,
            [
                "updates/latest.json",
                "updates/latest.json.sig",
                "updates/MonitorSMS-0.2.14.zip",
                "updates/MonitorSMS-0.2.14.zip.sig",
                "updates/MonitorSMS-0.2.13-to-0.2.14-patch.zip",
                "updates/MonitorSMS-0.2.13-to-0.2.14-patch.zip.sig",
            ],
        )
        self.assertEqual(
            client.deleted_batches,
            [
                {
                    "Bucket": "monitor-updates",
                    "Delete": {
                        "Objects": [
                            {"Key": "updates/latest.json"},
                            {"Key": "updates/latest.json.sig"},
                            {"Key": "updates/MonitorSMS-0.2.14.zip"},
                            {"Key": "updates/MonitorSMS-0.2.14.zip.sig"},
                            {"Key": "updates/MonitorSMS-0.2.13-to-0.2.14-patch.zip"},
                            {"Key": "updates/MonitorSMS-0.2.13-to-0.2.14-patch.zip.sig"},
                        ],
                        "Quiet": True,
                    },
                }
            ],
        )

    def test_publish_update_artifacts_prunes_before_uploading_expected_six_files_when_patch_present(self) -> None:
        client = FakeS3Client([{"Contents": [{"Key": "updates/MonitorSMS-0.2.13.zip"}]}])

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            latest = tmp_path / "latest.json"
            latest_sig = tmp_path / "latest.json.sig"
            zip_path = tmp_path / "MonitorSMS-0.2.14.zip"
            zip_sig = tmp_path / "MonitorSMS-0.2.14.zip.sig"
            patch_path = tmp_path / "MonitorSMS-0.2.13-to-0.2.14-patch.zip"
            patch_sig = tmp_path / "MonitorSMS-0.2.13-to-0.2.14-patch.zip.sig"

            latest.write_text('{"version":"0.2.14"}\n', encoding="utf-8")
            latest_sig.write_bytes(b"manifest-signature")
            zip_path.write_bytes(b"zip-payload")
            zip_sig.write_bytes(b"zip-signature")
            patch_path.write_bytes(b"patch-payload")
            patch_sig.write_bytes(b"patch-signature")

            deleted, uploaded = upload_update.publish_update_artifacts(
                client,
                bucket="monitor-updates",
                prefix="updates",
                latest_path=latest,
                latest_sig_path=latest_sig,
                zip_path=zip_path,
                zip_sig_path=zip_sig,
                patch_path=patch_path,
                patch_sig_path=patch_sig,
            )

        self.assertEqual(deleted, ["updates/MonitorSMS-0.2.13.zip"])
        self.assertEqual(
            uploaded,
            [
                "updates/latest.json",
                "updates/latest.json.sig",
                "updates/MonitorSMS-0.2.14.zip",
                "updates/MonitorSMS-0.2.14.zip.sig",
                "updates/MonitorSMS-0.2.13-to-0.2.14-patch.zip",
                "updates/MonitorSMS-0.2.13-to-0.2.14-patch.zip.sig",
            ],
        )
        self.assertEqual(
            client.actions,
            [
                ("delete", ["updates/MonitorSMS-0.2.13.zip"]),
                ("upload", "updates/latest.json"),
                ("upload", "updates/latest.json.sig"),
                ("upload", "updates/MonitorSMS-0.2.14.zip"),
                ("upload", "updates/MonitorSMS-0.2.14.zip.sig"),
                ("upload", "updates/MonitorSMS-0.2.13-to-0.2.14-patch.zip"),
                ("upload", "updates/MonitorSMS-0.2.13-to-0.2.14-patch.zip.sig"),
            ],
        )
        self.assertEqual(len(client.uploads), 6)
        self.assertEqual(client.uploads[2]["extra_args"]["ContentType"], "application/zip")
        self.assertIn("sha256", client.uploads[2]["extra_args"]["Metadata"])
        self.assertEqual(client.uploads[4]["extra_args"]["ContentType"], "application/zip")
        self.assertIn("sha256", client.uploads[4]["extra_args"]["Metadata"])

    def test_prune_update_artifacts_fails_closed_when_delete_reports_errors(self) -> None:
        client = ErroringDeleteClient([{"Contents": [{"Key": "updates/latest.json"}]}])

        with self.assertRaises(RuntimeError):
            upload_update.prune_update_artifacts(client, bucket="monitor-updates", prefix="updates")


if __name__ == "__main__":
    unittest.main()
