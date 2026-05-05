# ADR-0007: Airflow pipeline-architectuur — Cosmos, Datasets, YAML-registry

| Status | **Geaccepteerd** |
|---|---|
| Datum | 2026-05-05 |
| Beslissers | Platform Architect, Data Engineering |
| Gerelateerd | [ADR-0001](0001-stackable-as-base.md) (Stackable), [ADR-0005](0005-dbt-trino-as-transform.md) (dbt-trino), [ADR-0004](0004-openmetadata-as-catalog.md) (OpenMetadata) |

---

## Context

Het platform heeft 8 brondomeinen (persoon, polisadm, ww, wia, wajong, zw,
crm, fez) en 10 use cases met cross-domein marts. De eerste DAG-opzet
(`dbt_run_per_domain.py`) draait dbt parallel per domein, maar:

1. **schaalt niet voor cross-domein marts.** UC-05 Client 360 heeft refs naar
   5 domeinen; UC-04 TW Eligibility naar 3. Een per-domein-DAG kan die volgorde
   niet uitdrukken zonder serialisatie of dubbele runs.
2. **kent geen DAG-tot-DAG koppeling.** Bronze (Spark streaming) → Silver
   (dbt) → Gold (dbt) → OM-ingest → Superset draaien op losse `@hourly`
   schedules. Een mislukte streaming-batch leidt nog steeds tot een gold-run
   op stale silver.
3. **vereist 4 wijzigingen voor een nieuwe bron.** dbt-staging, Kafka-topic,
   `models:` blok in `dbt_project.yml`, en de `DOMAINS`-lijst in de DAG. Geen
   single source of truth.
4. **bevat copy-paste boilerplate.** `_trino_env`, git-sync init, resources —
   bij meer DAGs neemt drift toe.

Tegelijk hebben we een uitgebreide tagging-strategie in dbt: elk model heeft
tags op laag (`staging`/`intermediate`/`marts`), domein, en use-case
(`["marts","uc01","ag","sturingsinfo"]`). Die tags zijn nu onderbenut.

## Beslissing

Drie ontwerppijlers voor alle ETL-orkestratie op dit platform:

### Pijler 1 — YAML-source-registry als single source of truth

Eén bestand per bron in `platform/11-airflow/sources/<domain>.yml` definieert:

- topic-pattern (Kafka) en bronze-tabel-naam
- eigenaar, classificatie (BIO), bewaartermijn
- staging-model-naam (matcht dbt) en gerelateerde use-cases
- SLA: verwachte event-frequentie, lag-drempel voor alerting

Alle DAG-factories lezen dit; ook `nifi-flows/` en de OM-source-registratie
kunnen er later op aansluiten. Een nieuwe bron = één YAML toevoegen + dbt
staging-model schrijven. De DAGs verschijnen automatisch in Airflow.

### Pijler 2 — DAG-factory per pijplijnstap

Vijf factories in `platform/11-airflow/include/`:

| Factory | Output | Granulariteit |
|---|---|---|
| `bronze_factory` | 1 watch-DAG | Sensor op alle bronze-tabellen (Spark schrijft, DAG bevestigt). Publiceert dataset per bron. |
| `silver_factory` | 1 DAG per domein (8) | Cosmos-rendered dbt run+test op `tag:<domain> tag:staging`. Triggered op bronze-dataset. |
| `gold_factory` | 1 DAG per use case (6 actief) | Cosmos-rendered dbt run+test op `tag:uc<NN>`. Triggered op silver-datasets van benodigde domeinen. |
| `governance_factory` | 1 DAG per scope | OM-ingest (Trino + dbt artifacts), bewaartermijn-enforcer, DQ-checks per UC. |
| `ops_factory` | losse DAGs | Synthetic seed, lakehouse-maintenance — geen vaste structuur, wel gemeenschappelijke helpers. |

Elke factory is een functie `build_*_dag(spec) -> DAG` die uit een YAML-spec
of dbt-tag een complete DAG genereert. De DAG-aanroeperfiles (`dags/*.py`)
bevatten alleen `for ... build_silver_dag(domain)` — geen logica.

### Pijler 3 — Datasets als koppellijm tussen DAGs

Vanaf Airflow 2.4 is `Dataset` de canonieke manier om DAG-tot-DAG
afhankelijkheden te modelleren. URI-conventie:

```
bronze://uwv/<domain>_<entity>          # bronze.uwv.<domain>_<entity>
silver://<domain>/<entity>              # silver.<domain>.stg_<entity>
gold://<usecase>/<table>                # gold.<usecase>.<table>
```

Concreet:

