"""Governance-factory.

Drie soorten governance-DAGs:
  - om_ingest_trino:   OpenMetadata Trino-ingest (catalog refresh)
  - om_ingest_dbt:     OpenMetadata dbt-artifacts ingest (lineage + meta)
  - bewaartermijn:     R-AVG-08 enforcement per tabel met meta.bewaartermijn_jaren

Deze runnen op tijd-schema (geen Dataset-trigger) — ze leunen op rust-state.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from airflow import DAG
from airflow.models import Variable
from airflow.operators.empty import EmptyOperator
from airflow.providers.cncf.kubernetes.operators.pod import KubernetesPodOperator
from kubernetes.client.models import V1EnvVar

from k8s_helpers import (
    SMALL_POD_RESOURCES,
    ca_mount,
    ca_volume,
    git_sync_init,
    workspace_mount,
    workspace_volume,
)

DEFAULT_ARGS = {
    "owner": "data-steward",
    "depends_on_past": False,
    "email_on_failure": False,
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

OM_INGESTION_IMAGE = "openmetadata/ingestion:1.5.7"


def _om_ingest_task(*, task_id: str, workflow_yaml: str, repo_url: str) -> KubernetesPodOperator:
    """Genereer een KPO die metadata-ingest draait."""
    return KubernetesPodOperator(
        task_id=task_id,
        namespace="uwv-platform",
        image=OM_INGESTION_IMAGE,
        cmds=["bash", "-c"],
        arguments=[
            f"metadata ingest -c {workflow_yaml}"
        ],
        env_vars=[
            V1EnvVar(name="REQUESTS_CA_BUNDLE", value="/etc/uwv-ca/ca.crt"),
            V1EnvVar(name="SSL_CERT_FILE", value="/etc/uwv-ca/ca.crt"),
        ],
        init_containers=[git_sync_init(repo_url)] if repo_url else [],
        volumes=[workspace_volume(), ca_volume()],
        volume_mounts=[workspace_mount(), ca_mount()],
        container_resources=SMALL_POD_RESOURCES,
        is_delete_operator_pod=True,
        get_logs=True,
    )


def build_om_ingest_dag() -> DAG:
    # `bewaartermijn_enforcer.py` blijft een losse DAG-file (R-AVG-08
    # was al uitgewerkt vóór deze refactor). Bij wens kan governance ook
    # die DAG hier centraliseren — niet nu, geen functioneel verschil.
    """Run beide OM-ingests sequentieel: Trino eerst (tabellen), dan dbt (lineage)."""
    repo_url = Variable.get("uwv_repo_url", default_var="")
    with DAG(
        dag_id="governance_om_ingest",
        description=(
            "OpenMetadata-ingest: Trino-catalog (tabellen) gevolgd door "
            "dbt-artifacts (lineage + meta). Zie ADR-0007."
        ),
        default_args=DEFAULT_ARGS,
        schedule=timedelta(hours=1),
        start_date=datetime(2026, 5, 1),
        catchup=False,
        max_active_runs=1,
        tags=["uwv", "governance", "openmetadata"],
    ) as dag:
        if not repo_url:
            EmptyOperator(
                task_id="skip_no_repo",
                trigger_rule="all_success",
            )
            return dag

        ingest_trino = _om_ingest_task(
            task_id="ingest_trino_catalog",
            workflow_yaml="/workspace/repo/platform/13-openmetadata-config/workflows/trino-ingest.yaml",
            repo_url=repo_url,
        )
        ingest_dbt = _om_ingest_task(
            task_id="ingest_dbt_artifacts",
            workflow_yaml="/workspace/repo/platform/13-openmetadata-config/workflows/dbt-ingest.yaml",
            repo_url=repo_url,
        )
        ingest_trino >> ingest_dbt
    return dag


