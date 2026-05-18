"""Governance-factory.

Bouwt twee soorten governance-DAGs:

  - om_ingest:    OpenMetadata-ingestion voor alle UWV-services
                  (Trino + lineage + profiler, Superset, Airflow, Kafka, dbt).
                  Service-/workflow-YAMLs komen uit ConfigMap
                  `openmetadata-uwv-config` (zie
                  platform/13-openmetadata-config/kustomization.yaml).
  - bewaartermijn: R-AVG-08 enforcement per tabel met meta.bewaartermijn_jaren.

Deze runnen op tijd-schema (geen Dataset-trigger) — ze leunen op rust-state.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from airflow import DAG
from airflow.providers.cncf.kubernetes.operators.pod import KubernetesPodOperator
from kubernetes.client.models import V1EnvVar

from k8s_helpers import (
    SMALL_POD_RESOURCES,
    ca_mount,
    ca_volume,
    om_config_mount,
    om_config_volume,
    secret_env,
)

DEFAULT_ARGS = {
    "owner": "data-steward",
    "depends_on_past": False,
    "email_on_failure": False,
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

OM_INGESTION_IMAGE = "openmetadata/ingestion:1.12.8"


def _om_env_vars() -> list[V1EnvVar]:
    """Env-vars die de service-YAMLs envsubst'en (zie platform/13-openmetadata-config/services/).

    Alle Secrets moeten in de uwv-platform namespace bestaan — de KPO draait
    daar. Bootstrap kopieert openmetadata-admin naar uwv-platform zodat
    OM_JWT_TOKEN cross-namespace bereikbaar is.
    """
    return [
        # OM API sink — JWT van de ingestion-bot of een andere admin-bot.
        secret_env("OM_JWT_TOKEN", "openmetadata-admin", "jwtToken"),
        # Trino source — `smoketest` is de technische bot-user (zie OPA-rules).
        secret_env("TRINO_PASSWORD", "trino-static-users", "smoketest"),
        # MinIO source — voor dbt-manifest read.
        secret_env("MINIO_SECRET_KEY", "minio-s3-credentials", "secretKey"),
        # Airflow + Superset metadata-DBs.
        secret_env(
            "AIRFLOW_DB_PW",
            "airflow-postgres-credentials",
            "adminUser.password",
        ),
        secret_env(
            "SUPERSET_ADMIN_PW",
            "superset-postgres-credentials",
            "adminUser.password",
        ),
        # CA-bundle voor TLS-verify naar Trino + OM ingress.
        V1EnvVar(name="REQUESTS_CA_BUNDLE", value="/etc/uwv-ca/ca.crt"),
        V1EnvVar(name="SSL_CERT_FILE", value="/etc/uwv-ca/ca.crt"),
    ]


def _om_ingest_task(
    *, task_id: str, workflow_yaml: str, subcommand: str = "ingest"
) -> KubernetesPodOperator:
    """KPO die `metadata <subcommand> -c <workflow_yaml>` draait.

    workflow_yaml is het pad in de pod (gemount uit `openmetadata-uwv-config`
    ConfigMap op /config). `subcommand` is "ingest" voor de meeste workflow-
    types (DatabaseMetadata/Lineage, Dashboard, Pipeline, Messaging, DBT) en
    "profile" voor type=Profiler.
    """
    return KubernetesPodOperator(
        task_id=task_id,
        namespace="uwv-platform",
        image=OM_INGESTION_IMAGE,
        cmds=["bash", "-c"],
        # envsubst rendert ${VAR}-references uit de YAML op runtime.
        arguments=[
            f"envsubst < {workflow_yaml} > /tmp/run.yaml && "
            f"metadata {subcommand} -c /tmp/run.yaml"
        ],
        env_vars=_om_env_vars(),
        volumes=[ca_volume(), om_config_volume()],
        volume_mounts=[ca_mount(), om_config_mount()],
        container_resources=SMALL_POD_RESOURCES,
        is_delete_operator_pod=True,
        get_logs=True,
    )


def _om_enrich_task() -> KubernetesPodOperator:
    """KPO die `enrich_from_dbt_meta.py` draait — past dbt-meta toe als
    OM-tags / glossary-links / owner / tier / domain / dataProduct /
    custom-properties.

    Hergebruikt de OM-ingestion-image (heeft Python 3.10 + boto3 + requests +
    pyyaml standaard). Script + mapping zitten in dezelfde /config-mount."""
    return KubernetesPodOperator(
        task_id="enrich_om_from_dbt_meta",
        namespace="uwv-platform",
        image=OM_INGESTION_IMAGE,
        cmds=["bash", "-c"],
        arguments=["python /config/enrich_from_dbt_meta.py"],
        env_vars=_om_env_vars(),
        volumes=[ca_volume(), om_config_volume()],
        volume_mounts=[ca_mount(), om_config_mount()],
        container_resources=SMALL_POD_RESOURCES,
        is_delete_operator_pod=True,
        get_logs=True,
    )


def build_om_ingest_dag() -> DAG:
    """Run alle OM-ingests sequentieel — service first, dan lineage/profiler/dbt.

    Volgorde:
      1. Trino service + tabellen   (services/trino-service.yaml)
      2. Trino lineage              (services/trino-lineage.yaml)
      3. Trino profiler + auto-PII  (services/trino-profiler.yaml)
      4. Superset dashboards        (services/superset-service.yaml)
      5. Airflow pipelines          (services/airflow-service.yaml)
      6. Kafka topics               (services/kafka-service.yaml)
      7. MinIO buckets (storage)    (services/minio-storage.yaml)
      8. dbt artifacts (lineage)    (services/dbt-workflow.yaml)
      9. dbt-meta enricher          (enrich_from_dbt_meta.py)

    dbt LAATST omdat het tabellen + columns nodig heeft die door Trino-ingest
    worden aangemaakt; Trino-lineage/profiler na de basis-catalog om
    duplicate-table errors te vermijden. Enricher als sluitstuk: tabellen +
    dbt-models bestaan op dit punt, dus mapping van meta → tags/glossary/
    owner/tier/domain/dataProduct kan PATCHen zonder 404's.
    """
    with DAG(
        dag_id="governance_om_ingest",
        description=(
            "OpenMetadata-ingest van alle UWV-services: Trino (catalog + "
            "lineage + profiler), Superset, Airflow, Kafka en dbt-artifacts."
        ),
        default_args=DEFAULT_ARGS,
        schedule=timedelta(hours=1),
        start_date=datetime(2026, 5, 1),
        catchup=False,
        max_active_runs=1,
        tags=["uwv", "governance", "openmetadata"],
    ) as dag:
        ingest_trino = _om_ingest_task(
            task_id="ingest_trino_catalog",
            workflow_yaml="/config/trino-service.yaml",
        )
        ingest_trino_lineage = _om_ingest_task(
            task_id="ingest_trino_lineage",
            workflow_yaml="/config/trino-lineage.yaml",
        )
        ingest_trino_profiler = _om_ingest_task(
            task_id="ingest_trino_profiler",
            workflow_yaml="/config/trino-profiler.yaml",
            # type=Profiler vereist `metadata profile` ipv `metadata ingest`
            # (anders: 'DatabaseServiceProfilerPipeline' has no attribute 'threads').
            subcommand="profile",
        )
        ingest_superset = _om_ingest_task(
            task_id="ingest_superset",
            workflow_yaml="/config/superset-service.yaml",
        )
        ingest_airflow = _om_ingest_task(
            task_id="ingest_airflow",
            workflow_yaml="/config/airflow-service.yaml",
        )
        ingest_kafka = _om_ingest_task(
            task_id="ingest_kafka",
            workflow_yaml="/config/kafka-service.yaml",
        )
        ingest_minio = _om_ingest_task(
            task_id="ingest_minio_storage",
            workflow_yaml="/config/minio-storage.yaml",
        )
        ingest_dbt = _om_ingest_task(
            task_id="ingest_dbt_artifacts",
            workflow_yaml="/config/dbt-workflow.yaml",
        )
        enrich = _om_enrich_task()

        # Sequentieel: catalog eerst, dan derivatives, dan side-services,
        # dan dbt-lineage, dan enricher (PATCH /tables met dbt-meta-mapping).
        (
            ingest_trino
            >> ingest_trino_lineage
            >> ingest_trino_profiler
            >> ingest_superset
            >> ingest_airflow
            >> ingest_kafka
            >> ingest_minio
            >> ingest_dbt
            >> enrich
        )
    return dag
