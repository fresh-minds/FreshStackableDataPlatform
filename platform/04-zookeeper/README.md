# 04-zookeeper

ZooKeeper voor Kafka-coördinatie.

| Resource | Doel |
|---|---|
| `ZookeeperCluster uwv-zookeeper` | 1 server, scaled-down. |
| `ZookeeperZnode uwv-zookeeper-znode-kafka` | Geïsoleerd ZK-pad voor Kafka; produceert ConfigMap met connect-string. |

## Apply

```bash
kubectl apply -k platform/04-zookeeper/
```

## Validatie

```bash
kubectl -n uwv-platform get zookeepercluster
kubectl -n uwv-platform get pods -l app.kubernetes.io/name=zookeeper
kubectl -n uwv-platform get configmap uwv-zookeeper-znode-kafka
```

## Productie

- ≥ 3 replicas (quorum); odd number.
- Aparte StorageClass met SSD/NVMe.
- `listenerClass: external-stable` als externe access nodig is (alleen voor
  beheer; clients praten interne).
