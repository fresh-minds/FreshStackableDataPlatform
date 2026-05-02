# 06-kafka

Kafka als event backbone (NiFi → Kafka → Spark → Delta).

| Resource | Doel |
|---|---|
| `KafkaCluster uwv-kafka` | 1 broker, single-AZ, gebruikt ZK Znode `uwv-zookeeper-znode-kafka`. |

Topics worden automatisch aangemaakt door producers (`auto.create.topics.enable=true`)
voor demo-doeleinden. Conventie:

- `uwv.<domain>.<event>` — bv. `uwv.wia.aanvraag`, `uwv.ww.aanvraag`, `uwv.polisadm.aangifte`.
- `uwv.<domain>.<event>.dlq` — dead-letter (handmatig te creëren in fase 4).
- `uwv.audit.<scope>` — auditlogs (fase 9).
- `uwv.trino.queries` — query-history voor OpenMetadata-lineage (fase 8).

## Voorvereisten

- ZK + Znode uit `04-zookeeper/`.

## Apply

```bash
kubectl apply -k platform/06-kafka/
```

## Validatie

```bash
kubectl -n uwv-platform get kafkacluster
kubectl -n uwv-platform get pods -l app.kubernetes.io/name=kafka

# Eenvoudige producer/consumer-test via een tijdelijke Pod:
kubectl -n uwv-platform run kfk-test --rm -it --image=bitnami/kafka:3.7 \
  --restart=Never -- bash -c '
    kafka-console-producer.sh --bootstrap-server uwv-kafka-broker:9092 --topic test
  '
```

## Productie

- ≥ 3 brokers, replication-factor 3, `min.insync.replicas: 2`.
- ACLs aanzetten (Kafka-OPA-integratie via Stackable).
- TLS aan, SASL voor authentication.
- KRaft-mode (zonder ZK) wanneer Stackable dat ondersteunt; voor nu blijft ZK.
