"""Pre-configured MinIO/S3 access for the UWV Lab notebook image.

Two flavors:
  * ``fs()`` — an ``s3fs.S3FileSystem`` for ``ls``/``open``/``upload``.
  * ``read_delta(table)`` — read a Delta table directly via delta-rs.
  * ``write_delta(df, table)`` — write a Delta table directly via delta-rs.

The credentials come from the ``minio-s3-credentials`` Stackable Secret
(``S3_ACCESS_KEY`` / ``S3_SECRET_KEY``) which the spawner injects into the
notebook pod. The default endpoint is the in-cluster MinIO Service so the
notebook never has to traverse the external ingress.
"""
from __future__ import annotations

import os
from typing import Any


def _endpoint() -> str:
    return os.environ.get("S3_ENDPOINT", "https://minio.uwv-platform.svc.cluster.local:9000")


def _key_pair() -> tuple[str, str]:
    return (
        os.environ.get("S3_ACCESS_KEY", "uwvadmin"),
        os.environ.get("S3_SECRET_KEY", ""),
    )


def fs(anonymous: bool = False):
    """Return an ``s3fs.S3FileSystem`` pre-configured for MinIO."""
    import s3fs

    access, secret = ("", "") if anonymous else _key_pair()
    ca_bundle = os.environ.get("UWV_CA_BUNDLE")
    return s3fs.S3FileSystem(
        key=access or None,
        secret=secret or None,
        anon=anonymous,
        client_kwargs={
            "endpoint_url": _endpoint(),
            "region_name": os.environ.get("S3_REGION", "eu-nl-1"),
            "verify": ca_bundle or False,
        },
    )


def ls(path: str = "") -> list[str]:
    """List a path (bucket or prefix). ``path=""`` enumerates buckets."""
    f = fs()
    if not path:
        return [b for b in f.ls("/") if b]
    return f.ls(path)


def _storage_options() -> dict[str, str]:
    """Storage options shaped for ``deltalake``."""
    access, secret = _key_pair()
    return {
        "AWS_ACCESS_KEY_ID": access,
        "AWS_SECRET_ACCESS_KEY": secret,
        "AWS_ENDPOINT_URL": _endpoint(),
        "AWS_REGION": os.environ.get("S3_REGION", "eu-nl-1"),
        "AWS_ALLOW_HTTP": "true" if _endpoint().startswith("http://") else "false",
        # MinIO + delta-rs: skip endpoint validation against AWS hostnames.
        "AWS_S3_ALLOW_UNSAFE_RENAME": "true",
        "AWS_CA_BUNDLE": os.environ.get("UWV_CA_BUNDLE", ""),
    }


def read_delta(table_uri: str, **kwargs: Any):
    """Read a Delta table from MinIO into a pandas DataFrame.

    ``table_uri`` is the s3a-style path, e.g. ``s3a://uwv-silver/wia/aanvraag``.
    """
    from deltalake import DeltaTable

    dt = DeltaTable(table_uri, storage_options=_storage_options())
    return dt.to_pandas(**kwargs)


def write_delta(df, table_uri: str, mode: str = "append", **kwargs: Any) -> None:
    """Write a pandas DataFrame to a Delta table on MinIO."""
    from deltalake import write_deltalake

    write_deltalake(
        table_or_uri=table_uri,
        data=df,
        mode=mode,
        storage_options=_storage_options(),
        **kwargs,
    )
