# 00-namespaces

Declaratieve namespaces voor het UWV-platform. Ook door
`scripts/bootstrap.sh` (Helm) idempotent aangemaakt; dit bestand is canonical.

| Namespace | Inhoud |
|---|---|
| `uwv-platform` | Stackable workloads: ZK, HMS, Kafka, NiFi, Spark, Trino, OPA, Airflow, Superset |
| `uwv-data` | Gedeelde Postgres-instance |
| `uwv-meta` | OpenMetadata + OpenSearch |
| `uwv-monitoring` | kube-prometheus-stack (Prometheus, Grafana) |
| `uwv-auth` | Keycloak |

Labels (`uwv.nl/*`) worden door OpenMetadata's Kubernetes-connector (fase 8)
opgepikt voor governance-context.

## Apply

```bash
kubectl apply -k platform/00-namespaces/
```
