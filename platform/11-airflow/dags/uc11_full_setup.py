"""UC-11 — full-platform end-to-end bootstrap.

Eén DAG die UC-11 op een verse cluster volledig operationeel maakt:

  1. wait_for_bronze            — wacht tot synthetische data in bronze staat
  2. silver_* (parallel)        — trigger alle silver-staging DAGs
  3. gold_uc11_klantreis        — bouwt int_klantreis_events + 2 marts
  4. render_dbt_manifest        — dbt parse + upload (OM-compat strip) naar
                                  s3://uwv-meta/dbt/latest/
  5. governance_om_ingest       — Trino-catalog, dbt-lineage, Superset,
                                  Airflow, Kafka — alle ingest-stappen
  6. om_cleanup_duplicates      — verwijder bronze/silver uc11_klantreis
                                  schemas (shared Hive metastore artefact)
  7. om_add_kafka_lineage       — voeg 7 Kafka topic → bronze edges toe
  8. rebuild_superset_dashboard — re-create superset-dashboards-init Job
                                  zodat het UC-11 dashboard (12 charts)
                                  daadwerkelijk wordt gebouwd nadat marts
                                  bestaan

Idempotent: kan onbeperkt worden hergedraaid op dezelfde cluster.

SYNTHETIC DATA — UWV REFERENCE PLATFORM — NOT FOR REAL USE.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.trigger_dagrun import TriggerDagRunOperator
from airflow.providers.cncf.kubernetes.operators.pod import KubernetesPodOperator
from airflow.utils.trigger_rule import TriggerRule
from kubernetes.client.models import V1EnvVar

from k8s_helpers import (
    SMALL_POD_RESOURCES,
    ca_mount,
    ca_volume,
    secret_env,
)

DEFAULT_ARGS = {
    "owner": "data-steward",
    "depends_on_past": False,
    "email_on_failure": False,
    "retries": 0,
    "retry_delay": timedelta(minutes=2),
}

# Silver-DAGs die UC-11 nodig heeft. Parallel triggeren is OK; ze hebben
# geen inter-dependency.
UC11_SILVER_DAGS = [
    "silver_persoon",
    "silver_polisadm",
    "silver_ww",
    "silver_zw",
    "silver_wia",
    "silver_wajong",
    "silver_crm",
]

# ── helper: minimaal KPO-skelet voor onze Python-pods ────────────────

_PY_IMAGE = "openmetadata/ingestion:1.5.7"  # heeft Python 3.10 + requests + minio


def _py_pod(task_id: str, script: str, *, om_jwt: bool = True,
            extra_env: list[V1EnvVar] | None = None) -> KubernetesPodOperator:
    """Run een inline Python-script als KPO met optioneel OM_JWT_TOKEN."""
    env_vars: list[V1EnvVar] = [
        V1EnvVar(name="REQUESTS_CA_BUNDLE", value="/etc/uwv-ca/ca.crt"),
        V1EnvVar(name="SSL_CERT_FILE", value="/etc/uwv-ca/ca.crt"),
    ]
    if om_jwt:
        env_vars.append(secret_env("OM_JWT_TOKEN", "openmetadata-admin", "jwtToken"))
    if extra_env:
        env_vars.extend(extra_env)

    return KubernetesPodOperator(
        task_id=task_id,
        namespace="uwv-platform",
        image=_PY_IMAGE,
        cmds=["python3", "-c"],
        arguments=[script],
        env_vars=env_vars,
        volumes=[ca_volume()],
        volume_mounts=[ca_mount()],
        container_resources=SMALL_POD_RESOURCES,
        is_delete_operator_pod=True,
        get_logs=True,
    )


# ── scripts ───────────────────────────────────────────────────────────

WAIT_FOR_BRONZE_SCRIPT = '''
import json, ssl, time, urllib.request
ctx = ssl._create_unverified_context()
url = "https://uwv-trino-coordinator.uwv-platform.svc.cluster.local:8443/v1/statement"
deadline = time.time() + 600
while time.time() < deadline:
    try:
        req = urllib.request.Request(url, data=b"SELECT count(*) FROM bronze.uwv.persona_created",
            headers={"X-Trino-User":"smoketest","Content-Type":"text/plain"}, method="POST")
        d = json.loads(urllib.request.urlopen(req, context=ctx, timeout=15).read())
        while d.get("nextUri"):
            d = json.loads(urllib.request.urlopen(
                urllib.request.Request(d["nextUri"], headers={"X-Trino-User":"smoketest"}),
                context=ctx, timeout=15).read())
            if d.get("data"):
                n = int(d["data"][0][0])
                print(f"[wait_for_bronze] persona_created rows={n}", flush=True)
                if n > 0:
                    raise SystemExit(0)
                break
    except Exception as e:
        print(f"[wait_for_bronze] poll: {e}", flush=True)
    time.sleep(15)
raise SystemExit("bronze.uwv.persona_created leeg na 10 min")
'''


RENDER_MANIFEST_SCRIPT = '''
import json, os, io, ssl, sys, subprocess, urllib.request
# Run dbt parse via subprocess — dbt-trino image heeft het ingebakken.
# Profiles + project staan op /opt/uwv/dbt.
os.chdir("/opt/uwv/dbt")
os.environ["DBT_PROFILES_DIR"] = "/opt/uwv/dbt"
subprocess.run(["dbt","parse","--no-partial-parse"], check=False)
with open("/opt/uwv/dbt/target/manifest.json") as f:
    m = json.load(f)
# OM 1.5.7 dbt_artifacts_parser is strict — strip newer dbt fields.
for k in ("invocation_started_at","run_started_at","quoting","send_anonymous_usage_stats"):
    m.get("metadata", {}).pop(k, None)
m.pop("functions", None)
data = json.dumps(m).encode()
# Upload via boto3 (zit in OM-ingest-image). MinIO endpoint via cluster-DNS.
import boto3, urllib3
urllib3.disable_warnings()
s3 = boto3.client("s3",
    endpoint_url="https://minio.uwv-platform.svc.cluster.local:9000",
    aws_access_key_id=os.environ["MINIO_ACCESS_KEY"],
    aws_secret_access_key=os.environ["MINIO_SECRET_KEY"],
    verify=False)
s3.put_object(Bucket="uwv-meta", Key="dbt/latest/manifest.json", Body=data)
print(f"manifest uploaded: {len(data)} bytes", flush=True)
'''


# Note: dbt-trino-image doesn't have boto3 by default. We use minio package
# instead which IS in the image for the other minio-uploaders. But the OM
# ingestion image (which we use for the Python pods) has boto3. So we need
# a different approach: render manifest in dbt image, upload via OM image.
# Simpler: do it all in OM image, calling dbt via pip-installed dbt-core +
# dbt-trino. But that adds 2 minutes to pip install. Alternative: split
# in 2 tasks (render in dbt image → write to PVC/emptyDir; upload in OM
# image). Easiest of all: use the dbt-trino image and pip-install boto3 in
# the script. Trade-off: ~30s pip install but single pod.

RENDER_MANIFEST_DBT_SCRIPT = '''
set -eu -o pipefail
cd /opt/uwv/dbt
export DBT_PROFILES_DIR=/opt/uwv/dbt
echo "=== dbt parse ==="
dbt parse --no-partial-parse || echo "(parse warnings — manifest mag wel bestaan)"
test -s target/manifest.json || { echo "manifest niet aangemaakt"; exit 1; }
echo "=== install boto3 + strip + upload ==="
pip install --quiet --disable-pip-version-check boto3 || pip install --quiet boto3
python3 <<PY
import json, os
with open("target/manifest.json") as f:
    m = json.load(f)
for k in ("invocation_started_at","run_started_at","quoting","send_anonymous_usage_stats"):
    m.get("metadata", {}).pop(k, None)
m.pop("functions", None)
data = json.dumps(m).encode()
import boto3, urllib3
urllib3.disable_warnings()
s3 = boto3.client("s3",
    endpoint_url="https://minio.uwv-platform.svc.cluster.local:9000",
    aws_access_key_id=os.environ["MINIO_ACCESS_KEY"],
    aws_secret_access_key=os.environ["MINIO_SECRET_KEY"],
    verify=False)
s3.put_object(Bucket="uwv-meta", Key="dbt/latest/manifest.json", Body=data)
print(f"manifest uploaded: {len(data)} bytes")
PY
'''


CLEANUP_DUPS_SCRIPT = '''
import json, os, urllib.parse, urllib.request, urllib.error
OM = "http://openmetadata.uwv-meta.svc.cluster.local:8585"
JWT = os.environ["OM_JWT_TOKEN"]
HDR = {"Authorization": f"Bearer {JWT}"}

def del_by_fqn(kind, fqn):
    enc = urllib.parse.quote(fqn, safe="")
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"{OM}/api/v1/{kind}/name/{enc}", headers=HDR), timeout=15).read()
        obj_id = json.loads(r).get("id")
    except urllib.error.HTTPError as e:
        print(f"  - {fqn} not present ({e.code})", flush=True)
        return
    url = f"{OM}/api/v1/{kind}/{obj_id}?hardDelete=true&recursive=true"
    try:
        urllib.request.urlopen(urllib.request.Request(url, headers=HDR, method="DELETE"),
                               timeout=15).read()
        print(f"  ✓ deleted {fqn}", flush=True)
    except urllib.error.HTTPError as e:
        print(f"  ! delete {fqn}: {e.code}", flush=True)

for fqn in [
    "uwv-trino.bronze.uc11_klantreis.mart_uc11_klantreis_events",
    "uwv-trino.bronze.uc11_klantreis.mart_uc11_klantreis_phases",
    "uwv-trino.silver.uc11_klantreis.mart_uc11_klantreis_events",
    "uwv-trino.silver.uc11_klantreis.mart_uc11_klantreis_phases",
]:
    del_by_fqn("tables", fqn)
for fqn in [
    "uwv-trino.bronze.uc11_klantreis",
    "uwv-trino.silver.uc11_klantreis",
]:
    del_by_fqn("databaseSchemas", fqn)
'''


KAFKA_LINEAGE_SCRIPT = '''
import json, os, urllib.parse, urllib.request, urllib.error
OM = "http://openmetadata.uwv-meta.svc.cluster.local:8585"
JWT = os.environ["OM_JWT_TOKEN"]
HDR = {"Authorization": f"Bearer {JWT}", "Content-Type":"application/json"}

MAPPINGS = [
    ('uwv-kafka."uwv.persona.created"',  "uwv-trino.bronze.uwv.persona_created"),
    ('uwv-kafka."uwv.polisadm.ikv"',     "uwv-trino.bronze.uwv.polisadm_ikv"),
    ('uwv-kafka."uwv.ww.aanvraag"',      "uwv-trino.bronze.uwv.ww_aanvraag"),
    ('uwv-kafka."uwv.zw.melding"',       "uwv-trino.bronze.uwv.zw_melding"),
    ('uwv-kafka."uwv.wia.aanvraag"',     "uwv-trino.bronze.uwv.wia_aanvraag"),
    ('uwv-kafka."uwv.wajong.dossier"',   "uwv-trino.bronze.uwv.wajong_dossier"),
    ('uwv-kafka."uwv.crm.contact"',      "uwv-trino.bronze.uwv.crm_contact"),
]

def get_id(kind, fqn):
    enc = urllib.parse.quote(fqn, safe="")
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"{OM}/api/v1/{kind}/name/{enc}", headers=HDR), timeout=15).read()
        return json.loads(r).get("id")
    except urllib.error.HTTPError as e:
        print(f"  ! {kind} {fqn}: {e.code}", flush=True)
        return None

added = 0
for topic_fqn, table_fqn in MAPPINGS:
    tid = get_id("topics", topic_fqn)
    bid = get_id("tables", table_fqn)
    if not (tid and bid):
        continue
    body = json.dumps({"edge": {
        "fromEntity": {"id": tid, "type": "topic"},
        "toEntity":   {"id": bid, "type": "table"},
    }}).encode()
    try:
        urllib.request.urlopen(urllib.request.Request(
            f"{OM}/api/v1/lineage", data=body, headers=HDR, method="PUT"
        ), timeout=15).read()
        added += 1
        print(f"  ✓ {topic_fqn} → {table_fqn}", flush=True)
    except urllib.error.HTTPError as e:
        print(f"  ! edge {topic_fqn} → {table_fqn}: {e.code}", flush=True)
print(f"[kafka_lineage] {added}/{len(MAPPINGS)} edges aangemaakt", flush=True)
'''


# Re-creates de superset-dashboards-init Job zodat het UC-11 dashboard
# pas WORDT GEBOUWD nadat onze gold-marts bestaan. We hergebruiken het
# bestaande `superset-dashboards-init-script` ConfigMap.
REBUILD_DASHBOARD_SCRIPT = '''
import json, os, time, urllib.parse, urllib.request, urllib.error
KAPI = "https://kubernetes.default.svc"
with open("/var/run/secrets/kubernetes.io/serviceaccount/token") as f:
    SA_TOKEN = f.read().strip()
import ssl
ctx = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
HDR = {"Authorization": f"Bearer {SA_TOKEN}", "Content-Type":"application/json"}
NS = "uwv-platform"
JOB = "superset-dashboards-init"

# delete existing Job (foreground propagation)
url = f"{KAPI}/apis/batch/v1/namespaces/{NS}/jobs/{JOB}?propagationPolicy=Foreground"
try:
    urllib.request.urlopen(urllib.request.Request(url, headers=HDR, method="DELETE"),
                           context=ctx, timeout=15).read()
    print(f"deleted {JOB}", flush=True)
except urllib.error.HTTPError as e:
    if e.code != 404: print(f"  ! delete: {e.code}", flush=True)

# wait for delete to complete
url = f"{KAPI}/apis/batch/v1/namespaces/{NS}/jobs/{JOB}"
for _ in range(30):
    try:
        urllib.request.urlopen(urllib.request.Request(url, headers=HDR),
                               context=ctx, timeout=10).read()
        time.sleep(2)
    except urllib.error.HTTPError as e:
        if e.code == 404: break

# create fresh Job
body = {
    "apiVersion":"batch/v1","kind":"Job",
    "metadata":{"name":JOB,"namespace":NS,
                "labels":{"uwv.nl/component":"superset-dashboards-init"}},
    "spec":{"ttlSecondsAfterFinished":3600,"backoffLimit":2,
        "template":{"spec":{"restartPolicy":"OnFailure","containers":[{
            "name":"build-dashboards","image":"python:3.11-slim",
            "command":["bash","-euo","pipefail","-c"],
            "args":["pip install --quiet --disable-pip-version-check requests && python /scripts/build_dashboards.py"],
            "env":[
                {"name":"SUPERSET_URL","value":"http://uwv-superset-node:8088"},
                {"name":"ADMIN_USER","valueFrom":{"secretKeyRef":{
                    "name":"superset-postgres-credentials","key":"adminUser.username"}}},
                {"name":"ADMIN_PASSWORD","valueFrom":{"secretKeyRef":{
                    "name":"superset-postgres-credentials","key":"adminUser.password"}}},
                {"name":"WIA_DATASET","value":"mart_uc01_wia_funnel_daily"},
            ],
            "volumeMounts":[{"name":"scripts","mountPath":"/scripts"}],
            "resources":{"requests":{"cpu":"50m","memory":"128Mi"},
                         "limits":{"cpu":"500m","memory":"256Mi"}},
        }],"volumes":[{"name":"scripts","configMap":{"name":"superset-dashboards-init-script"}}]}}}}
url = f"{KAPI}/apis/batch/v1/namespaces/{NS}/jobs"
urllib.request.urlopen(urllib.request.Request(url, data=json.dumps(body).encode(),
                       headers=HDR, method="POST"), context=ctx, timeout=15).read()
print(f"created fresh {JOB}", flush=True)

# poll for completion
url = f"{KAPI}/apis/batch/v1/namespaces/{NS}/jobs/{JOB}"
deadline = time.time() + 300
while time.time() < deadline:
    time.sleep(15)
    r = urllib.request.urlopen(urllib.request.Request(url, headers=HDR),
                               context=ctx, timeout=10).read()
    status = json.loads(r).get("status", {})
    if status.get("succeeded"):
        print("  ✓ job completed", flush=True)
        raise SystemExit(0)
    if status.get("failed"):
        raise SystemExit(f"job {JOB} failed")
raise SystemExit(f"job {JOB} timeout (5 min)")
'''


# ── DAG definition ────────────────────────────────────────────────────

with DAG(
    dag_id="uc11_full_setup",
    description=(
        "UC-11 Integrale Klantreis — eind-tot-eind bootstrap. "
        "Chain't silver-builds → gold-mart → OM-ingest → cleanup + "
        "Kafka-edges → Superset-dashboard."
    ),
    default_args=DEFAULT_ARGS,
    schedule=None,        # alleen manueel — dit is een one-shot bootstrap
    start_date=datetime(2026, 5, 1),
    catchup=False,
    max_active_runs=1,
    tags=["uwv", "uc11", "bootstrap"],
) as dag:

    wait_bronze = _py_pod(
        task_id="wait_for_bronze",
        script=WAIT_FOR_BRONZE_SCRIPT,
        om_jwt=False,
    )

    silver_triggers = [
        TriggerDagRunOperator(
            task_id=f"trigger_{d}",
            trigger_dag_id=d,
            reset_dag_run=True,
            wait_for_completion=True,
            poke_interval=20,
            allowed_states=["success"],
            failed_states=["failed"],
        )
        for d in UC11_SILVER_DAGS
    ]

    trigger_gold = TriggerDagRunOperator(
        task_id="trigger_gold_uc11_klantreis",
        trigger_dag_id="gold_uc11_klantreis",
        reset_dag_run=True,
        wait_for_completion=True,
        poke_interval=20,
        allowed_states=["success"],
        failed_states=["failed"],
    )

    render_manifest = KubernetesPodOperator(
        task_id="render_dbt_manifest",
        namespace="uwv-platform",
        image="uwv/dbt-trino:1.9.0-uwv",
        cmds=["bash", "-c"],
        arguments=[RENDER_MANIFEST_DBT_SCRIPT],
        env_vars=[
            secret_env("MINIO_ACCESS_KEY", "minio-s3-credentials", "accessKey"),
            secret_env("MINIO_SECRET_KEY", "minio-s3-credentials", "secretKey"),
            V1EnvVar(name="REQUESTS_CA_BUNDLE", value="/etc/uwv-ca/ca.crt"),
            V1EnvVar(name="SSL_CERT_FILE", value="/etc/uwv-ca/ca.crt"),
        ],
        volumes=[ca_volume()],
        volume_mounts=[ca_mount()],
        container_resources=SMALL_POD_RESOURCES,
        is_delete_operator_pod=True,
        get_logs=True,
    )

    trigger_om = TriggerDagRunOperator(
        task_id="trigger_governance_om_ingest",
        trigger_dag_id="governance_om_ingest",
        reset_dag_run=True,
        wait_for_completion=True,
        poke_interval=30,
        allowed_states=["success"],
        failed_states=["failed"],
    )

    cleanup = _py_pod(
        task_id="om_cleanup_duplicates",
        script=CLEANUP_DUPS_SCRIPT,
    )

    add_edges = _py_pod(
        task_id="om_add_kafka_lineage",
        script=KAFKA_LINEAGE_SCRIPT,
    )

    rebuild_dash = _py_pod(
        task_id="rebuild_superset_dashboard",
        script=REBUILD_DASHBOARD_SCRIPT,
        om_jwt=False,
    )
    rebuild_dash.trigger_rule = TriggerRule.ALL_DONE

    # Flow
    wait_bronze >> silver_triggers >> trigger_gold >> render_manifest \
        >> trigger_om >> [cleanup, add_edges] >> rebuild_dash
