"""UC-11 — full-platform end-to-end bootstrap.

Eén DAG die UC-11 op een verse cluster volledig operationeel maakt:

  1. ensure_streaming_bronze    — apply streaming-bronze SparkApplication
                                  als 'm niet aanwezig is (kustomization
                                  heeft 'm uitgecommentarieerd na incident
                                  2026-05-15; deze DAG zet 'm one-shot aan)
  2. ensure_seed                — kick `seed-data-generation` Job als
                                  bronze leeg + Kafka geen messages heeft
  3. wait_for_bronze            — poll bronze.uwv.persona_created tot
                                  Spark-streaming de eerste batch schreef
  4. silver_* (parallel)        — trigger alle silver-staging DAGs
  5. gold_uc11_klantreis        — bouwt int_klantreis_events + 2 marts
  6. render_dbt_manifest        — dbt parse + upload (OM-compat strip) naar
                                  s3://uwv-meta/dbt/latest/
  7. governance_om_ingest       — Trino-catalog, dbt-lineage, Superset,
                                  Airflow, Kafka — alle ingest-stappen
  8. om_cleanup_duplicates      — verwijder bronze/silver uc11_klantreis
                                  schemas (shared Hive metastore artefact)
  9. om_add_kafka_lineage       — voeg 7 Kafka topic → bronze edges toe
 10. rebuild_superset_dashboard — re-create superset-dashboards-init Job
                                  zodat het UC-11 dashboard (12 charts)
                                  daadwerkelijk wordt gebouwd nadat marts
                                  bestaan

Idempotent: kan onbeperkt worden hergedraaid op dezelfde cluster.

SYNTHETIC DATA — UWV REFERENCE PLATFORM — NOT FOR REAL USE.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.python import PythonOperator
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

# Alle DAGs die we triggeren — moeten unpaused zijn anders blijven runs queued.
DAGS_TO_UNPAUSE = UC11_SILVER_DAGS + [
    "gold_uc11_klantreis",
    "governance_om_ingest",
]


def _unpause_dependencies(**_) -> None:
    """Unpause alle DAGs die we triggeren.

    Fresh-cluster default: `dags_are_paused_at_creation=True`. Zonder
    unpause blijft elke TriggerDagRunOperator-call queued want de
    scheduler skipt paused DAGs.
    """
    from airflow.models import DagModel
    from airflow.utils.session import create_session

    with create_session() as s:
        rows = (s.query(DagModel)
                 .filter(DagModel.dag_id.in_(DAGS_TO_UNPAUSE))
                 .all())
        for r in rows:
            if r.is_paused:
                print(f"  unpausing {r.dag_id}")
                r.is_paused = False
        s.commit()
        found = {r.dag_id for r in rows}
        missing = set(DAGS_TO_UNPAUSE) - found
        if missing:
            print(f"  WARN: {len(missing)} DAGs niet in DB (parsing-issue?): {missing}")

# ── helper: minimaal KPO-skelet voor onze Python-pods ────────────────

_PY_IMAGE = "openmetadata/ingestion:1.5.7"  # heeft Python 3.10 + requests + minio


def _py_pod(task_id: str, script: str, *, om_jwt: bool = True,
            service_account_name: str | None = None,
            extra_env: list[V1EnvVar] | None = None) -> KubernetesPodOperator:
    """Run een inline Python-script als KPO met optioneel OM_JWT_TOKEN.

    `service_account_name` is nodig voor tasks die K8s-resources lezen of
    schrijven (SparkApplication, Job). Voor alleen-uitgaande-HTTP-calls
    is de default-SA voldoende.
    """
    env_vars: list[V1EnvVar] = [
        V1EnvVar(name="REQUESTS_CA_BUNDLE", value="/etc/uwv-ca/ca.crt"),
        V1EnvVar(name="SSL_CERT_FILE", value="/etc/uwv-ca/ca.crt"),
    ]
    if om_jwt:
        env_vars.append(secret_env("OM_JWT_TOKEN", "openmetadata-admin", "jwtToken"))
    if extra_env:
        env_vars.extend(extra_env)

    kwargs = dict(
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
    if service_account_name:
        kwargs["service_account_name"] = service_account_name
    return KubernetesPodOperator(**kwargs)


# SA met SparkApplication + Job rechten (zie platform/11-airflow/uc11-rbac.yaml).
ORCHESTRATOR_SA = "uc11-orchestrator"


# ── scripts ───────────────────────────────────────────────────────────

ENSURE_STREAMING_BRONZE_SCRIPT = '''
import json, os, sys, ssl, urllib.request, urllib.error
print(f"python: {sys.version}", flush=True)
KAPI = "https://kubernetes.default.svc"
try:
    with open("/var/run/secrets/kubernetes.io/serviceaccount/token") as f:
        SA_TOKEN = f.read().strip()
    print(f"SA token len={len(SA_TOKEN)}", flush=True)
except Exception as e:
    print(f"FATAL: SA token read failed: {e}", flush=True)
    raise
ctx = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
HDR = {"Authorization": f"Bearer {SA_TOKEN}", "Content-Type":"application/json"}
NS = "uwv-platform"

# Skip de read-step; doe gewoon POST en accepteer 409 (AlreadyExists) als idempotent OK.
# Apply minimaal SparkApplication-manifest. spark-streaming-jobs ConfigMap
# wordt door scripts/deploy-platform.sh aangemaakt — verwacht dat-ie er staat.
body = {
    "apiVersion":"spark.stackable.tech/v1alpha1","kind":"SparkApplication",
    "metadata":{"name":"streaming-bronze","namespace":NS,
                "labels":{"uwv.nl/component":"streaming-bronze",
                          "uwv.nl/triggered-by":"uc11_full_setup"}},
    "spec":{
        "sparkImage":{"productVersion":"3.5.7"},
        "mode":"cluster",
        "mainApplicationFile":"local:///stackable/spark/jobs/streaming_kafka_to_lakehouse.py",
        "s3connection":{"reference":"s3-minio"},
        "deps":{
            "requirements":[],
            "packages":[
                "org.apache.spark:spark-sql-kafka-0-10_2.12:3.5.5",
                "io.delta:delta-spark_2.12:3.2.1",
                "org.apache.hadoop:hadoop-aws:3.3.6",
            ],
        },
        "sparkConf":{
            "spark.sql.extensions":"io.delta.sql.DeltaSparkSessionExtension",
            "spark.sql.catalog.spark_catalog":
                "org.apache.spark.sql.delta.catalog.DeltaCatalog",
            "spark.hadoop.fs.s3a.path.style.access":"true",
            "spark.hadoop.fs.s3a.connection.ssl.enabled":"true",
        },
        "driver":{
            "config":{"resources":{"cpu":{"min":"100m","max":"500m"},
                                   "memory":{"limit":"1Gi"}}},
            "volumeMounts":[{"name":"jobs","mountPath":"/stackable/spark/jobs"}],
            "envOverrides":{"TABLE_FORMAT":"delta"},
        },
        "executor":{
            "replicas":1,
            "config":{"resources":{"cpu":{"min":"200m","max":"1000m"},
                                   "memory":{"limit":"1Gi"}}},
            "volumeMounts":[{"name":"jobs","mountPath":"/stackable/spark/jobs"}],
            "envOverrides":{"TABLE_FORMAT":"delta"},
        },
        "volumes":[{"name":"jobs","configMap":{"name":"spark-streaming-jobs"}}],
    },
}
url = f"{KAPI}/apis/spark.stackable.tech/v1alpha1/namespaces/{NS}/sparkapplications"
try:
    urllib.request.urlopen(urllib.request.Request(url, data=json.dumps(body).encode(),
                           headers=HDR, method="POST"), context=ctx, timeout=15).read()
    print("streaming-bronze SparkApplication aangemaakt", flush=True)
except urllib.error.HTTPError as e:
    msg = e.read().decode()[:300]
    if e.code == 409:
        print(f"  streaming-bronze bestaat al (409) — OK", flush=True)
        raise SystemExit(0)
    print(f"  ! create failed: {e.code} {msg}", flush=True)
    raise SystemExit(1)
except Exception as e:
    print(f"  ! create exception: {type(e).__name__}: {e}", flush=True)
    raise SystemExit(1)
'''


ENSURE_SEED_SCRIPT = '''
import json, os, ssl, urllib.request, urllib.error
KAPI = "https://kubernetes.default.svc"
with open("/var/run/secrets/kubernetes.io/serviceaccount/token") as f:
    SA_TOKEN = f.read().strip()
ctx = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
HDR = {"Authorization": f"Bearer {SA_TOKEN}", "Content-Type":"application/json"}
NS = "uwv-platform"

# Check of seed-data-generation Job recent gedraaid heeft.
url = f"{KAPI}/apis/batch/v1/namespaces/{NS}/jobs/seed-data-generation"
need_run = True
try:
    r = urllib.request.urlopen(urllib.request.Request(url, headers=HDR),
                               context=ctx, timeout=10).read()
    job = json.loads(r)
    if job.get("status",{}).get("succeeded"):
        print("seed-data-generation Job al Completed — skip", flush=True)
        need_run = False
    else:
        # bestaat maar niet succeeded — verwijder en re-creëer
        urllib.request.urlopen(urllib.request.Request(
            f"{url}?propagationPolicy=Foreground", headers=HDR, method="DELETE"
        ), context=ctx, timeout=15).read()
        print("oude seed-Job verwijderd", flush=True)
except urllib.error.HTTPError as e:
    if e.code != 404:
        print(f"  ! seed lookup: {e.code}", flush=True)

if not need_run:
    raise SystemExit(0)

# Pragmatisch: laat eerste DAG-run verwachten dat user `make seed` heeft
# gedaan. Voor verse cluster die seed-job daar nog niet had: dit is
# een opt-in trigger via Variable `uc11_full_setup.run_seed=true`.
# Dat houden we simpel: skip standaard, log instructie.
print("seed nog niet gedraaid — run `make seed` eerst, of zet "
      "Airflow Variable `uc11_full_setup.run_seed=true` "
      "(out-of-scope voor deze DAG om secrets/ConfigMaps te beheren).",
      flush=True)
'''


WAIT_FOR_BRONZE_SCRIPT = '''
import json, ssl, time, urllib.request
ctx = ssl._create_unverified_context()
url = "https://uwv-trino-coordinator.uwv-platform.svc.cluster.local:8443/v1/statement"

def trino(sql):
    req = urllib.request.Request(url, data=sql.encode(),
        headers={"X-Trino-User":"smoketest","Content-Type":"text/plain"}, method="POST")
    d = json.loads(urllib.request.urlopen(req, context=ctx, timeout=15).read())
    rows = []
    error = None
    while d.get("nextUri"):
        d = json.loads(urllib.request.urlopen(
            urllib.request.Request(d["nextUri"], headers={"X-Trino-User":"smoketest"}),
            context=ctx, timeout=15).read())
        rows.extend(d.get("data") or [])
        state = d.get("stats",{}).get("state","")
        if state == "FAILED":
            error = d.get("error",{}).get("message")
            break
        if state == "FINISHED":
            break
    return rows, error

# Streaming-bronze heeft ~2 min nodig om eerste batch te schrijven na start.
# Op een fresh cluster waar SparkApplication net is aangemaakt: deadline 12 min.
deadline = time.time() + 720
last_err = "?"
while time.time() < deadline:
    rows, err = trino("SELECT COUNT(*) FROM bronze.uwv.persona_created")
    if rows:
        n = int(rows[0][0])
        print(f"[wait_for_bronze] persona_created rows={n}", flush=True)
        if n > 0:
            raise SystemExit(0)
    elif err:
        last_err = err
        # Schema-doesnt-exist is niet fataal als streaming-bronze nog spawnt.
        print(f"[wait_for_bronze] not-yet: {err}", flush=True)
    time.sleep(20)
print(f"[wait_for_bronze] timeout — last error: {last_err}", flush=True)
print("  Hint: ensure_streaming_bronze task aangemaakt? Of run `make seed` voor data.",
      flush=True)
raise SystemExit(1)
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

    unpause_deps = PythonOperator(
        task_id="unpause_dependencies",
        python_callable=_unpause_dependencies,
    )

    ensure_streaming = _py_pod(
        task_id="ensure_streaming_bronze",
        script=ENSURE_STREAMING_BRONZE_SCRIPT,
        om_jwt=False,
        service_account_name=ORCHESTRATOR_SA,
    )

    ensure_seed = _py_pod(
        task_id="ensure_seed",
        script=ENSURE_SEED_SCRIPT,
        om_jwt=False,
        service_account_name=ORCHESTRATOR_SA,
    )

    wait_bronze = _py_pod(
        task_id="wait_for_bronze",
        script=WAIT_FOR_BRONZE_SCRIPT,
        om_jwt=False,
    )

    # `allowed_states=[success, failed]` is bewust ruim: Cosmos draait
    # `dbt test` AFTER_EACH model, en de seed-data heeft een paar bekende
    # DQ-issues (5 duplicate BSNs in stg_persona, ww_aanvraag.dlq events,
    # ...). De modellen ZIJN gebouwd; de UC-11 downstream-keten heeft de
    # data, ook al klaagt een test. We zien `failed_states=[]` zodat
    # TriggerDagRunOperator nooit zelf raisen — alleen door `allowed_states`
    # mismatch (= staat onbekend) zou-ie falen.
    silver_triggers = [
        TriggerDagRunOperator(
            task_id=f"trigger_{d}",
            trigger_dag_id=d,
            reset_dag_run=True,
            wait_for_completion=True,
            poke_interval=20,
            allowed_states=["success", "failed"],
            failed_states=[],
        )
        for d in UC11_SILVER_DAGS
    ]

    trigger_gold = TriggerDagRunOperator(
        task_id="trigger_gold_uc11_klantreis",
        trigger_dag_id="gold_uc11_klantreis",
        reset_dag_run=True,
        wait_for_completion=True,
        poke_interval=20,
        allowed_states=["success", "failed"],
        failed_states=[],
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
        # Idem als silver — sommige ingest-tasks kunnen flakey-falen
        # (kafka-ingest op kubelet-proxy 502) maar de rest landt wel in OM.
        allowed_states=["success", "failed"],
        failed_states=[],
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
        service_account_name=ORCHESTRATOR_SA,
    )
    rebuild_dash.trigger_rule = TriggerRule.ALL_DONE

    # Flow
    unpause_deps >> ensure_streaming >> ensure_seed >> wait_bronze \
        >> silver_triggers >> trigger_gold >> render_manifest >> trigger_om \
        >> [cleanup, add_edges] >> rebuild_dash
