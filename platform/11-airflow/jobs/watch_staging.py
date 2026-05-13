#!/usr/bin/env python3
"""watch_staging.py — Polt MinIO uwv-staging/incoming/ en triggert Airflow DAGs.

Draait als KPO-task (python:3.11-slim). Voor elke csv_batch-bron:
als er bestanden liggen in incoming/<prefix>/, trigger dan ingest_csv_<bron>
per bestand via de Airflow REST API (basic auth, intern HTTP endpoint).

Idempotentie:
  - Bestanden die al in bewerking zijn (running/queued DAG-run) worden
    overgeslagen (GET /api/v1/dags/{id}/dagRuns?state=running,queued).
  - csv_to_bronze.py verplaatst het bestand naar processed/ na succes,
    zodat de volgende poll het niet meer ziet.

SYNTHETIC DATA — UWV REFERENCE PLATFORM — NOT FOR REAL USE.
"""
from __future__ import annotations

import base64
import glob
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

# Pip install op runtime — zelfde patroon als csv_to_bronze.py.
_PIP_HOSTS = [
    "--trusted-host", "pypi.org",
    "--trusted-host", "pypi.python.org",
    "--trusted-host", "files.pythonhosted.org",
]
subprocess.check_call(
    [sys.executable, "-m", "pip", "install", "--quiet", "--disable-pip-version-check",
     *_PIP_HOSTS, "boto3>=1.34,<2", "PyYAML>=6,<7"],
    stdout=subprocess.DEVNULL,
)

import urllib3
import boto3  # noqa: E402  (installed above)
import yaml  # noqa: E402  (installed above)
from botocore.client import Config  # noqa: E402

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ── Configuratie uit env-vars (gezet door de DAG via secret/env) ──────────────
S3_ENDPOINT       = os.environ["S3_ENDPOINT"]
S3_ACCESS_KEY     = os.environ["S3_ACCESS_KEY"]
S3_SECRET_KEY     = os.environ["S3_SECRET_KEY"]
STAGING_BUCKET    = os.environ.get("STAGING_BUCKET", "uwv-staging")
AIRFLOW_BASE_URL  = os.environ["AIRFLOW_BASE_URL"]  # http://...:8080 (intern HTTP)
AIRFLOW_USERNAME  = os.environ["AIRFLOW_USERNAME"]
AIRFLOW_PASSWORD  = os.environ["AIRFLOW_PASSWORD"]
SOURCES_DIR       = os.environ.get("UWV_SOURCES_DIR", "/opt/uwv/airflow/sources")


def log(msg: str) -> None:
    print(f"[watch_staging] {msg}", flush=True)


# ── S3 client ─────────────────────────────────────────────────────────────────

def s3_client():
    return boto3.client(
        "s3",
        endpoint_url=S3_ENDPOINT,
        aws_access_key_id=S3_ACCESS_KEY,
        aws_secret_access_key=S3_SECRET_KEY,
        config=Config(signature_version="s3v4"),
        region_name="eu-central-1",
        verify=False,  # in-cluster self-signed cert
    )


def list_incoming(s3, bucket: str, prefix: str) -> list[str]:
    """Geeft keys terug die in incoming/<prefix>/ staan (geen directory-markers)."""
    paginator = s3.get_paginator("list_objects_v2")
    keys = []
    for page in paginator.paginate(Bucket=bucket, Prefix=f"{prefix}/"):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if not key.endswith("/"):
                keys.append(key)
    log(f"  {len(keys)} bestand(en) gevonden in s3://{bucket}/{prefix}/")
    return keys


# ── Airflow REST API ──────────────────────────────────────────────────────────

def _auth_header() -> str:
    creds = base64.b64encode(
        f"{AIRFLOW_USERNAME}:{AIRFLOW_PASSWORD}".encode()
    ).decode()
    return f"Basic {creds}"