- `bronze_factory` publiceert `Dataset("bronze://uwv/wia_aanvraag")` per ronde.
- `silver_factory` voor `wia` heeft `schedule=[Dataset("bronze://uwv/wia_aanvraag")]`
  en publiceert `Dataset("silver://wia/aanvraag")`.
- `gold_factory` voor `uc01` heeft `schedule=[Dataset("silver://wia/aanvraag")]`.
- UC-05 (5 datasets in schedule) draait pas wanneer alle vijf bronnen geüpdatet zijn.

Geen tijd-gebaseerde aannames meer; pijplijn rijgt zich op data-events.

## Tooling-keuzes

### Cosmos voor dbt-orkestratie

`astronomer-cosmos` (≥ 1.7) genereert **één Airflow-task per dbt-model**
in plaats van één pod per dbt-run. Voordelen:

- per-model retries, granular logs, model-niveau-lineage in Airflow UI
- sluit aan bij OpenMetadata (model-niveau) zonder extra mapping
- behoudt de bestaande `KubernetesPodOperator`-uitvoering — Cosmos `ExecutionMode.KUBERNETES` spawnt nog steeds een dbt-trino pod per model

**Configuratie:**
- `LoadMode.DBT_MANIFEST` — Cosmos parseert `manifest.json` (geen DB-toegang
  bij DAG-parse). Manifest wordt door een eenmalige Job (`dbt-manifest-job`)
  voor-gerenderd en in een ConfigMap gezet.
- `ProfileConfig` met `TrinoBaseProfileMapping` — leest Trino-creds uit een
  Airflow-Connection (door OPA gehandhaafd via `smoketest`-rol in dev).
- `ExecutionMode.KUBERNETES` — image `ghcr.io/dbt-labs/dbt-trino:1.9.0`,
  identiek aan huidige setup.

### Cosmos installeren op Stackable Airflow 2.9.3

Twee paden, beiden gedocumenteerd:

| Pad | Wanneer | Hoe |
|---|---|---|
| **A. initContainer + shared volume** (default voor dev) | k3d, geen registry | Init-container `python:3.11-slim` doet `pip install --target=/cosmos-pkgs astronomer-cosmos==1.7.1`. Airflow-containers krijgen `PYTHONPATH=/cosmos-pkgs:...`. Trade-off: ~20s extra startup per pod. |
| **B. Custom image** (productie) | OCI-registry beschikbaar | Build `infrastructure/airflow/Dockerfile` met `FROM docker.stackable.tech/.../airflow:2.9.3-...` + `RUN pip install astronomer-cosmos==1.7.1`. Push naar interne registry; verwijs ernaar via `spec.image.custom`. |

Pad A is geactiveerd. Pad B wordt voorbereid (Dockerfile + README) maar niet
gebouwd in deze referentie.

## Mapstructuur

```
platform/11-airflow/
├── airflowcluster.yaml          # podOverrides voor cosmos-init + 3 mounts
├── ingress.yaml
├── kustomization.yaml           # 3 configMapGenerators (dags, include, sources)
├── dags/                        # DAG-aanroeperfiles (factory-calls)
│   ├── ingest_bronze_watch.py
│   ├── transform_silver_per_domain.py
│   ├── transform_gold_per_usecase.py
│   ├── governance_om_ingest.py
│   ├── governance_bewaartermijn.py
│   ├── ops_synthetic_data_load.py
│   └── ops_lakehouse_maintenance.py
├── include/                     # importable factories + helpers
│   ├── __init__.py
│   ├── datasets.py              # URI-conventies + helper-funcs
│   ├── sources_loader.py        # YAML → SourceSpec dataclass
│   ├── trino_helpers.py         # _trino_env, profile-mapping
│   ├── k8s_helpers.py           # git-sync init, resources, CA-mount
│   ├── bronze_factory.py
│   ├── silver_factory.py
│   ├── gold_factory.py
│   └── governance_factory.py
├── sources/                     # YAML-registry — 1 bestand per bron
│   ├── persoon.yml
│   ├── polisadm.yml
│   ├── ww.yml
│   ├── wia.yml
│   ├── wajong.yml
│   ├── zw.yml
│   ├── crm.yml
│   └── fez.yml
├── jobs/
│   └── dbt-manifest-job.yaml    # one-shot Job die manifest.json rendert
└── tests/
    └── dag_integrity_test.py    # pytest: parse + cycle + dataset-coverage
```

