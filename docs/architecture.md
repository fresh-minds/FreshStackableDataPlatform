# Architectuur

Deze referentie-implementatie volgt de
[UWV-referentiearchitectuur](../referentiearchitectuur-uwv-data-analytics.md)
en de [component-mapping](../uwv-platform-mapping-research.md). Onderstaand
document beschrijft hoe die abstractie concreet landt in code en YAML in deze
repo.

---

## 1. Hoog-niveau

```
                                   (k3d cluster, scaled-down)

  Synthetic data    NiFi          Kafka          Spark Structured       MinIO  (Delta)        Trino                BI / consumers
  generators  ───►  (Stackable ─► (Stackable ──► Streaming ──────────►  bronze ───────────►   (Stackable     ──►   Superset
  (Python)          NiFiCluster)  KafkaCluster)  (SparkApplication)     silver                TrinoCluster)        OpenMetadata
                                                                        gold                                       dbt-trino (in Airflow)
                                                                        sensitive
                                                                          ▲
                                                                          │
                                                                  Hive Metastore
                                                                  (Stackable + Postgres)

  Auth :  Keycloak (OIDC) ─► AuthenticationClass  ─►  Trino · Superset · Airflow · NiFi · OpenMetadata
  Authz:  OPA (Stackable OpaCluster) + Rego bundle ─► Trino access-controller
  TLS  :  cert-manager + Stackable secret-operator
  Logs :  Vector ─► OpenSearch (gedeeld met OpenMetadata)
  Metr :  Prometheus + Grafana
  Trace:  OpenTelemetry collector
```

De pijlrichting is dataflow. Auth/authz/observability zijn cross-cutting
en raken alle componenten.

---

## 2. Mapping op de UWV-referentiearchitectuur

| Laag in referentie-arch. | Component in deze repo |
|---|---|
| Bronnen | `data-generation/` — synthetische generators voor Polisadm/WW/WIA/Wajong/CRM/FEZ |
| Ingestie & integratie | `platform/07-nifi/` (NiFi) + `platform/06-kafka/` (Kafka) + `nifi-flows/templates/` |
| Opslag (lakehouse, medallion) | MinIO (`platform/03-storage/`) + Delta-tabellen + `platform/05-hive-metastore/` |
| Processing & ML | `platform/08-spark/apps/` (PySpark via SparkApplication) + `dbt/` (Trino-side transforms) |
| Semantische laag | dbt-marts (`dbt/models/marts/uc0x_*/`) + Trino views (`gold` catalog) |
| Consumptie | `platform/12-superset/` (BI) + Trino REST/JDBC voor toekomstige API-laag |
| IAM | Keycloak (`infrastructure/helm/keycloak/`) + Stackable AuthenticationClass (`platform/02-authentication/`) |
| Authorisatie | `platform/10-opa/` + `opa-policies-src/` (Rego) |
| Catalog / lineage / DQ | OpenMetadata (`infrastructure/helm/openmetadata/`) + `platform/13-openmetadata-config/` |
| Observability | Vector (Stackable) + Prometheus (`infrastructure/helm/prometheus-stack/`) + OpenSearch (gedeeld) |
| Secrets / TLS | cert-manager + Stackable secret-operator |

---

## 3. Zone-scheiding (medallion + sensitive)

Vier MinIO-buckets, elk met eigen Trino-catalog:

| Catalog | Bucket | Inhoud | Toegang (default) |
|---|---|---|---|
| `bronze`    | `uwv-bronze`    | Onveranderbare brondata (incl. raw PII) | data-engineers (JIT) |
| `silver`    | `uwv-silver`    | Geconformeerd, gepseudonimiseerd waar mogelijk | analisten + engineers |
| `gold`      | `uwv-gold`      | CGM-conforme business products | domein-rollen via RBAC |
| `sensitive` | `uwv-sensitive` | Bijzondere persoonsgegevens (art. 9 AVG, medisch) | strikt; 4-eyes principe |

OPA-policies zijn **format-agnostisch**: ze kijken naar `catalog.schema.table`-
en kolomnamen, niet naar het onderliggende bestandsformaat. Switching tussen
Delta en Iceberg laat de policies onveranderd.

---

## 4. Tabelformaat-abstractie

Eén centrale variabele:

```yaml
# platform-config.yaml
platform:
  table_format: delta   # delta | iceberg
```

Wordt gelezen door:

| Component | Hoe |
|---|---|
| Trino-catalogs | Templates onder `platform/09-trino/catalogs/*.yaml.tmpl` worden gerenderd door `scripts/render-trino-catalogs.sh` op basis van `table_format`. Connector wordt `delta-lake` of `iceberg`. |
| dbt | `dbt_project.yml` zet `vars: table_format: "{{ env_var('TABLE_FORMAT', 'delta') }}"`. Macro `table_format_properties()` levert de juiste `properties{}` per model. |
| Spark | Env var `TABLE_FORMAT` op `SparkApplication`. Helper `spark-jobs/lib/lakehouse_io.py` schakelt `write_iceberg()` vs `write_delta()`. |
| NiFi | Twee templates onder `nifi-flows/templates/{iceberg,delta}/`. Per default deployen we de Delta-variant (= NiFi → Kafka, en Spark schrijft Delta). |
| Airflow | DAGs lezen `Variable.get("TABLE_FORMAT")`. Maintenance-DAG kiest `OPTIMIZE`/`VACUUM` (Delta) of `expire_snapshots`/`rewrite_data_files` (Iceberg). |

**Geen** hardcoded `delta` of `iceberg` buiten deze plekken. Zie
[ADR-0002](adr/0002-iceberg-vs-delta.md) en
[ADR-0006](adr/0006-delta-chosen-for-this-implementation.md).

---

## 5. Ingestion-pad bij Delta (afwijking van Iceberg-demo)

Stackable's referentie-demo `data-lakehouse-iceberg-trino-spark` gebruikt
NiFi's native `PutIceberg`-processor. Voor **Delta is er geen native NiFi-
processor**. Daarom wordt voor de Delta-route alle bron-data via NiFi naar
**Kafka** geschreven; Spark Structured Streaming consumeert Kafka en schrijft
naar Delta op MinIO.

```
  Bron-mock ─► NiFi (PublishKafka) ─► Kafka topic uwv.<domain>.<event>
                                              │
                                              ▼
                                    Spark Structured Streaming
                                    (SparkApplication, K8s)
                                              │
                                              ▼
                            Delta-tabel in MinIO (s3a://uwv-bronze/...)
                            Hive Metastore registreert tabel
```

Iceberg-pad (toekomstig of switch-back): NiFi's `PutIceberg` schrijft direct
naar bronze; Spark blijft beschikbaar voor silver/gold-transformaties.

---

## 6. Naming conventions

- **K8s namespaces**:
  - `uwv-platform` — Stackable workloads
  - `uwv-data` — synthetic data jobs, dbt-runners
  - `uwv-meta` — OpenMetadata stack
  - `uwv-monitoring` — Prometheus, Grafana
  - `uwv-auth` — Keycloak
- **Trino-schemas**:
  - `bronze.uwv.<entity>`
  - `silver.<domain>.<entity>` (`ww`, `wia`, `wajong`, `crm`, `fez`, `polisadm`)
  - `gold.<uc_id>.<artifact>` (`uc01_wia_funnel`, `uc05_client_360`, ...)
  - `sensitive.<domain>.<entity>`
- **dbt models**: `<layer>_<domain>_<entity>.sql` (`stg_wia_aanvraag.sql`, `mart_uc01_wia_funnel_daily.sql`).
- **Kafka topics**: `uwv.<domain>.<event>`.
- **DNS**: `<service>.uwv-platform.local`.

---

## 7. Auth-flow

```
Browser  ──► Keycloak (OIDC) ──── login + role assignment
   │                              ▲
   │                              │
   ▼                              │
Service (Trino/Superset/Airflow/NiFi/OpenMetadata)
   │
   ├── via Stackable AuthenticationClass (OIDC, ADR032)
   │
   └── Trino ──► OPA bundle (uit ConfigMap) ──── allow/deny + row filters + column masks
```

Mock-rollen in de Keycloak realm: `wia_beoordelaar`, `ww_handhaver`,
`wajong_arbeidsdeskundige`, `crm_medewerker`, `fez_analist`, `data_steward`,
`data_engineer`, `platform_admin`.

---

## 8. Definition of Done

Het platform is "klaar" wanneer:

1. `make cluster && make bootstrap && make deploy-platform && make seed && make test` slaagt op een schoon k3d-cluster.
2. Superset toont dashboard "WIA Funnel" met 7 dagen synthetische data voor rol `data_steward`.
3. OpenMetadata toont end-to-end lineage van synthetische bron → dbt-model → Superset chart.
4. OPA weigert query op `client_360.bsn` voor rol zonder doel "uitkering"; maskeert BSN voor `crm_medewerker`.
5. dbt-test `bsn_valid` faalt op een ingespoten ongeldige BSN-record.
6. OpenMetadata toont voor elke gold-tabel: eigenaar, doelbinding-tag, classificatie, bewaartermijn.
7. [`docs/compliance-mapping.md`](compliance-mapping.md) mapt elk R-NORA/AVG/BIO/NIS2 op een concreet bestand of setting.
8. CI-pipeline (GitHub Actions) groen op fresh clone.
9. Switching naar Iceberg vereist alleen wijziging in `platform-config.yaml` + Trino-catalog redeploy + dbt re-run — code blijft anders ongewijzigd.
10. Geen `latest`-tag, geen plaintext secret, geen TODO in productie-policy zonder ticket-id.
