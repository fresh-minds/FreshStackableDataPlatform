# spark-jobs

PySpark-jobs voor het UWV-platform.

| Bestand | Doel |
|---|---|
| [`lib/lakehouse_io.py`](lib/lakehouse_io.py) | Format-agnostische helper. Leest `TABLE_FORMAT` env; bouwt SparkSession met Hive Metastore + S3A + Delta/Iceberg extensions. |
| [`streaming_files_to_lakehouse.py`](streaming_files_to_lakehouse.py) | File-source streaming: leest JSONL uit `s3a://uwv-raw/<domain>/<entity>/` en schrijft per stream naar `bronze.<domain>.<entity>` via `foreachBatch`. |
| [`seed_bronze_wia.py`](seed_bronze_wia.py) | Vult `bronze.uwv.wia_aanvraag` met N synthetische rijen (start van de WIA-demo). |
| [`batch_silver_wia.py`](batch_silver_wia.py) | Batch: `bronze.uwv.wia_aanvraag` → `silver.wia_spark.aanvraag`. |
| [`batch_gold_wia.py`](batch_gold_wia.py) | Batch: `silver.wia_spark.aanvraag` → `gold.uc01_wia_spark.funnel_daily`. |

De drie `*_wia`-jobs vormen samen de WIA Spark-demo (seed → silver → gold) en
draaien als `SparkApplication`s via:

```bash
make wia-spark-demo
```

> **Lakehouse-onderhoud** (Delta `OPTIMIZE`/`VACUUM`, Iceberg `expire_snapshots`)
> draait als Airflow-DAG —
> [`platform/11-airflow/dags/lakehouse_maintenance.py`](../platform/11-airflow/dags/lakehouse_maintenance.py),
> niet als losse Spark-job.
>
> **Gepland** (nog niet aanwezig): batch-ingest van de polisadministratie
> (fase 5) en feature-engineering voor de Wajong-AI-use-case UC-02 (fase 9+).

## Deployment

De scripts worden via `kustomize configMapGenerator` gemount in de
SparkApplication-pods (zie [`platform/08-spark/`](../platform/08-spark/)).
`scripts/deploy-platform.sh` synchroniseert deze map naar
`platform/08-spark/scripts/` (gitignored) zodat kustomize ze van een
toegestane root-pad kan oppikken.

## Lokaal draaien (zonder cluster)

```bash
cd spark-jobs
TABLE_FORMAT=delta python3 -c "import lib.lakehouse_io as m; print(m.TABLE_FORMAT)"
```

End-to-end testen vereist HMS + MinIO (met `uwv-raw` + `uwv-bronze` buckets); doe dat in de cluster.

## Format-switch

Wijzig in [`platform-config.yaml`](../platform-config.yaml) en
herapply de SparkApplication. De Spark-driver leest `TABLE_FORMAT` env
en gebruikt automatisch de juiste extension + connector.
