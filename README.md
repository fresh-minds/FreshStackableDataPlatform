# UWV Reference Data & Analytics Platform

Een **fictieve, illustratieve** referentie-implementatie van een modern data-
en analyticsplatform voor UWV, gebouwd op open source en gericht op compliance
met NORA, AVG, BIO/BIO2, NIS2 en de AI Act.

> **Disclaimer.** Geen echte UWV-data, geen echte BSN's, geen echte productiecode.
> Alle datasets zijn synthetisch en gemarkeerd met
> `# SYNTHETIC DATA — UWV REFERENCE PLATFORM — NOT FOR REAL USE`.
> Deze repo is geen UWV-product en geen aanbestedingsstuk.

---

## Wat dit platform doet

Een Kubernetes-native lakehouse + analytics-stack:

- **Storage**: MinIO (S3-compatible).
- **Tabelformaat**: Delta Lake (default voor deze implementatie — zie [ADR-0006](docs/adr/0006-delta-chosen-for-this-implementation.md)). Iceberg-pad blijft afgedekt via abstractie.
- **Catalog backend**: Apache Hive Metastore (Postgres-backed).
- **Ingestion**: NiFi → Kafka → Spark Structured Streaming → Delta op MinIO.
- **Query engine**: Trino, met OPA-authorisatie (Rego: doelbinding, row filters, column masking).
- **Transformatie**: dbt-trino, format-agnostisch via macro `table_format()`.
- **Orchestratie**: Apache Airflow.
- **BI**: Apache Superset.
- **Catalog/governance/lineage/DQ**: OpenMetadata.
- **AuthN**: Keycloak (OIDC).
- **Logs/metrics/tracing**: Vector + Prometheus + OpenTelemetry; OpenSearch single-node gedeeld voor logs en OM-search.

Alle componenten via **Stackable Data Platform 26.3** operators (NiFi, Kafka,
Spark, Hive, Trino, Airflow, Superset, OPA, ZooKeeper, secret-/listener-operator).

---

## Snelstart (k3d)

Voorvereisten:

- Docker Desktop met ≥ 8 GB RAM en ≥ 4 CPU's beschikbaar voor containers.
- `k3d` ≥ 5.6
- `kubectl` ≥ 1.29
- `helm` ≥ 3.14
- `stackablectl` ≥ 25.x
- `make`

```bash
# 1. Clone en cd naar de repo
cd UDP_Stackable

# 2. Voeg DNS-injectie toe aan /etc/hosts (vereist sudo)
echo "127.0.0.1 trino.uwv-platform.local keycloak.uwv-platform.local \
  superset.uwv-platform.local airflow.uwv-platform.local nifi.uwv-platform.local \
  minio.uwv-platform.local openmetadata.uwv-platform.local" | sudo tee -a /etc/hosts

# 3. Cluster + platform deployen (~15-30 min op de eerste run)
make cluster        # k3d cluster create
make bootstrap      # cert-manager, MinIO, Postgres, Keycloak, Stackable operators
make deploy-platform # Trino, Spark, Kafka, NiFi, Airflow, Superset, OpenMetadata
make seed           # synthetische data laden (10k cliënten)
make test           # smoke tests

# 4. Stop en cleanup
make clean          # k3d cluster delete
```

---

## Repository-layout

| Directory | Inhoud |
|---|---|
| `platform-config.yaml` | Centrale configuratie. Wijzig `table_format` hier, niet elders. |
| `docs/` | Architectuur, ADRs, use-case specs, compliance-mapping, runbook. |
| `infrastructure/` | k3d-config, externe Helm-values (cert-manager, Keycloak, MinIO, Postgres, OpenMetadata), Stackable release-pinning. |
| `platform/` | Kubernetes-manifests per laag (00-namespaces … 13-openmetadata-config). |
| `dbt/` | dbt-project, models (staging/intermediate/marts/uc01..uc10), macros, tests. |
| `data-generation/` | Synthetische data-generators (Python). |
| `nifi-flows/` | NiFi-flow templates (iceberg/delta varianten). |
| `spark-jobs/` | PySpark-jobs (streaming + batch + ML demo). |
| `opa-policies-src/` | Rego-policies + tests. |
| `scripts/` | Bash-helpers voor `make`-targets. |
| `tests/` | Smoke / integration / e2e tests. |
| `ci/` | GitHub Actions workflows (in opzet). |

---

## Documentatie

- [Architectuur](docs/architecture.md)
- [Achtergrondsamenvatting](docs/context-summary.md)
- [Compliance-mapping](docs/compliance-mapping.md)
- [Runbook](docs/runbook.md)
- ADRs: [0001](docs/adr/0001-stackable-as-base.md) · [0002](docs/adr/0002-iceberg-vs-delta.md) · [0003](docs/adr/0003-opa-as-trino-authz.md) · [0004](docs/adr/0004-openmetadata-as-catalog.md) · [0005](docs/adr/0005-dbt-trino-as-transform.md) · [0006](docs/adr/0006-delta-chosen-for-this-implementation.md)
- Use cases: [UC-01](docs/use-cases/uc01-wia-funnel.md) · [UC-02](docs/use-cases/uc02-wajong-ai.md) · [UC-03](docs/use-cases/uc03-ww-risk.md) · [UC-04](docs/use-cases/uc04-proactieve-tw.md) · [UC-05](docs/use-cases/uc05-client-360.md) · [UC-06](docs/use-cases/uc06-schadelast.md) · [UC-07](docs/use-cases/uc07-dq-polisadm.md) · [UC-08](docs/use-cases/uc08-smz-planning.md) · [UC-09](docs/use-cases/uc09-reint-effect.md) · [UC-10](docs/use-cases/uc10-gegevensdiensten.md)

---

## Status

Werk-in-uitvoering. Zie [WORKLOG.md](WORKLOG.md) voor laatste fase en openstaande
items. De [Definition of Done](docs/architecture.md#definition-of-done) staat
in `docs/architecture.md`.

---

## Licentie

Apache License 2.0 — zie [LICENSE](LICENSE).
