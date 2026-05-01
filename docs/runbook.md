# Runbook

Operationele handleiding voor het draaien, monitoren, herstellen en uitbreiden
van het UWV Reference Data Platform.

> **Status:** skeleton (fase 0). Definitieve runbook-content wordt in fase 10
> ingevuld zodra alle componenten daadwerkelijk draaien en gedrag is
> geobserveerd. Deze versie schetst alleen de structuur en TODO-items.

---

## 1. Snelstart

Zie [`README.md`](../README.md) voor de happy-path commands.

---

## 2. Cluster lifecycle

### 2.1 Cluster opzetten
```bash
make cluster        # k3d cluster create
make bootstrap      # cert-manager, MinIO, Postgres, Keycloak, Stackable operators
make deploy-platform
```

### 2.2 Cluster pauzeren / hervatten
TODO (fase 1): documenteer `k3d cluster stop/start` en welke services een warmstart nodig hebben.

### 2.3 Cluster volledig opruimen
```bash
make clean          # k3d cluster delete uwv-platform
```

---

## 3. Component-status checken

| Component | Health-check command |
|---|---|
| k3d nodes | `kubectl get nodes` |
| Stackable operators | `kubectl get pods -n stackable-operators` |
| Trino | `kubectl get trinocluster -A` |
| Kafka | `kubectl get kafkacluster -A` |
| Hive Metastore | `kubectl get hivecluster -A` |
| OPA | `kubectl get opacluster -A` |
| Airflow | `kubectl get airflowcluster -A` |
| Superset | `kubectl get supersetcluster -A` |
| NiFi | `kubectl get nificluster -A` |
| OpenMetadata | `kubectl get pods -n uwv-meta` |
| Keycloak | `kubectl get pods -n uwv-auth` |

TODO (fase 2+): vul per component de specifieke "is-het-gezond?" probes in.

---

## 4. Veelvoorkomende incidenten

### 4.1 Trino weigert query met "Access Denied"
- Eerst: log inspecteren — `kubectl logs -n uwv-platform <trino-coordinator-pod> -c trino`.
- OPA-decision-log bekijken in OpenSearch.
- Verifieer rol-toekenning in Keycloak voor de gebruiker.
- TODO (fase 9): voorbeeldqueries per rol.

### 4.2 dbt-run faalt met "table not found"
- Check Hive Metastore: `kubectl exec -it -n uwv-platform <hive-pod> -- ...` (TODO: precieze syntax).
- Verifieer dat eerdere fase-runs (bronze/silver) geslaagd zijn.

### 4.3 Streaming-job blijft hangen
- Spark UI port-forwarden: `kubectl port-forward -n uwv-platform svc/spark-streaming-ui 4040:4040`.
- Checkpoint-bucket inspecteren: `mc alias set local http://minio.uwv-platform.local:80 ...`; `mc ls local/uwv-checkpoints/`.

---

## 5. Backup & restore

TODO (fase 1+):
- MinIO snapshots strategie.
- Postgres dumps voor HMS / Airflow / Superset / OpenMetadata.
- Keycloak realm export.
- Trino state — niet relevant (statelos).

---

## 6. Upgrade-procedure

TODO (fase 1+): Stackable operator upgrades, dbt-package updates, Helm-chart bumps.

---

## 7. Synthetische data herladen

```bash
make seed
```

Dit:
1. Genereert 10k synthetische cliënten + bijbehorende entiteiten in `data-generation/output/`.
2. Pusht via NiFi → Kafka → Spark → Delta-bronze.
3. Triggert dbt-run die silver + gold rebuiltd.

TODO (fase 4+): troubleshooting ingestion-pijplijn.

---

## 8. OPA-policy bijwerken

```bash
# Edit Rego onder opa-policies-src/trino/
opa fmt -w opa-policies-src/
opa test opa-policies-src/

# Bouw bundle naar ConfigMap
bash scripts/build-opa-bundle.sh

# OPA herlaadt automatisch als label opa.stackable.tech/bundle=true gezet is.
```

TODO (fase 9): troubleshooting "policy lijkt niet actief".

---

## 9. Observability dashboards

- Grafana: `http://grafana.uwv-platform.local:8080`
- OpenSearch Dashboards: `http://logs.uwv-platform.local:8080`
- OpenMetadata: `http://openmetadata.uwv-platform.local:8080`

TODO (fase 1/8): default-credentials uit secrets ophalen, voorbeeld-queries.

---

## 10. Compliance-evidence verzamelen

Zie [`compliance-mapping.md`](compliance-mapping.md). Elk R-* code heeft daar
een verwijzing naar het YAML-bestand of de configuratie waar de maatregel
landt. Voor audit:

```bash
# Voorbeeld: bewijs dat encryption-in-transit afgedwongen wordt
grep -r 'tls' platform/ infrastructure/ | grep -v '#'
```

TODO (fase 10): scriptmatig evidence-pakket genereren.
