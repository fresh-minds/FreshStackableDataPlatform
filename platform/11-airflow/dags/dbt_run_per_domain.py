"""DAG: dbt run per domein.

Spawnt één KubernetesPodOperator-task per domein (parallel) die een
dbt-trino image draait. Het dbt-project wordt door een git-sync init-container
in de pod geclond — repo-URL via Airflow Variable `uwv_repo_url`.

Voor pure-lokale dev zonder git: zet `uwv_repo_url` op een lege string en de
dbt-tasks slaan over (BashOperator-skip). De DAG zelf parseert wel.

SYNTHETIC DATA — UWV REFERENCE PLATFORM — NOT FOR REAL USE.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from airflow import DAG
from airflow.models import Variable
from airflow.operators.bash import BashOperator
from airflow.operators.empty import EmptyOperator
from airflow.providers.cncf.kubernetes.operators.pod import KubernetesPodOperator
from kubernetes.client.models import (
    V1Container,
    V1EnvVar,
    V1EnvVarSource,
    V1SecretKeySelector,
    V1Volume,
    V1VolumeMount,
)

DOMAINS = [
    "persoon",
    "polisadm",
    "ww",
    "wia",
    "wajong",
    "zw",
    "crm",
    "fez",
]

DEFAULT_ARGS = {
    "owner": "data-engineer",
    "depends_on_past": False,
    "email_on_failure": False,
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

DBT_IMAGE = "ghcr.io/dbt-labs/dbt-trino:1.9.0"
GIT_SYNC_IMAGE = "registry.k8s.io/git-sync/git-sync:v4.2.4"


def _shared_volumes() -> tuple[list[V1Volume], list[V1VolumeMount]]:
    workspace = V1Volume(name="workspace", empty_dir={})
    mount = V1VolumeMount(name="workspace", mount_path="/workspace")
    return [workspace], [mount]


def _git_sync_init(repo_url: str) -> V1Container:
    return V1Container(
        name="git-sync",
        image=GIT_SYNC_IMAGE,
        image_pull_policy="IfNotPresent",
        env=[
            V1EnvVar(name="GITSYNC_REPO", value=repo_url),
            V1EnvVar(name="GITSYNC_REF", value="main"),
            V1EnvVar(name="GITSYNC_ROOT", value="/workspace"),
            V1EnvVar(name="GITSYNC_DEPTH", value="1"),
            V1EnvVar(name="GITSYNC_ONE_TIME", value="true"),
        ],
        volume_mounts=[V1VolumeMount(name="workspace", mount_path="/workspace")],
    )


def _trino_env() -> list[V1EnvVar]:
    return [
        V1EnvVar(
            name="TRINO_HOST",
            value="uwv-trino-coordinator.uwv-platform.svc.cluster.local",
        ),
        V1EnvVar(name="TRINO_PORT", value="8443"),
        V1EnvVar(name="TRINO_USER", value="smoketest"),
        V1EnvVar(
            name="TRINO_PASSWORD",
            value_from=V1EnvVarSource(
                secret_key_ref=V1SecretKeySelector(
                    name="trino-static-users",
                    key="smoketest",
                )
            ),
        ),
        V1EnvVar(name="TABLE_FORMAT", value="delta"),
        V1EnvVar(name="DBT_PROFILES_DIR", value="/workspace/repo/dbt"),
    ]


with DAG(
    dag_id="dbt_run_per_domain",
    description="Run dbt staging+marts per domein parallel.",
    default_args=DEFAULT_ARGS,
    schedule="@hourly",
    start_date=datetime(2026, 5, 1),
    catchup=False,
    max_active_runs=1,
    tags=["dbt", "uwv", "fase-6"],
) as dag:
    start = EmptyOperator(task_id="start")
    end = EmptyOperator(task_id="end")

    repo_url = Variable.get("uwv_repo_url", default_var="")

    if not repo_url:
        BashOperator(
            task_id="skip_no_repo_configured",
            bash_command=(
                'echo "Airflow Variable uwv_repo_url is leeg — '
                'dbt-tasks slaan over. Set via Airflow UI \\u2192 Admin \\u2192 Variables." '
                "&& exit 0"
            ),
        ) >> end
        start >> end
    else:
        volumes, volume_mounts = _shared_volumes()
        for domain in DOMAINS:
            task = KubernetesPodOperator(
                task_id=f"dbt_run_{domain}",
                namespace="uwv-platform",
                image=DBT_IMAGE,
                image_pull_policy="IfNotPresent",
                cmds=["bash", "-c"],
                arguments=[
                    "cd /workspace/repo/dbt && "
                    "cp profiles.yml.template profiles.yml && "
                    "dbt deps && "
                    f"dbt run --target dev --select 'tag:{domain}' && "
                    f"dbt test --target dev --select 'tag:{domain}'"
                ],
                env_vars=_trino_env(),
                init_containers=[_git_sync_init(repo_url)],
                volumes=volumes,
                volume_mounts=volume_mounts,
                # Resources zijn klein zodat KubernetesExecutor rustig blijft.
                container_resources={
                    "request_cpu": "100m",
                    "request_memory": "256Mi",
                    "limit_cpu": "500m",
                    "limit_memory": "1Gi",
                },
                is_delete_operator_pod=True,
                get_logs=True,
            )
            start >> task >> end
