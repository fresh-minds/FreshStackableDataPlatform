# Handmatige CSV-upload — runbook

End-to-end pad voor een ad-hoc CSV-bron: van upload tot gold-tabel + Superset.
Gebruikt de `klanttevredenheid`-bron als demo; pattern is generiek voor elke
bron met `sla.mode: csv_batch` in [`platform/11-airflow/sources/`](../../platform/11-airflow/sources/).

> **SYNTHETIC DATA — UWV REFERENCE PLATFORM — NOT FOR REAL USE.**

---

## Wanneer gebruik je dit pad?

- Eénmalige of periodieke CSV uit een bronsysteem zonder Kafka-aansluiting.
- Klein volume (≤ enkele miljoenen rijen) waarvoor streaming overkill is.
- Tabel-schema is bekend en stabiel — wordt afgedwongen door de source-YAML.

Voor continue events (WIA, WW, polisadministratie, …) gebruik je het
Kafka-pad — zie [ADR-0007](../adr/0007-airflow-pipeline-architecture.md).

---

## Architectuur in één blik

```
gebruiker
   │  upload CSV
   ▼
MinIO  s3://uwv-staging/incoming/<bron>/<bestand>.csv
   │  (handmatige Airflow-trigger met object_key)
   ▼
Airflow DAG  ingest_csv_<bron>
   │  KubernetesPodOperator → csv_to_bronze.py
   │  - leest CSV uit staging
   │  - valideert schema (uit source-YAML)
   │  - schrijft Delta naar s3://uwv-bronze/uwv/<table>/
   │  - registreert tabel in Trino (CALL system.register_table)
   │  - verplaatst CSV naar processed/
   │  publiceert bronze-Dataset
   ▼
Airflow DAG  silver_<domain>     (auto-trigger via Dataset)
   │  Cosmos → dbt run --select tag:<domain>,tag:staging
   │  publiceert silver-Dataset
   ▼
Airflow DAG  gold_<uc>_<naam>    (auto-trigger via Dataset)
   │  Cosmos → dbt run --select tag:<uc>
   ▼
Superset-dashboard
```

---

## Stap 1 — Source-YAML controleren

Een nieuwe CSV-bron vereist één YAML in
[`platform/11-airflow/sources/`](../../platform/11-airflow/sources/) met:

- `sla.mode: csv_batch` (in plaats van `streaming` of `batch`)
- `ingest:` blok met staging-bucket en CSV-schema
- géén `kafka:` blok

Voorbeeld: [`klanttevredenheid.yml`](../../platform/11-airflow/sources/klanttevredenheid.yml).

Na een wijziging:

```bash
make deploy-platform   # of: kubectl apply -k platform/11-airflow/
```

De source-YAML komt via een ConfigMap in de Airflow-pods terecht; nieuwe
DAGs verschijnen na een DAG-parse-cycle (~30s).

---

## Stap 2 — CSV-bestand uploaden naar MinIO

### Optie A — Browser (MinIO Console)

