"""DAG: OpenMetadata Trino-ingestion (metadata + lineage + profiler).

Drie taken parallel:
  1. metadata — tabellen/kolommen/types
  2. lineage — uit query-history
  3. profiler — kolom-statistieken

Gebruikt KubernetesPodOperator met `metadata` CLI image.
Workflow-YAMLs komen uit ConfigMap `openmetadata-uwv-config` (fase 8).

SYNTHETIC DATA — UWV REFERENCE PLATFORM — NOT FOR REAL USE.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.empty import EmptyOperator
from airflow.providers.cncf.kubernetes.operators.pod import KubernetesPodOperator
from kubernetes.client.models import (
    V1ConfigMapVolumeSource,
    V1EnvVar,
    V1EnvVarSource,
    V1SecretKeySelector,
    V1Volume,
    V1VolumeMount,
)

DEFAULT_ARGS = {
    "owner": "data-engineer",
    "depends_on_past": False,
    "email_on_failure": False,
    "retries": 1,
    "retry_delay": timedelta(minutes=10),
}

OM_IMAGE = "docker.getcollate.io/openmetadata/ingestion:1.5.0"

WORKFLOWS = [
    ("metadata", "trino-service.yaml"),
    ("lineage", "trino-lineage.yaml"),
    ("profiler", "trino-profiler.yaml"),
]


def _env() -> list[V1EnvVar]:
    return [
        V1EnvVar(
            name="OM_JWT_TOKEN",
            value_from=V1EnvVarSource(
                secret_key_ref=V1SecretKeySelector(
                    name="openmetadata-admin", key="jwtToken"
                )
            ),
        ),
        V1EnvVar(
            name="TRINO_PASSWORD",
            value_from=V1EnvVarSource(
                secret_key_ref=V1SecretKeySelector(
                    name="trino-static-users", key="smoketest"
                )
            ),
        ),
    ]


with DAG(
    dag_id="om_ingest_trino",
    description="OpenMetadata Trino metadata/lineage/profiler ingestion.",
    default_args=DEFAULT_ARGS,
    schedule="@daily",
    start_date=datetime(2026, 5, 1),
    catchup=False,
    tags=["openmetadata", "uwv", "fase-8"],
) as dag:
    start = EmptyOperator(task_id="start")
    end = EmptyOperator(task_id="end")

    for kind, config_file in WORKFLOWS:
        task = KubernetesPodOperator(
            task_id=f"om_{kind}_trino",
            namespace="uwv-meta",
            image=OM_IMAGE,
            image_pull_policy="IfNotPresent",
            cmds=["bash", "-c"],
            arguments=[
                # envsubst de workflow-YAML; metadata CLI ondersteunt geen
                # ${VAR} interpolatie out-of-the-box.
                f"envsubst < /config/{config_file} > /tmp/workflow.yaml && "
                f"metadata {kind} -c /tmp/workflow.yaml"
            ],
            env_vars=_env(),
            volumes=[
                V1Volume(
                    name="config",
                    config_map=V1ConfigMapVolumeSource(name="openmetadata-uwv-config"),
                ),
            ],
            volume_mounts=[V1VolumeMount(name="config", mount_path="/config")],
            container_resources={
                "request_cpu": "100m",
                "request_memory": "256Mi",
                "limit_cpu": "1000m",
                "limit_memory": "1Gi",
            },
            is_delete_operator_pod=True,
            get_logs=True,
        )
        start >> task >> end
