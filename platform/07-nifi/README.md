# 07-nifi

Apache NiFi via Stackable's NiFiCluster CRD.

| Resource | Doel |
|---|---|
| `ZookeeperZnode uwv-zookeeper-znode-nifi` | NiFi cluster-state. |
| `NiFiCluster uwv-nifi` | NiFi 2.0, 1 node, OIDC via Keycloak. |

## In fase 4: deploy-only, geen flows

De Spark streaming-pijp werkt direct op Kafka-topics die door
`data-generation/load_to_kafka.py` (in-cluster Job) worden gevuld.
NiFi staat klaar voor:

- Fase 5+: SuwiML-adapters, CDC-ingest, PII-tagging at ingest.
- Productie: GetSFTP/GetS3/InvokeHTTP → ValidateRecord → UpdateAttribute (PII-tags) → PublishKafka.

Flow-design beschreven in [`nifi-flows/templates/delta/README.md`](../../nifi-flows/templates/delta/README.md).
NiFi-flows worden via UI of REST-API geïmporteerd zodra ze nodig zijn.

## Apply

```bash
kubectl apply -k platform/07-nifi/
```

## Validatie

```bash
kubectl -n uwv-platform get nificluster
kubectl -n uwv-platform get pods -l app.kubernetes.io/name=nifi
# UI: kubectl port-forward svc/uwv-nifi-node 8443:8443 → https://localhost:8443/nifi
```

OIDC-login via mock-realm-user `data.engineer`.

## Productie

- ≥ 3 nodes (NiFi-cluster met ZK-coordination).
- Provenance + audit-store naar OpenSearch.
- TLS verplicht; geen `auto-generate` van sensitive-key.
- NiFi Registry als source of truth voor flow-definities (CI-deploybaar).
