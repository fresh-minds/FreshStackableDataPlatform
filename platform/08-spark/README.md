# 08-spark

Spark on Kubernetes via Stackable's `SparkApplication` CRD.

| Resource | Doel |
|---|---|
| `SparkApplication streaming-bronze` | Streaming Kafka → Delta bronze (foreachBatch dispatcher per topic). |
| `ConfigMap spark-streaming-jobs` (gegenereerd) | Mount van `streaming_kafka_to_lakehouse.py` + `lakehouse_io.py`. |

## Code-locatie

Canonical bron: [`spark-jobs/`](../../spark-jobs/) — daar staan
`streaming_kafka_to_lakehouse.py` en `lib/lakehouse_io.py`.

`scripts/deploy-platform.sh` kopieert deze bestanden naar
`platform/08-spark/scripts/` (gitignored) zodat kustomize ze via
`configMapGenerator` kan oppikken — zonder load-restrictor=None.

## Voorvereisten

- `platform/01-secrets/` — `minio-s3-credentials` Secret aanwezig.
- `platform/03-storage/` — `S3Connection s3-minio`.
- `platform/05-hive-metastore/` — HMS Ready.
- `platform/06-kafka/` — KafkaCluster Ready, met topics gevuld door seed.

## Apply

```bash
make deploy-platform   # incl. spark-jobs/ → platform/08-spark/scripts/ sync
# of stand-alone:
bash scripts/sync-spark-jobs.sh && kubectl apply -k platform/08-spark/
```

## Validatie

```bash
kubectl -n uwv-platform get sparkapplication
kubectl -n uwv-platform logs -l app.kubernetes.io/instance=streaming-bronze --tail=50
```

In Spark UI: lijst van actieve streaming queries en batch-stats.

## Format-switch

`TABLE_FORMAT` env staat in `streaming-bronze.yaml` op `"delta"`. Voor
Iceberg: wijzig `platform-config.yaml` + de twee env-blokken (driver +
executor). In fase 6 wordt dit via een Airflow-helper geautomatiseerd.

## Productie

- `replicas: ≥ 3` op executor.
- Aparte SparkApplication per topic-domein (i.p.v. één foreachBatch dispatcher).
- Fault-tolerant execution + retry-policy.
- Delta Lake `OPTIMIZE` schedule + `VACUUM RETAIN 168 HOURS` via fase-6 maintenance-DAG.
