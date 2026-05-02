# 13-openmetadata-config

UWV-specifieke configuratie voor OpenMetadata: classifications (PII / Health /
Confidentiality / BIO / LegalBasis / Doelbinding / AI), CGM-glossary, en
service-connection definities voor Trino / dbt / Superset / Airflow / Kafka.

## Bestanden

| Bestand | Doel |
|---|---|
| [classifications-uwv.yaml](classifications-uwv.yaml) | 7 classifications met ~50 tags totaal — PII, Health.Article9, BIO.BIV, LegalBasis, Doelbinding, AI.Risk-\*. |
| [glossary-cgm.yaml](glossary-cgm.yaml) | CGM-glossary met ~22 termen uit referentiearchitectuur Bijlage B. |
| [services/trino-service.yaml](services/trino-service.yaml) | Trino DatabaseService config — schema-filter dekt alle UWV-catalogs. |
| [services/trino-lineage.yaml](services/trino-lineage.yaml) | Lineage-workflow uit Trino query-history. |
| [services/trino-profiler.yaml](services/trino-profiler.yaml) | Profiler op silver.\* (kolom-statistieken voor UC-07). |
| [services/dbt-workflow.yaml](services/dbt-workflow.yaml) | dbt-manifest workflow (leest s3://uwv-meta/dbt/latest/). |
| [services/superset-service.yaml](services/superset-service.yaml) | Dashboard-ingestion. |
| [services/airflow-service.yaml](services/airflow-service.yaml) | Pipeline-ingestion. |
| [services/kafka-service.yaml](services/kafka-service.yaml) | Topic-ingestion. |
| [init-job.yaml](init-job.yaml) | ConfigMap + Job die classifications + glossary toepast via OM REST API. |
| [kustomization.yaml](kustomization.yaml) | Bundelt alles + bouwt ConfigMap `openmetadata-uwv-config`. |

## Pre-requisites

- OpenMetadata Helm-installed in `uwv-meta` (zie `infrastructure/helm/openmetadata/`).
- OpenSearch single-node draait (gedeeld met Vector logs).
- Postgres `openmetadata` database init (via fase 1 init-script).
- JWT-token voor admin: `metadata generate-token` na bootstrap; resultaat in Secret `openmetadata-admin.jwtToken`.

## Apply

```bash
kubectl apply -k platform/13-openmetadata-config/
kubectl -n uwv-meta wait --for=condition=complete job/openmetadata-init --timeout=10m
```

## Wat doet de init-Job

1. Wacht tot OM `/api/v1/system/version` 200 retourneert.
2. POST per classification (en bijbehorende tags).
3. POST glossary CGM + alle terms.

**Niet** gedaan door deze Job: ingestion-runs voor Trino/dbt/Superset/Airflow/Kafka.
Die zijn in de `services/*.yaml` configs gedefinieerd en worden door Airflow-DAGs
[`platform/11-airflow/dags/om_ingest_*.py`](../11-airflow/dags/) gescheduled.

## Verificatie

```bash
# Lijst classifications
TOKEN=$(kubectl -n uwv-meta get secret openmetadata-admin -o jsonpath='{.data.jwtToken}' | base64 -d)
kubectl -n uwv-meta port-forward svc/openmetadata 8585:8585 &
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8585/api/v1/classifications" | jq '.data[].name'

# Lijst glossary terms
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8585/api/v1/glossaryTerms?glossary=CGM" | jq '.data[].name'
```

## Productie

- JWT-tokens roteren via External Secrets + Vault (geen statische tokens in Secrets).
- Auto-classification AAN — laat OM zelf BSN-patronen detecteren naast de declaratieve tags.
- Reverse Metadata aan zetten zodat OM-tags terug naar Trino propageren → voedsel voor OPA-policies (fase 9).
- DLM (Data Lifecycle Manager) configureren met `bewaartermijn_jaren`-meta uit dbt-models.