Mounts in pod:
- `/stackable/airflow/dags/` ← ConfigMap `airflow-dags` (DAG-aanroepers)
- `/opt/uwv/airflow/include/` ← ConfigMap `airflow-include` (factories) — op `PYTHONPATH`
- `/opt/uwv/airflow/sources/` ← ConfigMap `airflow-sources` (YAML's) — gelezen via env `UWV_SOURCES_DIR`
- `/opt/uwv/dbt/manifest.json` ← ConfigMap `dbt-manifest` (single-key)

## Gevolgen

### Positief

- **Eén YAML-bestand** voegt een nieuwe bron toe: het toevoegen van een dbt
  staging-model is daarna voldoende; bronze-watch + silver-DAG verschijnen
  automatisch.
- **Per-model lineage** in Airflow UI; aansluiting op OpenMetadata behoudt
  granulariteit.
- **Geen dode runs** dankzij Datasets; gold draait pas als silver vers is.
- **Testbare factories**: pytest kan factory-output asserten zonder cluster.
- **Cosmos opent deur** naar `dbt build`-mode (run+test+source freshness in
  één graph), partial reruns op model-niveau, en `select`-filters die
  meegegroeid zijn met de dbt CLI.

### Negatief / mitigatie

- **Cosmos-versie pinnen**: 1.7.x serie heeft breaking changes geïntroduceerd
  vs 1.5; pin op `astronomer-cosmos==1.7.1` met regression-test in CI.
- **Manifest-staleness**: bij dbt-model-wijziging moet manifest opnieuw
  worden gerenderd. Mitigatie: pre-commit hook + `make airflow-manifest`
  target + Airflow Variable `dbt_manifest_version` voor cache-busting.
- **YAML-registry duplicaat**: bron-info staat zowel in YAML als in dbt
  schema.yml `meta:`. Mitigatie: schrijf een tweerichtings-validator
  (`tests/test_sources_consistency.py`) — afwijking → CI fail.
- **Dataset-fan-in voor UC-05** (5 schedule-deps): bij vertraagde domein-DAG
  blijft UC-05 wachten. Acceptabel — alternatief ("partial gold runs") leidt
  tot inconsistente client-360 views.
- **Init-container 20s** verlengt cold-start. Productie gebruikt custom image.

### Migratiepad

1. Deze ADR + structuur naast bestaande DAGs in een PR.
2. `dbt_run_per_domain.py` blijft eerst werken; nieuwe `transform_silver_*` +
   `transform_gold_*` parallel actief.
3. UC-01 (WIA Funnel) als eerste end-to-end via nieuwe stack — DoD-test groen.
4. Bestaande `om_ingest_trino.py` + `om_ingest_dbt.py` consolideren naar
   `governance_om_ingest.py` zodra de factory-coverage compleet is.
5. `dbt_run_per_domain.py` verwijderen wanneer alle 6 actieve UC-DAGs groen
   zijn op de nieuwe stack.

## Alternatieven overwogen

| Alternatief | Reden afgewezen |
|---|---|
| **Eén mega-DAG** met TaskGroups voor alle laagovergangen | Onleesbaar bij 8 domeinen × 10 UCs; één failure blokkeert alles; geen onafhankelijke schedules per UC. |
| **Pure `KubernetesPodOperator` zonder Cosmos** (huidige patroon doortrekken) | Geen per-model granulariteit; logs per pod ipv per task; dbt model-failure mengt met andere modellen in dezelfde run. |
| **Apache Beam / Flink** voor ETL ipv dbt | Overkill voor batch-aggregatie op een lakehouse; team-skills al op SQL/dbt; OPA-policies binden op Trino-tabellen niet op stream-records. |
| **Argo Workflows** ipv Airflow | Stackable bevat Airflow-operator; geen tweede orkestratie-engine introduceren. |
| **Dagster** | Krachtige asset-graph maar Stackable supportet het niet; dubbele leercurve. |
| **Cosmos `LoadMode.DBT_LS`** (live `dbt ls` bij DAG-parse) | Vereist Trino-conn bij elke scheduler-restart; trage parse; niet air-gap-vriendelijk. |
| **Geen Cosmos, hand-rolled task-per-model** | Mogelijk maar herproduceert Cosmos slechter; niet onderhoudbaar. |

## Open punten

- **`dbt build` ipv `dbt run + dbt test`** — aanrader voor productie (single
  graph traversal). Cosmos ondersteunt dit via `render_config.test_behavior =
  TestBehavior.AFTER_EACH`. Default in onze setup.
- **Source freshness** — Cosmos heeft `dbt source freshness` integratie. Voor
  UWV (mostly streamed) is dit voornamelijk nuttig op `fez` (batch). Open.
- **Backfill-strategie** — Datasets zijn forward-only. Manuele backfill via
  `airflow dags backfill` blijft mogelijk.

---

> Verwijs vanuit elke factory en DAG-aanroeper naar deze ADR in een
> module-docstring. Bij wijziging van de pijler-keuzes: nieuw ADR.