1. Open [MinIO Console](https://minio-console.uwv-platform.local:8443) (SSO via Keycloak, of root `uwvadmin`).
2. Navigeer naar `uwv-staging` → `incoming/<bron>/`.
3. Drop het CSV-bestand. Naam mag vrij gekozen worden — bv. `2026-05-01.csv`.

### Optie B — CLI (`mc`)

Vereist een `uwv-platform` alias in `~/.mc/config.json`:

```bash
mc cp ./mijn-meting.csv \
  uwv-platform/uwv-staging/incoming/klanttevredenheid/$(date -u +%Y%m%dT%H%M%S).csv
```

### Optie C — Portal

Open [/csv-upload](https://platform.uwv-platform.local:8443/csv-upload/) — de
portal toont per bron de juiste deeplinks en commands.

---

## Stap 3 — Airflow-DAG triggeren

1. Open [Airflow](https://airflow.uwv-platform.local:8443).
2. Zoek de DAG `ingest_csv_<bron>` (bv. `ingest_csv_klanttevredenheid`).
3. Klik **Trigger DAG w/ config** en geef:

   ```json
   {"object_key": "incoming/klanttevredenheid/2026-05-01.csv"}
   ```

4. De DAG heeft één task `csv_to_bronze` die ~30–60s duurt:
   - eerste run: `pip install` + `register_table`
   - vervolgruns: alleen append + register-skip

### Wat gebeurt er bij fouten?

| Fout | Oorzaak | Actie |
|---|---|---|
| `object_key valt niet onder prefix` | upload zat niet onder `incoming/<bron>/` | upload opnieuw in juiste prefix |
| `CSV mist kolommen: [...]` | header wijkt af van source-YAML schema | corrigeer CSV of update YAML |
| `kolom X required maar bevat N null-waarden` | lege cellen in verplichte kolom | corrigeer CSV |
| `kolom X heeft Y waarden < min` | range-violation (bv. score=0) | corrigeer CSV |
| `register_table` faalt | Trino-credentials/permissions | check `trino-static-users` secret + OPA-policy |

Bij een falende run blijft de CSV in `incoming/` staan zodat hertrigger
mogelijk is. Bij succes verplaatst de loader 'm naar
`processed/<bron>/<timestamp>_<hash>_<naam>.csv` om dubbele ingest te voorkomen.

---

## Stap 4 — Verificatie

```sql
-- In Trino (smoketest of via OIDC):
SELECT count(*), max(ingestion_ts)
FROM bronze.uwv.klanttevredenheid;

-- Silver (auto getriggerd):
SELECT * FROM silver.klantcontact.stg_klanttevredenheid LIMIT 10;

-- Gold (auto getriggerd):
SELECT *
FROM gold.uc_klant_tev.mart_uc_klant_tev_kanaal_maand
ORDER BY maand DESC, kanaal;
```

In Superset opent het dashboard *Klanttevredenheid trend* automatisch
(eerste run vereist mogelijk handmatige refresh van de Superset-dataset).

OpenMetadata pikt de nieuwe tabellen op bij de volgende
`governance_om_ingest`-run (uurlijks).

---

## Een nieuwe CSV-bron toevoegen

Checklist (zelfde flow als een Kafka-bron, minus Kafka/Spark):

1. Voeg toe: `platform/11-airflow/sources/<bron>.yml` met `mode: csv_batch`.
2. Voeg toe: `dbt/models/staging/<domain>/stg_<bron>.sql` + `_stg_<bron>.yml`.
3. Voeg toe (alleen voor nieuwe domain): `+schema` regel in
   `dbt/dbt_project.yml` onder `staging:`.
4. Voeg toe: `dbt/models/marts/<uc>/mart_<...>.sql` + `_<uc>.yml`.
5. Update `gold_factory.ACTIVE_USE_CASES` met de nieuwe UC (alleen voor
   nieuwe UC).
6. Voeg toe in `platform/11-airflow/kustomization.yaml`:
   `sources/<bron>.yml` onder `airflow-sources`.
7. Optioneel: voeg toe aan portal-bronlijst in
   `portal/src/pages/csv-upload.astro`.
8. Apply:
   ```bash
   kubectl apply -k platform/11-airflow/
   make dbt-manifest      # of equivalente target
   ```

---

## Veelgestelde vragen

**Kan ik meerdere CSV's tegelijk uploaden?**
Ja — trigger de DAG meerdere keren met verschillende `object_key`. Of upload
ze allemaal en trigger één-voor-één.

**Wat als ik per ongeluk dezelfde CSV twee keer trigger?**
De tweede run faalt op `download` (file is verplaatst naar `processed/`).
Geen dubbele rijen.

**Kan ik partitioneren op een andere kolom dan `event_date`?**
Pas `bronze.partition_by` aan in de source-YAML; `csv_to_bronze.py` voegt de
kolom dan automatisch toe (default-waarde: vandaag in UTC). Voor backfill
moet `csv_to_bronze.py` een conf-veld krijgen — niet in scope voor MVP.

**Is dit pad geschikt voor PII?**
Technisch ja, maar wees voorzichtig: de CSV staat in MinIO `uwv-staging`
totdat de DAG draait. Voor PII gebruik je liever het Kafka-pad met
field-level pseudonymize-macro of de `sensitive` zone — niet `bronze`.
