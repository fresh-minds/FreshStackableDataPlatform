# 08-spark

Spark on Kubernetes via Stackable's `SparkApplication` CRD.

| Resource | Doel |
|---|---|
| `SparkApplication streaming-bronze` | Structured Streaming: leest JSONL uit `s3a://uwv-raw/`, schrijft naar Delta bronze (foreachBatch dispatcher per stream). |
| `ConfigMap spark-streaming-jobs` (gegenereerd) | Mount van `streaming_files_to_lakehouse.py` + `lakehouse_io.py`. |

## Architectuur

```
data-generation/load_to_s3.py  →  s3://uwv-raw/<domain>/<entity>/dt=YYYY-MM-DD/*.jsonl
                                              ↓ (Spark file source)
                                  streaming_files_to_lakehouse.py
                                              ↓
                                  bronze.uwv.<domain>_<entity>  (Delta)
```

Geen message bus tussen producer en consumer — MinIO IS de buffer + replay-laag.

## Code-locatie

Canonical bron: [`spark-jobs/`](../../spark-jobs/) — daar staan
`streaming_files_to_lakehouse.py` en `lib/lakehouse_io.py`.

`scripts/deploy-platform.sh` kopieert deze bestanden naar
`platform/08-spark/scripts/` (gitignored) zodat kustomize ze via
`configMapGenerator` kan oppikken — zonder load-restrictor=None.

## Voorvereisten

- `platform/01-secrets/` — `minio-s3-credentials` Secret aanwezig.
- `platform/03-storage/` — `S3Connection s3-minio`; bucket `uwv-raw` bestaat in MinIO.
- `platform/05-hive-metastore/` — HMS Ready.

## Apply

```bash
make deploy-platform   # incl. spark-jobs/ → platform/08-spark/scripts/ sync
# of stand-alone:
kubectl apply -k platform/08-spark/
```

## Validatie

```bash
kubectl -n uwv-platform get sparkapplication
kubectl -n uwv-platform logs -l app.kubernetes.io/instance=streaming-bronze --tail=50
```

In Spark UI: lijst van actieve streaming queries en batch-stats.

## Stream → tabel mapping

| File-pad | Bronze-tabel |
|---|---|
| `s3a://uwv-raw/uwv/persona/created/...` | `bronze.uwv.persona_created` |
| `s3a://uwv-raw/uwv/polisadm/ikv/...` | `bronze.uwv.polisadm_ikv` |
| `s3a://uwv-raw/uwv/ww/aanvraag/...` | `bronze.uwv.ww_aanvraag` |
| `s3a://uwv-raw/uwv/wia/aanvraag/...` | `bronze.uwv.wia_aanvraag` |
| `s3a://uwv-raw/uwv/wajong/dossier/...` | `bronze.uwv.wajong_dossier` |
| `s3a://uwv-raw/uwv/zw/melding/...` | `bronze.uwv.zw_melding` |
| `s3a://uwv-raw/uwv/crm/contact/...` | `bronze.uwv.crm_contact` |
| `s3a://uwv-raw/uwv/fez/uitkeringslast/...` | `bronze.uwv.fez_uitkeringslast` |

## Format-switch

`TABLE_FORMAT` env staat in `streaming-bronze.yaml` op `"delta"`. Voor
Iceberg: wijzig `platform-config.yaml` + de twee env-blokken (driver +
executor).

## Productie

- `replicas: ≥ 3` op executor.
- Aparte SparkApplication per stream-domein (i.p.v. één foreachBatch dispatcher).
- Fault-tolerant execution + retry-policy.
- Delta Lake `OPTIMIZE` schedule + `VACUUM RETAIN 168 HOURS` via maintenance-DAG.
