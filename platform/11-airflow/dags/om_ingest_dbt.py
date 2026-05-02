"""DAG: OpenMetadata dbt-workflow.

Leest dbt-artefacten uit s3://uwv-meta/dbt/latest/ en koppelt ze aan
de Trino-service in OM (geeft kolomniveau-lineage + meta-tags).

Vereist: dbt_run_per_domain DAG heeft eerst manifest.json + catalog.json
+ run_results.json geüpload naar MinIO via een post-task (TODO).

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


with DAG(
    dag_id="om_ingest_dbt",
    description="OpenMetadata dbt-workflow ingestion (manifest + catalog + run_results).",
    default_args=DEFAULT_ARGS,
    schedule="@daily",
    start_date=datetime(2026, 5, 1),
    catchup=False,
    tags=["openmetadata", "dbt", "uwv", "fase-8"],
) as dag:
    start = EmptyOperator(task_id="start")
    end = EmptyOperator(task_id="end")

    om_dbt = KubernetesPodOperator(
        task_id="om_ingest_dbt_artifacts",
        namespace="uwv-meta",
        image=OM_IMAGE,
        image_pull_policy="IfNotPresent",
        cmds=["bash", "-c"],
        arguments=[
            "envsubst < /config/dbt-workflow.yaml > /tmp/workflow.yaml && "
            "metadata ingest -c /tmp/workflow.yaml"
        ],
        env_vars=[
            V1EnvVar(
                name="OM_JWT_TOKEN",
                value_from=V1EnvVarSource(
                    secret_key_ref=V1SecretKeySelector(
                        name="openmetadata-admin", key="jwtToken"
                    )
                ),
            ),
            V1EnvVar(
                name="MINIO_SECRET_KEY",
                value_from=V1EnvVarSource(
                    secret_key_ref=V1SecretKeySelector(
                        name="minio-s3-credentials", key="secretKey"
                    )
                ),
            ),
        ],
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
            "limit_cpu": "500m",
            "limit_memory": "512Mi",
        },
        is_delete_operator_pod=True,
        get_logs=True,
    )

    start >> om_dbt >> end
