"""Stream `uwv.<domain>.<entity>` Kafka topics → bronze.<domain>.<entity> Delta/Iceberg.

Schrijft per-topic naar een eigen bronze-tabel via foreachBatch dispatch.
Schema: bronze.uwv.<domain>_<entity> met kolommen:
  payload (string, raw JSON envelope)
  topic, kafka_partition, kafka_offset, kafka_ts (timestamp)
  ingestion_ts (timestamp)
  event_date (date) — partition key

dbt staging-models in fase 5 parsen `payload` naar getypte silver-tabellen.
"""
from __future__ import annotations

import os
import sys

# Maak lib importeerbaar uit ConfigMap-mount.
sys.path.insert(0, "/stackable/spark/jobs")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))

from pyspark.sql import functions as F  # noqa: E402

from lakehouse_io import (  # noqa: E402
    TABLE_FORMAT,
    ensure_bronze_schema,
    get_spark_with_lakehouse_config,
)

KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP",
                            "uwv-kafka-bootstrap.uwv-platform.svc.cluster.local:9092")
TOPIC_PATTERN = os.getenv("TOPIC_PATTERN", "uwv\\..*\\..*")
CHECKPOINT_BASE = os.getenv("CHECKPOINT_BASE", "s3a://uwv-checkpoints/streaming")
TRIGGER_SECONDS = int(os.getenv("TRIGGER_SECONDS", "20"))


def topic_to_table(topic: str) -> str | None:
    """`uwv.persona.created` → `uwv.persona_created` (Hive db=uwv, table=…).

    Trino ziet deze als `bronze.uwv.<table>` via de bronze-catalog.
    Returnt None voor onverwachte topic-naming.
    """
    parts = topic.split(".")
    if len(parts) < 3 or parts[0] != "uwv":
        return None
    domain, *entity_parts = parts[1:]
    entity = "_".join(entity_parts)
    return f"uwv.{domain}_{entity}"


def process_batch(batch_df, batch_id: int) -> None:
    """foreachBatch dispatcher — per topic één write."""
    if batch_df.rdd.isEmpty():
        return
    topics = [r["topic"] for r in batch_df.select("topic").distinct().collect()]
    for topic in topics:
        table = topic_to_table(topic)
        if table is None:
            print(f"  [batch {batch_id}] skip onbekende topic-format: {topic}", flush=True)
            continue
        topic_df = batch_df.filter(F.col("topic") == F.lit(topic))
        # Drop kolom 'topic' uit output; ingest is per-tabel
        out_df = topic_df.drop("topic")
        out_df.write.format(TABLE_FORMAT).mode("append").saveAsTable(table)
        cnt = topic_df.count()
        print(f"  [batch {batch_id}] {topic} → {table}: {cnt} rows", flush=True)


def main() -> int:
    spark = get_spark_with_lakehouse_config("uwv-streaming-kafka-to-bronze")
    spark.sparkContext.setLogLevel("WARN")
    print(f"==> Streaming start (TABLE_FORMAT={TABLE_FORMAT}, pattern={TOPIC_PATTERN})", flush=True)

    ensure_bronze_schema(spark)

    kafka_opts = {
        "kafka.bootstrap.servers": KAFKA_BOOTSTRAP,
        "subscribePattern": TOPIC_PATTERN,
        "startingOffsets": "earliest",
        "failOnDataLoss": "false",
    }
    ssl_cafile = os.environ.get("KAFKA_SSL_CAFILE")
    if ssl_cafile and os.path.exists(ssl_cafile):
        print(f"==> Kafka TLS aan: ssl_cafile={ssl_cafile}", flush=True)
        kafka_opts.update({
            "kafka.security.protocol": "SSL",
            "kafka.ssl.truststore.type": "PEM",
            "kafka.ssl.truststore.location": ssl_cafile,
            "kafka.ssl.endpoint.identification.algorithm": "",
        })
    reader = spark.readStream.format("kafka")
    for k, v in kafka_opts.items():
        reader = reader.option(k, v)
    raw = reader.load()

    enriched = (
        raw
        .selectExpr(
            "CAST(value AS STRING) as payload",
            "topic",
            "partition as kafka_partition",
            "offset as kafka_offset",
            "timestamp as kafka_ts",
        )
        .withColumn("ingestion_ts", F.current_timestamp())
        .withColumn("event_date", F.to_date("kafka_ts"))
    )

    query = (
        enriched.writeStream
        .foreachBatch(process_batch)
        .option("checkpointLocation", f"{CHECKPOINT_BASE}/uwv-bronze")
        .trigger(processingTime=f"{TRIGGER_SECONDS} seconds")
        .start()
    )

    print(f"  Streaming query started: id={query.id} runId={query.runId}", flush=True)
    query.awaitTermination()
    return 0


if __name__ == "__main__":
    sys.exit(main())
