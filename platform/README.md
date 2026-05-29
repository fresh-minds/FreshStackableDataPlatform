# platform/ — Kubernetes-manifests per laag

Eén submap per platform-component. De **numerieke prefix** (`00`–`21`) geeft
de **deploy-volgorde** aan: lagere nummers zijn afhankelijkheden van hogere
nummers. `scripts/deploy-platform.sh` past de mappen in deze volgorde toe.

> Wijzig configuratie zoveel mogelijk centraal in
> [`../platform-config.yaml`](../platform-config.yaml), niet binnen de
> componenten zelf.

## Componenten

| # | Component | Wat | Afhankelijkheden |
|---|---|---|---|
| 00 | [namespaces](00-namespaces/README.md) | Declaratieve namespaces (`uwv-platform`, `uwv-data`, `uwv-monitoring`, …), netwerk-labels en ResourceQuota/LimitRange per namespace. | — |
| 01 | [secrets](01-secrets/README.md) | Stackable `SecretClass`-CRD's + dev-only `Secret`-objects (Postgres, MinIO, Keycloak admin). | 00 |
| 02 | [authentication](02-authentication/README.md) | `AuthenticationClass` voor Keycloak-OIDC + interne TLS-CA-secretclass. | 00, 01 |
| 03 | [storage](03-storage/README.md) | `S3Connection` voor MinIO + bucket-init Job. | 00, 01 |
| 05 | [hive-metastore](05-hive-metastore/README.md) | Hive Metastore — catalog backend voor zowel Delta als Iceberg. | 00, 01, 03 |
| 08 | [spark](08-spark/README.md) | Spark-on-Kubernetes via `SparkApplication`-CRD; leest JSONL uit `s3a://uwv-raw/`. | 00, 03, 05 |
| 09 | [trino](09-trino/README.md) | Trino — distributed SQL engine met OPA-authz + OIDC. | 00, 02, 03, 05, 10 |
| 10 | [opa](10-opa/README.md) | Open Policy Agent — authorisatielaag voor Trino. | 00 |
| 11 | [airflow](11-airflow/README.md) | Apache Airflow via `AirflowCluster`-CRD; orkestreert dbt + maintenance. | 00, 02, 09 |
| 12 | [superset](12-superset/README.md) | Apache Superset BI via `SupersetCluster`-CRD; query't Trino. | 00, 02, 09 |
| 12 | [databricks](12-databricks/README.md) | **Spec-only** — Databricks-notebooks voor UC-11 (AKS/Entra). Geen k3d-manifests. | — |
| 12 | [powerbi](12-powerbi/README.md) | **Spec-only** — Power BI / Microsoft Fabric-rapport voor UC-12 (AKS/Entra). Geen k3d-manifests. | — |
| 13 | [openmetadata-config](13-openmetadata-config/README.md) | UWV-specifieke OpenMetadata-config: classifications, glossary, service-defs, ingestion-pipelines. | OpenMetadata via `infrastructure/helm/` |
| 14 | [monitoring](14-monitoring/README.md) | Cross-cutting reliability: PrometheusRules, ServiceMonitors, OpenSearch-ILM. | Prometheus via `infrastructure/helm/` |
| 15 | [portal](15-portal/README.md) | Rol-aware workspace-shell — embedt alle service-UI's onder één URL. | 00, 02 |
| 16 | [jupyter](16-jupyter/README.md) | UWV Lab — JupyterHub + KubeSpawner; notebook-werkplek op bronze/silver/gold/sensitive met Git-integratie. | 00, 02, 03, 05, 09 |
| 17 | [multica](17-multica/README.md) | Multica-coördinatieserver voor coding agents. Exploratory — niet in de governance-flow. | 00, 02 |
| 18 | [om-access-bridge](18-om-access-bridge/README.md) | Self-service data-access: OpenMetadata task-approval → Keycloak realm-role → OPA-grant (ADR-0008). | 02, 10, 13, OpenMetadata |
| 19 | [nanitics-observatory](19-nanitics-observatory/README.md) | In-cluster agent-runtime + trace-viewer; watcher filed issues naar Multica. Dev-only. | 00, 02 |
| 20 | [multica-daemon](20-multica-daemon/README.md) | Multica agent-runtime daemon — compute voor door Multica-taken gespawnde agents. | 00, 17 |
| 21 | [nao](21-nao/README.md) | Natural-language analytics agent — natuurlijke taal → SQL op Trino, met chat-UI. Dev-only. | 00, 02, 09 |

> **Gaten in de nummering (04, 06, 07).** ZooKeeper (`04`), Kafka (`06`) en
> NiFi (`07`) zijn uit de actieve stack gehaald: hun Stackable-operators staan
> **uit** in [`../infrastructure/stackablectl/release.yaml`](../infrastructure/stackablectl/release.yaml)
> en de Delta-route leest JSONL direct uit `s3a://uwv-raw/` via Spark
> Structured Streaming. De NiFi/Kafka-flows blijven als template aanwezig onder
> [`../nifi-flows/templates/`](../nifi-flows/templates/).
>
> **Drie `12-*`-varianten.** De BI-/verwerkingslaag heeft drie smaken:
> `12-superset` (open-source default, actief in k3d) en de spec-only
> Microsoft-varianten `12-powerbi` en `12-databricks` (AKS/Entra).

## Deploy

```bash
make deploy-platform        # past de actieve lagen in volgorde toe
```

`scripts/deploy-platform.sh` deployt `12-superset` (niet de spec-only
`12-databricks`/`12-powerbi`) en slaat de uitgeschakelde lagen 04/06/07 over.
`18-om-access-bridge` wordt apart gedeployd (`make deploy-om-bridge`) omdat het
op een OpenMetadata-admin-token wacht. Voor één enkel component:

```bash
kubectl apply -k platform/09-trino/        # of -f bij niet-kustomize componenten
```

## Cluster-modi

`platform-config.yaml#scale_profile` schakelt tussen:

- `scaled-down` — 1 replica per service, lage resource requests (k3d-default).
- `production` — meerdere replicas, hogere requests/limits.

> Kustomize `overlays/` voor de production-flip is nog niet aanwezig — zie
> [`docs/improvements.md`](../docs/improvements.md) item 1.7.

## Conventies

- Elke submap is **kustomize-compatibel** (kustomization.yaml of plain manifests).
- README per component: doel, CRD-overzicht, deploy, verify, bekende issues.
- Geen geheimen committen — alle Secret-objecten zijn `dev-` gemarkeerd
  en mogen niet naar productie. Zie [`01-secrets/README.md`](01-secrets/README.md).
- `table_format` en andere cross-component-keuzes komen uit
  [`../platform-config.yaml`](../platform-config.yaml).
