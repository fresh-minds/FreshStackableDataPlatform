"""watch_csv_staging — polt MinIO staging en triggert ingest_csv_* DAGs.

Draait elke 2 minuten. Één KPO-task per run die watch_staging.py uitvoert.
Voor elke csv_batch-bron in airflow-sources: als er bestanden liggen in
incoming/<prefix>/, trigger dan ingest_csv_<bron> via de Airflow REST API.

Auto-trigger flow:
  1. Gebruiker upload CSV naar MinIO  uwv-staging/incoming/<bron>/
  2. Deze DAG detecteert het bestand (polling interval: 2 min max wachttijd)
  3. ingest_csv_<bron> wordt getriggerd met conf={"object_key": "<key>"}
  4. bronze-Dataset wordt gepubliceerd → silver-DAG triggert automatisch

SYNTHETIC DATA — UWV REFERENCE PLATFORM — NOT FOR REAL USE.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from airflow import DAG
from airflow.providers.cncf.kubernetes.operators.pod import KubernetesPodOperator
from kubernetes.client.models import V1ConfigMapVolumeSource, V1EnvVar, V1Volume, V1VolumeMount

from k8s_helpers import (
    SMALL_POD_RESOURCES,
    ca_mount,
    ca_volume,
    secret_env,
)

# ── Constanten ────────────────────────────────────────────────────────────────

LOADER_IMAGE = "python:3.11-slim"

# Airflow webserver intern (HTTP, port 8080) — geen TLS-problematiek.
AIRFLOW_BASE_URL = "http://uwv-airflow-webserver.uwv-platform.svc.cluster.local:8080"

S3_ENDPOINT = "https://minio.uwv-platform.svc.cluster.local:9000"

JOBS_CM     = "airflow-jobs"
SOURCES_CM  = "airflow-sources"
JOBS_MOUNT  = "/opt/uwv/airflow/jobs"
SOURCES_MOUNT = "/opt/uwv/airflow/sources"

DEFAULT_ARGS = {
    "owner": "data-engineer",
    "depends_on_past": False,
    "email_on_failure": False,
    "retries": 1,
    "retry_delay": timedelta(minutes=2),
}


def _volumes() -> list[V1Volume]:
    return [
        ca_volume(),
        V1Volume(name="airflow-jobs",    config_map=V1ConfigMapVolumeSource(name=JOBS_CM)),
        V1Volume(name="airflow-sources", config_map=V1ConfigMapVolumeSource(name=SOURCES_CM)),
    ]


def _mounts() -> list[V1VolumeMount]:
    return [
        ca_mount(),
        V1VolumeMount(name="airflow-jobs",    mount_path=JOBS_MOUNT,    read_only=True),
        V1VolumeMount(name="airflow-sources",  mount_path=SOURCES_MOUNT, read_only=True),
    ]


def _pip_cmd() -> str:
    trusted = (
        "--trusted-host pypi.org "
        "--trusted-host pypi.python.org "
        "--trusted-host files.pythonhosted.org"
    )
    return (
        f"pip install --quiet --disable-pip-version-check {trusted} "
        f"'boto3>=1.34,<2' 'PyYAML>=6,<7' && "
        f"python {JOBS_MOUNT}/watch_staging.py"
    )


with DAG(
    dag_id="watch_csv_staging",
    description=(
        "Polt MinIO uwv-staging/incoming/ elke 2 minuten. "
        "Bij nieuwe CSV-bestanden wordt ingest_csv_<bron> automatisch getriggerd. "
        "Zie ADR-0007."
    ),
    default_args=DEFAULT_ARGS,
    schedule_interval="*/2 * * * *",
    start_date=datetime(2026, 5, 1),
    catchup=False,
    max_active_runs=1,
    is_paused_upon_creation=False,   # direct actief, geen handmatig unpausen vereist
    tags=["watcher", "csv", "ingest", "auto-trigger"],
) as dag:

    KubernetesPodOperator(
        task_id="scan_and_trigger",
        name="csv-staging-watcher",
        image=LOADER_IMAGE,
        namespace="uwv-platform",
        cmds=["bash", "-euo", "pipefail", "-c"],
        arguments=[_pip_cmd()],
        env_vars=[
            # Vaste waarden — in-cluster endpoints.
            V1EnvVar(name="S3_ENDPOINT",      value=S3_ENDPOINT),
            V1EnvVar(name="STAGING_BUCKET",   value="uwv-staging"),
            V1EnvVar(name="AIRFLOW_BASE_URL", value=AIRFLOW_BASE_URL),
            V1EnvVar(name="UWV_SOURCES_DIR",  value=SOURCES_MOUNT),
            # Secrets.
            secret_env("S3_ACCESS_KEY",    "minio-s3-credentials", "accessKey"),
            secret_env("S3_SECRET_KEY",    "minio-s3-credentials", "secretKey"),
            secret_env("AIRFLOW_USERNAME", "airflow-api-bot",       "username"),
            secret_env("AIRFLOW_PASSWORD", "airflow-api-bot",       "password"),
        ],
        env_from=[],
        volumes=_volumes(),
        volume_mounts=_mounts(),
        container_resources=SMALL_POD_RESOURCES,
        is_delete_operator_pod=True,
        get_logs=True,
        in_cluster=True,
    )
