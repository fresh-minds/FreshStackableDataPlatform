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
| Hive Metastore | `kubectl get hivecluster -A` |
| OPA | `kubectl get opacluster -A` |
| Airflow | `kubectl get airflowcluster -A` |
| Superset | `kubectl get supersetcluster -A` |
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

- Grafana: `https://grafana.uwv-platform.local:8443`
- OpenSearch Dashboards: `https://opensearch.uwv-platform.local:8443`
- OpenMetadata: `https://openmetadata.uwv-platform.local:8443`
- Prometheus: `https://prometheus.uwv-platform.local:8443`
- Alertmanager: in-cluster only — `kubectl -n uwv-monitoring port-forward svc/prometheus-kube-prometheus-alertmanager 9093:9093`
- MailHog (k3d-only, dev-SMTP-sink): `https://mailhog.uwv-platform.local:8443/`

TODO (fase 1/8): default-credentials uit secrets ophalen, voorbeeld-queries.

### 9.1 Alert-pipeline overzicht

```
metrics  → Prometheus → AlertmanagerConfig → email (SMTP) → MailHog (k3d) / UWV-relay (aks)
logs     → Vector log_to_metric → Prometheus → ↑                          └→ Slack #uwv-data-platform
```

Definities:
- Metric-rules: [`platform/14-monitoring/prometheusrule-uwv.yaml`](../platform/14-monitoring/prometheusrule-uwv.yaml)
- Log-rules:    [`platform/14-monitoring/vector-log-alerts.yaml`](../platform/14-monitoring/vector-log-alerts.yaml)
- Receivers:    [`platform/14-monitoring/alertmanager-config.yaml`](../platform/14-monitoring/alertmanager-config.yaml) (k3d) / `platform-overlays/aks/14-monitoring/` (aks)
- Vector-config: [`infrastructure/helm/vector/values.yaml`](../infrastructure/helm/vector/values.yaml) (transforms `detect_alert_events` + `log_to_metric`)

### 9.2 Alert komt niet aan (debug-checklist)

1. **Is Alertmanager actief?** `kubectl -n uwv-monitoring get pods -l app.kubernetes.io/name=alertmanager` — verwacht `Running`.
2. **Is de AlertmanagerConfig geladen?** `kubectl -n uwv-monitoring get alertmanagerconfig uwv-platform-receivers -o yaml` — geen `status.error`.
3. **Vuren de regels?** `kubectl -n uwv-monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090` → http://localhost:9090/alerts.
4. **Komt Alertmanager bij de SMTP-host?** Alertmanager-pod-logs: `kubectl -n uwv-monitoring logs -l app.kubernetes.io/name=alertmanager --tail=100 | grep -i smtp`.
5. **MailHog in k3d** — UI op `https://mailhog.uwv-platform.local:8443/`. Geen mails? Check `kubectl -n uwv-monitoring logs deploy/mailhog`.

### 9.3 End-to-end alert-test

```bash
# Stuur synthetische warning-alert
make alert-test

# Critical-severity (route gaat ook naar Slack)
make alert-test ACTION=critical

# Resolve
make alert-test-resolve
```

Verwacht resultaat:
- k3d : verschijnt binnen ~30s in MailHog UI
- aks : verschijnt binnen ~30s in `platform-alerts@uwv.nl`

### 9.4 Log-based alert: OpaDecisionDenySpike

- Vector detecteert `"result":false` in OPA-logs (zie `detect_alert_events` in helm-values).
- Tellt counter `vector_uwv_alert_event_total{event="opa_deny"}`.
- PrometheusRule `uwv-log-events` vuurt op `rate(...) > 0.2/s` over 5m.
- Onderzoek: query OpenSearch op `uwv-logs-audit-*` met `result: false` filter, of zoek in Trino coordinator-logs welke gebruiker / catalog gewerd.

### 9.5 Log-based alert: JvmOutOfMemory

- Vector matcht `java.lang.OutOfMemoryError` ongeacht container.
- Critical-severity (geen `for:`-window) — vuurt direct na 1e OOM-event in 10m.
- Onderzoek: `kubectl -n {{namespace}} describe pod {{container}}` voor restart-count, vraag heap-size verhogen in de Stackable-CR (`spec.coordinator.config.resources.memory.limit` etc.).

### 9.6 Log-based alert: KeycloakLoginErrorSpike

- Vector matcht event-type `LOGIN_ERROR` in Keycloak-logs.
- Verwacht: doorgaans < 5 fails per minuut.
- Onderzoek: Keycloak admin-console → Events → filter op `LOGIN_ERROR`. Bij brute-force: zet rate-limit aan op ingress-nginx (`nginx.ingress.kubernetes.io/limit-rpm: "60"`).

### 9.7 Alert-pipeline end-to-end test

Zie §9.3. Zelfreferentie zodat alert-template-links niet 404 geven.

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