def has_active_run(dag_id: str) -> bool:
    """True als er al een running of queued run is voor deze DAG."""
    url = f"{AIRFLOW_BASE_URL}/api/v1/dags/{dag_id}/dagRuns?state=running,queued&limit=1"
    req = urllib.request.Request(url, headers={"Authorization": _auth_header()})
    try:
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read())
            count = len(data.get("dag_runs", []))
            return count > 0
    except urllib.error.HTTPError as e:
        log(f"  WAARSCHUWING: kan active runs niet ophalen voor {dag_id}: HTTP {e.code}")
        return False


def unpause_dag(dag_id: str) -> None:
    """Zet DAG op is_paused=False als dat nog niet het geval is."""
    url = f"{AIRFLOW_BASE_URL}/api/v1/dags/{dag_id}"
    payload = json.dumps({"is_paused": False}).encode()
    req = urllib.request.Request(
        url, data=payload,
        headers={"Authorization": _auth_header(), "Content-Type": "application/json"},
        method="PATCH",
    )
    try:
        with urllib.request.urlopen(req):
            pass
    except urllib.error.HTTPError as e:
        log(f"  WAARSCHUWING: unpause mislukt voor {dag_id}: HTTP {e.code}")


def trigger_dag(dag_id: str, object_key: str) -> bool:
    """Trigger een Airflow DAG-run met object_key in conf. Return True bij succes."""
    url = f"{AIRFLOW_BASE_URL}/api/v1/dags/{dag_id}/dagRuns"
    payload = json.dumps({"conf": {"object_key": object_key}}).encode()
    req = urllib.request.Request(
        url, data=payload,
        headers={"Authorization": _auth_header(), "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as resp:
            result = json.loads(resp.read())
            log(f"  ✓ {dag_id} getriggerd: run_id={result.get('dag_run_id')}")
            return True
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        log(f"  FOUT: HTTP {e.code} bij triggeren {dag_id} — {body[:200]}")
        return False


# ── Sources laden ─────────────────────────────────────────────────────────────

def load_csv_batch_sources() -> list[dict]:
    sources = []
    for path in sorted(glob.glob(f"{SOURCES_DIR}/*.yml")):
        with open(path) as f:
            spec = yaml.safe_load(f)
        if spec and spec.get("sla", {}).get("mode") == "csv_batch":
            sources.append(spec)
            log(f"  bron: {spec['name']} (prefix={spec['ingest']['staging']['prefix']})")
    return sources


# ── Hoofdlogica ───────────────────────────────────────────────────────────────

def main() -> None:
    log("scan gestart")
    s3 = s3_client()
    sources = load_csv_batch_sources()

    if not sources:
        log("geen csv_batch bronnen gevonden — klaar")
        return

    total_triggered = 0
    for source in sources:
        name   = source["name"]
        prefix = source["ingest"]["staging"]["prefix"]
        dag_id = f"ingest_csv_{name}"

        log(f"bron '{name}' scannen …")

        # Zorg dat de ingest-DAG niet gepauzeerd staat.
        unpause_dag(dag_id)

        # Sla over als er al een run actief/queued is (max_active_runs=1 op de DAG).
        if has_active_run(dag_id):
            log(f"  {dag_id} heeft al een actieve run — overgeslagen")
            continue

        pending = list_incoming(s3, STAGING_BUCKET, prefix)
        if not pending:
            log(f"  geen bestanden gevonden")
            continue

        # Trigger per bestand. Na de eerste trigger stoppen we zodat we
        # de volgorde bewaren (FIFO via MinIO last-modified).
        for key in pending:
            log(f"  bestand gevonden: {key}")
            if trigger_dag(dag_id, key):
                total_triggered += 1
            # Na één succesvolle trigger stoppen — has_active_run check
            # pakt de rest op in de volgende poll (2 minuten).
            break

    log(f"scan klaar — {total_triggered} DAG run(s) getriggerd")


if __name__ == "__main__":
    main()
