# 14-monitoring

Cross-cutting monitoring + reliability resources die niet bij één specifieke
component horen. Toegevoegd in de "quick-wins"-sessie (zie [improvements.md](../../docs/improvements.md)).

| Resource | Improvements # | Doel |
|---|---|---|
| `prometheusrule-uwv.yaml` | #1 | Alert-rules: Trino p99, OPA deny-rate, Spark-lag, Postgres-disk, namespace-quota |
| `alertmanager-config.yaml` | #5 | Slack-receiver (warning) + PagerDuty (critical) — webhook-URLs in Secret `alertmanager-receivers` |
| `pdb-uwv.yaml` | #3 | PodDisruptionBudgets voor alle stateful Stackable-clusters + Postgres + OpenSearch |
| `hpa-trino.yaml` | #3 | HorizontalPodAutoscaler op Trino-workers (1-3 replicas in dev) |
| `opensearch-ilm-job.yaml` | #15 | One-shot Job die ILM-policies toepast: app-logs 30d delete, audit-logs 7 jaar |

## Voorvereisten

- kube-prometheus-stack actief (PrometheusRule + AlertmanagerConfig CRDs).
- OpenSearch operationeel (`uwv-meta` namespace).
- (Voor HPA): metrics-server of prometheus-adapter geïnstalleerd. K3d heeft metrics-server uit; productie heeft 'm aan.

## Apply

```bash
kubectl apply -k platform/14-monitoring/
```

## Validatie

```bash
# Alert-rules in Prometheus
kubectl -n uwv-monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090
# → http://localhost:9090/rules

# Alertmanager-config geladen
kubectl -n uwv-monitoring get alertmanagerconfig

# PDBs
kubectl get pdb -A | grep uwv

# HPA-status
kubectl -n uwv-platform get hpa

# ILM-job complete
kubectl -n uwv-meta logs job/opensearch-ilm-bootstrap
```

## Productie

- Alertmanager.enabled: true in helm-values (nu false in dev).
- Slack-webhook + PagerDuty routing-key uit Vault via External Secrets.
- HPA `maxReplicas: 10+`.
- ILM-policies: pas index-rollover-tresholds aan op verwacht volume.
