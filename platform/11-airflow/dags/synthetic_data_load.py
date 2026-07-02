"""DAG: synthetic-data laden via een Kubernetes Job.

Roept hetzelfde mechanisme aan als `make seed`: ConfigMaps voor de
generator-code, dan een Job die `load_to_s3.py` draait. Schrijft JSONL
naar `s3a://uwv-raw/`; Spark file-source streaming pikt het op.

Gebruikt KubernetesJobOperator (Airflow 2.10+) met inline-spec.

SYNTHETIC DATA — UWV REFERENCE PLATFORM — NOT FOR REAL USE.
"""

from __future__ import annotations

from datetime import datetime

from airflow import DAG
from airflow.models import Variable
from airflow.operators.empty import EmptyOperator
from airflow.providers.cncf.kubernetes.operators.job import KubernetesJobOperator
from kubernetes.client.models import (
    V1ConfigMapVolumeSource,
    V1Container,
    V1EnvVar,
    V1EnvVarSource,
    V1JobSpec,
    V1ObjectMeta,
    V1PodSpec,
    V1PodTemplateSpec,
    V1ResourceRequirements,
    V1SecretKeySelector,
    V1Volume,
    V1VolumeMount,
)

DEFAULT_ARGS = {
    "owner": "data-engineer",
    "depends_on_past": False,
    "email_on_failure": False,
    "retries": 0,
}


def _secret_env(name: str, secret_name: str, secret_key: str) -> V1EnvVar:
    return V1EnvVar(
        name=name,
        value_from=V1EnvVarSource(
            secret_key_ref=V1SecretKeySelector(name=secret_name, key=secret_key),
        ),
    )


def build_seed_job(
    client_count: int = 10000, seed: int = 2026, insecure: bool = False
) -> V1JobSpec:
    """Bouw een Job-spec equivalent aan data-generation/k8s/seed-job.yaml.

    Standaard verifieert de loader de MinIO-TLS tegen de gemounte interne CA
    (`uwv-ca-bundle` configmap → /etc/uwv-ca/ca.crt, via AWS_CA_BUNDLE). Alleen
    wanneer `insecure=True` (dev-escape via Airflow Variable) wordt --insecure
    doorgegeven en TLS-validatie overgeslagen.
    """
    seed_cmd = (
        'python load_to_s3.py --count "$COUNT" --seed "$SEED" '
        '--bucket "$S3_BUCKET" --endpoint "$S3_ENDPOINT"'
    )
    if insecure:
        seed_cmd += " --insecure"
    container = V1Container(
        name="seed",
        image="python:3.11-slim",
        command=["bash", "-euo", "pipefail", "-c"],
        args=[
            "pip install --quiet --disable-pip-version-check faker boto3 click urllib3 && "
            "cd /app && " + seed_cmd
        ],
        env=[
            V1EnvVar(name="COUNT", value=str(client_count)),
            V1EnvVar(name="SEED", value=str(seed)),
            V1EnvVar(name="S3_BUCKET", value="uwv-raw"),
            V1EnvVar(
                name="S3_ENDPOINT",
                value="https://minio.uwv-platform.svc.cluster.local:9000",
            ),
            V1EnvVar(name="S3_REGION", value="us-east-1"),
            # Interne CA voor TLS-verificatie tegen MinIO (boto3 leest AWS_CA_BUNDLE).
            V1EnvVar(name="AWS_CA_BUNDLE", value="/etc/uwv-ca/ca.crt"),
            V1EnvVar(name="SSL_CERT_FILE", value="/etc/uwv-ca/ca.crt"),
            _secret_env("S3_ACCESS_KEY", "minio-s3-credentials", "accessKey"),
            _secret_env("S3_SECRET_KEY", "minio-s3-credentials", "secretKey"),
            V1EnvVar(name="PYTHONPATH", value="/app"),
        ],
        resources=V1ResourceRequirements(
            requests={"cpu": "100m", "memory": "256Mi"},
            limits={"cpu": "1", "memory": "1Gi"},
        ),
        volume_mounts=[
            V1VolumeMount(name="scripts", mount_path="/app"),
            V1VolumeMount(name="generators", mount_path="/app/generators"),
            V1VolumeMount(name="uwv-ca", mount_path="/etc/uwv-ca", read_only=True),
        ],
    )
    pod_spec = V1PodSpec(
        restart_policy="Never",
        containers=[container],
        volumes=[
            V1Volume(
                name="scripts",
                config_map=V1ConfigMapVolumeSource(name="data-generation-scripts"),
            ),
            V1Volume(
                name="generators",
                config_map=V1ConfigMapVolumeSource(name="data-generation-generators"),
            ),
            V1Volume(
                name="uwv-ca",
                config_map=V1ConfigMapVolumeSource(name="uwv-ca-bundle"),
            ),
        ],
    )
    return V1JobSpec(
        ttl_seconds_after_finished=3600,
        backoff_limit=1,
        template=V1PodTemplateSpec(
            metadata=V1ObjectMeta(labels={"uwv.nl/component": "data-generation"}),
            spec=pod_spec,
        ),
    )


with DAG(
    dag_id="synthetic_data_load",
    description="Genereer en laad synthetische data via Kubernetes Job.",
    default_args=DEFAULT_ARGS,
    schedule=None,
    start_date=datetime(2026, 5, 1),
    catchup=False,
    tags=["seed", "uwv"],
) as dag:
    start = EmptyOperator(task_id="start")
    end = EmptyOperator(task_id="end")

    client_count = int(Variable.get("uwv_seed_client_count", default_var="10000"))
    seed_value = int(Variable.get("uwv_seed_value", default_var="2026"))
    # Secure default: TLS wordt geverifieerd tegen de gemounte interne CA.
    # Zet Airflow Variable `uwv_seed_insecure_tls=true` alleen als dev-escape
    # wanneer de CA (nog) niet beschikbaar is.
    insecure_tls = (
        Variable.get("uwv_seed_insecure_tls", default_var="false").strip().lower()
        in ("1", "true", "yes")
    )

    seed_task = KubernetesJobOperator(
        task_id="seed_data_to_s3",
        namespace="uwv-platform",
        job_template=V1ObjectMeta(name="seed-data-generation"),
        full_pod_spec=None,
        job_spec=build_seed_job(
            client_count=client_count, seed=seed_value, insecure=insecure_tls
        ),
        wait_until_job_complete=True,
        job_poll_interval=10,
    )

    start >> seed_task >> end
