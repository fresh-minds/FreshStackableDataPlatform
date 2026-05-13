#!/usr/bin/env python3
"""Voeg Kafka-topic → bronze-tabel lineage edges toe in OpenMetadata.

OM's Trino-source detecteert geen Kafka-upstream omdat de fysieke link
(Spark Structured Streaming) buiten Trino's query-log valt. We voegen de
edges expliciet toe via /api/v1/lineage met topic + bronze-table-pair.

UC-11-relevante mappings: 7 topics → 7 bronze tables.
"""
import json, sys, os, urllib3, requests
urllib3.disable_warnings()

OM = "https://openmetadata.uwv-platform.local:8443"
JWT = os.environ["OM_JWT"]
HDR = {"Authorization": f"Bearer {JWT}", "Content-Type": "application/json"}

# (topic-FQN, bronze-table-FQN) pairs — alle UC-11-bronnen.
MAPPINGS = [
    ('uwv-kafka."uwv.persona.created"',  "uwv-trino.bronze.uwv.persona_created"),
    ('uwv-kafka."uwv.polisadm.ikv"',     "uwv-trino.bronze.uwv.polisadm_ikv"),
    ('uwv-kafka."uwv.ww.aanvraag"',      "uwv-trino.bronze.uwv.ww_aanvraag"),
    ('uwv-kafka."uwv.zw.melding"',       "uwv-trino.bronze.uwv.zw_melding"),
    ('uwv-kafka."uwv.wia.aanvraag"',     "uwv-trino.bronze.uwv.wia_aanvraag"),
    ('uwv-kafka."uwv.wajong.dossier"',   "uwv-trino.bronze.uwv.wajong_dossier"),
    ('uwv-kafka."uwv.crm.contact"',      "uwv-trino.bronze.uwv.crm_contact"),
]


def get_id(kind: str, fqn: str) -> str:
    # Kafka topic-FQNs bevatten quotes; URL-encode het pad.
    import urllib.parse
    enc = urllib.parse.quote(fqn, safe='')
    r = requests.get(f"{OM}/api/v1/{kind}/name/{enc}", headers=HDR, verify=False)
    if r.status_code != 200:
        print(f"  ! {kind} {fqn}: {r.status_code} {r.text[:120]}")
        return None
    return r.json()["id"]


for topic_fqn, table_fqn in MAPPINGS:
    topic_id = get_id("topics", topic_fqn)
    table_id = get_id("tables", table_fqn)
    if not (topic_id and table_id):
        continue
    payload = {
        "edge": {
            "fromEntity": {"id": topic_id, "type": "topic"},
            "toEntity":   {"id": table_id, "type": "table"},
            "lineageDetails": {
                "pipeline": None,
                "description": "Spark Structured Streaming — uwv-kafka topic → bronze Delta-tabel (zie spark-jobs/streaming_kafka_to_lakehouse.py).",
            },
        }
    }
    r = requests.put(f"{OM}/api/v1/lineage", headers=HDR,
                     data=json.dumps(payload), verify=False)
    status = "✓" if r.status_code in (200, 201) else "!"
    print(f"  {status}  {topic_fqn.split('.')[-1]} → {table_fqn.split('.')[-1]}  ({r.status_code})")
