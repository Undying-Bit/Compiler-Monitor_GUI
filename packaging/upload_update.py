from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path


def parse_bool(value: str, *, default: bool) -> bool:
    if value is None:
        return default
    text = str(value).strip().lower()
    if text == "":
        return default
    if text in {"1", "true", "yes", "on"}:
        return True
    if text in {"0", "false", "no", "off"}:
        return False
    raise ValueError(f"Invalid boolean value: {value!r}")


def normalize_prefix(prefix: str) -> str:
    return prefix.strip().strip("/")


def ensure_file(path: Path, label: str) -> None:
    if not path.exists():
        raise FileNotFoundError(f"{label} not found: {path}")
    if not path.is_file():
        raise FileNotFoundError(f"{label} is not a file: {path}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def upload_file(
    client,
    *,
    bucket: str,
    key: str,
    path: Path,
    content_type: str,
    metadata: dict[str, str] | None = None,
) -> None:
    extra_args = {"ContentType": content_type}
    if metadata:
        extra_args["Metadata"] = metadata
    client.upload_file(str(path), bucket, key, ExtraArgs=extra_args)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Upload MonitorSMS updates to an S3-compatible bucket.")
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--access-key", required=True)
    parser.add_argument("--secret-key", required=True)
    parser.add_argument("--region", default="")
    parser.add_argument("--session-token", default="")
    parser.add_argument("--use-ssl", default="true")
    parser.add_argument("--verify-tls", default="true")
    parser.add_argument("--prefix", default="")
    parser.add_argument("--latest", required=True)
    parser.add_argument("--latest-sig", required=True)
    parser.add_argument("--zip", dest="zip_path", required=True)
    parser.add_argument("--zip-sig", required=True)

    args = parser.parse_args(argv)

    try:
        use_ssl = parse_bool(args.use_ssl, default=True)
        verify_tls = parse_bool(args.verify_tls, default=True)
    except ValueError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2

    try:
        import boto3
        from botocore.client import Config
    except Exception as exc:  # pragma: no cover - runtime dependency
        print("Error: boto3 is required for uploads. Install with: pip install boto3", file=sys.stderr)
        print(str(exc), file=sys.stderr)
        return 2

    latest_path = Path(args.latest).resolve()
    latest_sig_path = Path(args.latest_sig).resolve()
    zip_path = Path(args.zip_path).resolve()
    zip_sig_path = Path(args.zip_sig).resolve()
    try:
        ensure_file(latest_path, "latest.json")
        ensure_file(latest_sig_path, "latest.json.sig")
        ensure_file(zip_path, "ZIP file")
        ensure_file(zip_sig_path, "ZIP signature file")
    except FileNotFoundError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2

    session = boto3.session.Session()
    client = session.client(
        "s3",
        endpoint_url=args.endpoint,
        region_name=args.region or None,
        aws_access_key_id=args.access_key,
        aws_secret_access_key=args.secret_key,
        aws_session_token=args.session_token or None,
        use_ssl=use_ssl,
        verify=verify_tls,
        config=Config(signature_version="s3v4"),
    )

    prefix = normalize_prefix(args.prefix or "")
    latest_key = f"{prefix}/latest.json" if prefix else "latest.json"
    latest_sig_key = f"{latest_key}.sig"
    zip_key = f"{prefix}/{zip_path.name}" if prefix else zip_path.name
    zip_sig_key = f"{zip_key}.sig"

    try:
        upload_file(
            client,
            bucket=args.bucket,
            key=latest_key,
            path=latest_path,
            content_type="application/json; charset=utf-8",
        )
        upload_file(
            client,
            bucket=args.bucket,
            key=latest_sig_key,
            path=latest_sig_path,
            content_type="application/octet-stream",
        )
        upload_file(
            client,
            bucket=args.bucket,
            key=zip_key,
            path=zip_path,
            content_type="application/zip",
            metadata={"sha256": sha256_file(zip_path)},
        )
        upload_file(
            client,
            bucket=args.bucket,
            key=zip_sig_key,
            path=zip_sig_path,
            content_type="application/octet-stream",
        )
    except Exception as exc:
        print(f"Error while uploading: {exc}", file=sys.stderr)
        return 2

    print(f"Uploaded {latest_key}")
    print(f"Uploaded {latest_sig_key}")
    print(f"Uploaded {zip_key}")
    print(f"Uploaded {zip_sig_key}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
