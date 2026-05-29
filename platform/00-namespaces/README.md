# 00-namespaces

Declaratieve namespaces voor het UWV-platform. Ook door
`scripts/bootstrap.sh` (Helm) idempotent aangemaakt; dit bestand is canonical.

| Namespace | Inhoud |
|---|---|
| `uwv-platform` | Stackable workloads: HMS, Spark, Trino, OPA, Airflow, Superset (ZooKeeper/Kafka/NiFi-operators staan uit in deze release) |
| `uwv-data` | Gedeelde Postgres-instance |
| `uwv-meta` | OpenMetadata + OpenSearch |
| `uwv-monitoring` | kube-prometheus-stack (Prometheus, Grafana) |
| `uwv-auth` | Keycloak |

Labels (`uwv.nl/*`) worden door OpenMetadata's Kubernetes-connector (fase 8)
opgepikt voor governance-context.

## Deploy

```bash
kubectl apply -k platform/00-namespaces/
```

## Verify

```bash
kubectl get ns -l uwv.nl/environment=dev   # de uwv-* namespaces moeten Active zijn
```
