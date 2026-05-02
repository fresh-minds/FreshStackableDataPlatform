"""DAG: synthetic-data laden via een Kubernetes Job.

Roept hetzelfde mechanisme aan als `make seed`: ConfigMaps voor de
generator-code, dan een Job die `load_to_kafka.py` draait. Productie
zou dit met een dedicated container-image doen; dev is python:3.11-slim
met pip-install at runtime.

Gebruikt KubernetesJobOperator (Airflow 2.10+) met inline-spec.

SYNTHETIC DATA — UWV REFERENCE PLATFORM — NOT FOR REAL USE.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from airflow import DAG
from airflow.models import Variable
from airflow.operators.empty import EmptyOperator
from airflow.providers.cncf.kubernetes.operators.job import KubernetesJobOperator
from kubernetes.client.models import (
    V1ConfigMapVolumeSource,
    V1Container,
    V1EnvVar,
    V1JobSpec,
    V1ObjectMeta,
    V1PodSpec,
    V1PodTemplateSpec,
    V1ResourceRequirements,
    V1Volume,
    V1VolumeMount,
)

DEFAULT_ARGS = {
    "owner": "data-engineer",
    "depends_on_past": False,
    "email_on_failure": False,
    "retries": 0,  # Idempotent via topic-partitioning; geen retries op seed.
}


def build_seed_job(client_count: int = 10000, seed: int = 2026) -> V1JobSpec:
    """Bouw een Job-spec equivalent aan data-generation/k8s/seed-job.yaml."""
    container = V1Container(
        name="seed",
        image="python:3.11-slim",
        command=["bash", "-euo", "pipefail", "-c"],
        args=[
            "pip install --quiet --disable-pip-version-check faker kafka-python click && "
            "cd /app && "
            'python load_to_kafka.py --count "$COUNT" --seed "$SEED" '
            '--bootstrap "$KAFKA_BOOTSTRAP"'
        ],
        env=[
            V1EnvVar(name="COUNT", value=str(client_count)),
            V1EnvVar(name="SEED", value=str(seed)),
            V1EnvVar(
                name="KAFKA_BOOTSTRAP",
                value="uwv-kafka-bootstrap.uwv-platform.svc.cluster.local:9092",
            ),
            V1EnvVar(name="PYTHONPATH", value="/app"),
        ],
        resources=V1ResourceRequirements(
            requests={"cpu": "100m", "memory": "256Mi"},
            limits={"cpu": "1", "memory": "1Gi"},
        ),
        volume_mounts=[
            V1VolumeMount(name="scripts", mount_path="/app"),
            V1VolumeMount(name="generators", mount_path="/app/generators"),
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
    schedule=None,  # Manueel triggerbaar; geen recurring run.
    start_date=datetime(2026, 5, 1),
    catchup=False,
    tags=["seed", "uwv", "fase-6"],
) as dag:
    start = EmptyOperator(task_id="start")
    end = EmptyOperator(task_id="end")

    client_count = int(Variable.get("uwv_seed_client_count", default_var="10000"))
    seed_value = int(Variable.get("uwv_seed_value", default_var="2026"))

    seed_task = KubernetesJobOperator(
        task_id="seed_data_to_kafka",
        namespace="uwv-platform",
        job_template=V1ObjectMeta(name="seed-data-generation"),
        full_pod_spec=None,
        job_spec=build_seed_job(client_count=client_count, seed=seed_value),
        wait_until_job_complete=True,
        job_poll_interval=10,
    )

    start >> seed_task >> end
