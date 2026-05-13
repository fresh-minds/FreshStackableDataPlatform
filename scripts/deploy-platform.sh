#!/usr/bin/env bash
# Deploy alle platform-manifests onder platform/ (fasen 2-9).
#
# STUB voor fase 1 — wordt in fase 2 verder ingevuld zodra
# platform/00-namespaces / 01-secrets / etc. bestaan.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# Trino catalog templates renderen voor we 09-trino aanraken.
log "Rendering Trino catalogs (TABLE_FORMAT=${TABLE_FORMAT:-from-config})"
python3 "$ROOT/scripts/render-trino-catalogs.py"

# Spark-jobs sync — kustomize kan niet uit ../../<dir> laden zonder
# load-restrictor=None, dus we kopieren naar platform/08-spark/scripts/.
log "Syncing spark-jobs/ -> platform/08-spark/scripts/"
mkdir -p "$ROOT/platform/08-spark/scripts"
cp "$ROOT/spark-jobs/streaming_kafka_to_lakehouse.py" "$ROOT/platform/08-spark/scripts/"
cp "$ROOT/spark-jobs/lib/lakehouse_io.py"             "$ROOT/platform/08-spark/scripts/"

# Volgorde van applicatie. Per directory een README.md (TODO fase 2+).
LAYERS=(
  "platform/00-namespaces"
  "platform/01-secrets"
  "platform/02-authentication"
  "platform/03-storage"
  "platform/04-zookeeper"
  "platform/05-hive-metastore"
  "platform/06-kafka"
  "platform/07-nifi"
  "platform/08-spark"
  "platform/09-trino"
  "platform/10-opa"
  "platform/11-airflow"
  "platform/12-superset"
  "platform/13-openmetadata-config"
  "platform/14-monitoring"
  "platform/15-portal"
)

for layer in "${LAYERS[@]}"; do
  if [[ -d "$ROOT/$layer" ]] && find "$ROOT/$layer" -maxdepth 2 -name '*.yaml' | grep -q .; then
    log "Apply $layer"
    kubectl apply -k "$ROOT/$layer" 2>/dev/null \
      || kubectl apply -f "$ROOT/$layer/" --recursive
  else
    log "$layer — leeg, skip (wordt in latere fase ingevuld)"
  fi
done

# CoreDNS-override voor in-cluster resolutie van *.uwv-platform.local.
# Achtergrond: k3d kopieert de host-/etc/hosts naar de cluster-resolver
# zodat alle hostnames die de gebruiker daar heeft staan (127.0.0.1
# minio-console.uwv-platform.local etc.) ook in de pods naar 127.0.0.1
# wijzen. Voor MinIO/OpenMetadata/Superset/Airflow/Trino/NiFi die
# server-side OIDC-discovery doen tegen https://keycloak.uwv-platform.local:8443
# is dat fataal — ze proberen verbinding te maken met hun eigen loopback.
# Fix: laat CoreDNS *.uwv-platform.local naar de keycloak-external Service
# in ingress-nginx wijzen (die mappt 8443 → 443 op ingress-nginx-controller).
# uwv-ca-bundle uitbreiden met de Stackable secret-operator self-signed CA.
# Bootstrap probeert dit ook (via een trigger-pod), maar als de operator dan
# nog niet klaar is om certs uit te delen, blijft de bundle alleen het
# uwv-platform-issuer CA en faalt later TLS-verify naar Trino/Hive
# (Superset → Trino, OM Java truststore, etc). Hier zijn alle pods al
# een tijdje TLS aan het opvragen, dus secret-provisioner-tls-ca bestaat.
log "uwv-ca-bundle (her)opbouwen: Mozilla public roots + UWV-CA + Stackable secret-operator CA"
# Public roots zijn nodig zodat Airflow/Superset/Trino (Python REQUESTS_CA_BUNDLE
# en SSL_CERT_FILE wijzen naar /etc/uwv-ca/ca.crt) Let's Encrypt certs van
# keycloak.eu-sovereigndataplatform.com kunnen verifiëren bij OIDC-token-
# exchange. Zonder die roots → "unable to get local issuer certificate".
# UWV-CA is voor cert-manager-issued Keycloak op .local + interne TLS.
# Stackable-CA is voor in-cluster Trino/Hive/Kafka TLS (Superset → Trino).
if kubectl -n stackable-operators get secret secret-provisioner-tls-ca >/dev/null 2>&1; then
  TMP=$(mktemp -d)
  curl -fsSL --connect-timeout 10 https://curl.se/ca/cacert.pem -o "$TMP/public.crt"
  kubectl -n cert-manager get secret uwv-platform-ca -o jsonpath='{.data.ca\.crt}' 2>/dev/null \
    | base64 -d > "$TMP/uwv.crt"
  kubectl -n stackable-operators get secret secret-provisioner-tls-ca \
    -o jsonpath='{.data.0\.ca\.crt}' | base64 -d > "$TMP/stackable.crt"
  if [[ -s "$TMP/public.crt" && -s "$TMP/uwv.crt" && -s "$TMP/stackable.crt" ]]; then
    cat "$TMP/public.crt" "$TMP/uwv.crt" "$TMP/stackable.crt" > "$TMP/combined.crt"
    # delete+create (apply hits 256KB last-applied-configuration annotation
    # limit — the combined bundle is ~220 KB).
    kubectl -n uwv-platform delete configmap uwv-ca-bundle --ignore-not-found >/dev/null
    kubectl -n uwv-platform create configmap uwv-ca-bundle \
      --from-file=ca.crt="$TMP/combined.crt" >/dev/null
    kubectl -n uwv-meta delete configmap uwv-ca-bundle --ignore-not-found >/dev/null
    kubectl -n uwv-meta create configmap uwv-ca-bundle \
      --from-file=ca.crt="$TMP/combined.crt" >/dev/null
    n=$(grep -c "BEGIN CERT" "$TMP/combined.crt")
    printf '\033[1;32mOK\033[0m uwv-ca-bundle bevat nu %s certs (Mozilla + UWV + Stackable)\n' "$n"
    # Roll workloads die de bundle mounten, zodat hun proces de nieuwe file
    # ziet (de mounted file via ConfigMap-volume update zelf automatisch,
    # maar Python's `ssl` cached zijn context bij eerste open).
    kubectl -n uwv-platform delete pod -l app.kubernetes.io/name=superset --ignore-not-found >/dev/null 2>&1 || true
    kubectl -n uwv-platform delete pod -l app.kubernetes.io/name=airflow --ignore-not-found >/dev/null 2>&1 || true
    kubectl -n uwv-meta delete pod -l app.kubernetes.io/name=openmetadata --ignore-not-found >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
else
  printf '\033[1;33m!!\033[0m secret-provisioner-tls-ca nog niet aanwezig (Stackable operators staan nog niet TLS uit te delen?). Re-run deploy-platform later.\n'
fi

log "CoreDNS-override voor *.uwv-platform.local"
KC_SVC_IP=""
for i in {1..30}; do
  KC_SVC_IP=$(kubectl -n ingress-nginx get svc keycloak-external -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  [[ -n "$KC_SVC_IP" && "$KC_SVC_IP" != "None" ]] && break
  sleep 2
done
if [[ -z "$KC_SVC_IP" || "$KC_SVC_IP" == "None" ]]; then
  printf '\033[1;33m!!\033[0m keycloak-external Service nog niet beschikbaar; CoreDNS-override overgeslagen\n'
else
  kubectl -n kube-system create configmap coredns-custom --from-literal="uwv-platform.server=uwv-platform.local:53 {
    errors
    cache 30
    template IN A uwv-platform.local {
        match .*\\.uwv-platform\\.local
        answer \"{{ .Name }} 60 IN A ${KC_SVC_IP}\"
        fallthrough
    }
}
" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n kube-system rollout restart deployment coredns >/dev/null
  kubectl -n kube-system rollout status deployment coredns --timeout=60s >/dev/null
  printf '\033[1;32mOK\033[0m CoreDNS routet *.uwv-platform.local → %s (keycloak-external Service)\n' "$KC_SVC_IP"
fi

# MinIO laadt OIDC-config alleen bij startup. Als de pod bootte vóór dat
# keycloak.uwv-platform.local resolveerbaar was (CoreDNS-override boven),
# faalt de eerste OpenID-discovery met "connection refused" en MinIO valt
# terug op `loginStrategy: form` — geen Keycloak-knop op de console of
# /go/minio/ portal-redirect. Restart pakt OIDC opnieuw op.
log "MinIO restarten zodat OIDC-discovery via Keycloak slaagt"
kubectl -n uwv-platform delete pod -l app=minio --ignore-not-found >/dev/null 2>&1 || true

# Live Keycloak runtime patches die niet uit de realm-import komen.
# Realm-import strategy=IGNORE_EXISTING raakt bestaande users niet aan; en
# attributen op users zoals `policy=consoleAdmin` (vereist door MinIO's
# `MINIO_IDENTITY_OPENID_CLAIM_NAME=policy` claim-mapper) zitten niet
# standaard in de import. Dezelfde stap zit in scripts/full-deploy.sh §8.
log "Keycloak: TOTP wissen + policy=consoleAdmin op demo-admins"
if kubectl -n uwv-auth get pod keycloak-0 >/dev/null 2>&1; then
  kubectl -n uwv-auth exec keycloak-0 -c keycloak -- bash -c '
T=$(curl -fsS -d "client_id=admin-cli" -d "username=kcadmin" -d "password=uwv-dev-only-CHANGE-ME-2026" -d "grant_type=password" http://localhost:8080/realms/master/protocol/openid-connect/token 2>/dev/null | sed "s/.*access_token\":\"\([^\"]*\)\".*/\1/")
[ -z "$T" ] && { echo "Keycloak admin login faalde"; exit 0; }
A="Authorization: Bearer $T"
KC=http://localhost:8080
for u in platform.admin wia.beoordelaar wajong.arbeidsdeskundige data.engineer; do
  KCUID=$(curl -fsS -H "$A" "$KC/admin/realms/uwv/users?username=$u" 2>/dev/null | grep -oE "\"id\":\"[^\"]*\"" | head -1 | cut -d"\"" -f4)
  [ -z "$KCUID" ] && continue
  curl -sS -X PUT -H "$A" -H "Content-Type: application/json" "$KC/admin/realms/uwv/users/$KCUID" \
    -d "{\"username\":\"$u\",\"email\":\"$u@uwv-platform.local\",\"emailVerified\":true,\"enabled\":true,\"requiredActions\":[],\"attributes\":{\"policy\":[\"consoleAdmin\"]}}" -o /dev/null
  curl -sS -X DELETE -H "$A" "$KC/admin/realms/uwv/attack-detection/brute-force/users/$KCUID" -o /dev/null
done
echo "Keycloak runtime patches OK"
' 2>&1 | tail -2
fi

# Superset: na eerste OIDC-login krijgen UWV-users de `Public`-rol.
# AUTH_ROLES_SYNC_AT_LOGIN promoot via realm_access.roles als die in de
# access_token zit; in deze realm zit die niet altijd, dus we promoten
# alle Public-only users handmatig naar Admin (demo-cluster only).
log "Superset: Admin-rol op demo-users zonder rollen"
if kubectl -n uwv-platform get pod uwv-superset-node-default-0 >/dev/null 2>&1; then
  kubectl -n uwv-platform exec uwv-superset-node-default-0 -c superset -- python3 -c '
from superset.app import create_app
app = create_app()
with app.app_context():
    from flask_appbuilder.security.sqla.models import User, Role
    from superset import db
    admin = db.session.query(Role).filter_by(name="Admin").first()
    if not admin:
        print("Admin role missing — Superset niet geïnitialiseerd?")
    else:
        for u in db.session.query(User).all():
            if not u.roles or all(r.name == "Public" for r in u.roles):
                u.roles = [admin]
                db.session.commit()
                print(f"upgraded {u.username} -> Admin")
' 2>&1 | tail -10 || true
fi

# dbt-manifest ConfigMap voor Cosmos LoadMode.DBT_MANIFEST.
# De originele dbt-manifest-render Job (platform/11-airflow/jobs/) gebruikt
# git-sync tegen een private GitHub-repo, en het rauwe manifest.json (~1.4MB)
# overschrijdt de ConfigMap data-limiet (1MB). De Airflow-scheduler heeft
# echter al een `manifest-decompress` initContainer die `manifest.json.gz`
# en `dbt-project.tar.gz` uit binaryData uitpakt — we leveren die hier
# direct vanaf de host via de uwv/dbt-trino:1.9.0-uwv image (~135KB gzipd).
# Superset-init Job re-runt zodat hij na de CA-bundle update + Superset
# pod-roll de Trino-databases registreert. Backoff van een eerdere Failed
# Job blokkeert anders een retry.
log "superset-init Job opnieuw triggeren (na CA-bundle update + pod-roll)"
kubectl -n uwv-platform delete job superset-init --ignore-not-found >/dev/null 2>&1 || true
kubectl apply -k "$ROOT/platform/12-superset" >/dev/null 2>&1 || true

# OpenMetadata: seed admin JWT + re-trigger openmetadata-init Job.
# Bootstrap probeert dit ook (fail-soft), maar OM is dan vaak nog niet up
# → JWT-secret blijft leeg → openmetadata-init API-calls krijgen 401
# en classifications/glossary worden niet geladen. Hier is OM Ready.
log "OpenMetadata: decrypt ingestion-bot JWT + re-trigger init-Job"
if kubectl -n uwv-meta rollout status deploy/openmetadata --timeout=5m >/dev/null 2>&1; then
  FERNET=$(kubectl -n uwv-meta get secret openmetadata-fernetkey-secret -o jsonpath='{.data}' 2>/dev/null \
    | python3 -c 'import json,sys,base64;d=json.load(sys.stdin);print(next(iter(base64.b64decode(v).decode() for v in d.values())))' 2>/dev/null || true)
  ENCRYPTED=$(kubectl -n uwv-data exec postgres-postgresql-0 -c postgresql -- \
    env PGPASSWORD="$(kubectl -n uwv-data get secret postgres-postgresql -o jsonpath='{.data.password}' | base64 -d)" \
    psql -U postgres -d openmetadata -t -A -c \
    "SELECT json->'authenticationMechanism'->'config'->>'JWTToken' FROM user_entity WHERE name='ingestion-bot' LIMIT 1;" \
    2>/dev/null | sed 's/^fernet://' || true)
  JWT=""
  if [[ -n "$FERNET" && -n "$ENCRYPTED" ]]; then
    JWT=$(python3 -c "
from cryptography.fernet import MultiFernet, Fernet
mf = MultiFernet([Fernet(k.encode()) for k in '${FERNET}'.split(',')])
print(mf.decrypt(b'${ENCRYPTED}').decode())
" 2>/dev/null || true)
  fi
  if [[ -n "$JWT" ]]; then
    JWT_B64=$(printf '%s' "$JWT" | base64 | tr -d '\n')
    kubectl -n uwv-meta patch secret openmetadata-admin --type='json' \
      -p="[{\"op\":\"replace\",\"path\":\"/data/jwtToken\",\"value\":\"${JWT_B64}\"}]" >/dev/null 2>&1 || true
    kubectl -n uwv-platform create secret generic openmetadata-admin \
      --from-literal=jwtToken="$JWT" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n uwv-meta delete job openmetadata-init --ignore-not-found >/dev/null 2>&1 || true
    kubectl apply -k "$ROOT/platform/13-openmetadata-config" >/dev/null 2>&1 || true
    printf '\033[1;32mOK\033[0m OpenMetadata admin-JWT geseed + init-Job opnieuw getriggerd\n'
  else
    printf '\033[1;33m!!\033[0m JWT-decrypt faalde (OM nog niet klaar?) — re-run deploy-platform later\n'
  fi
else
  printf '\033[1;33m!!\033[0m OpenMetadata deployment niet Ready binnen 5m — JWT-seed overgeslagen\n'
fi

log "dbt-manifest ConfigMap renderen via uwv/dbt-trino:1.9.0-uwv"
if docker image inspect uwv/dbt-trino:1.9.0-uwv >/dev/null 2>&1; then
  TMP=$(mktemp -d)
  docker run --rm -v "$TMP:/out" --entrypoint sh uwv/dbt-trino:1.9.0-uwv -c '
    cd /opt/uwv/dbt
    cp profiles.yml.template profiles.yml 2>/dev/null || true
    DBT_PROFILES_DIR=/opt/uwv/dbt \
    TRINO_HOST=placeholder TRINO_PORT=8443 \
    TRINO_USER=placeholder TRINO_PASSWORD=placeholder \
    TABLE_FORMAT=delta \
    dbt parse --target dev >/tmp/dbt.log 2>&1 || cat /tmp/dbt.log >&2
    cp target/manifest.json /out/manifest.json 2>/dev/null || true
    # NB: --exclude pattern moet `./<naam>` zijn (niet kale `<naam>`) en
    # vóór de bron staan. .venv (~107MB) sluipt anders mee uit nieuwere
    # dbt-images en blaast de tarball over de 3MB etcd-record-limiet.
    tar -czf /out/dbt-project.tar.gz \
      --exclude=./target --exclude=./logs --exclude=./dbt_packages \
      --exclude=./.venv --exclude=./.user.yml --exclude=./.dockerignore \
      . 2>/dev/null
  ' 2>&1 | tail -3 || true
  if [[ -s "$TMP/manifest.json" ]]; then
    gzip -f -c "$TMP/manifest.json" > "$TMP/manifest.json.gz"
    kubectl -n uwv-platform create configmap dbt-manifest \
      --from-file=manifest.json.gz="$TMP/manifest.json.gz" \
      --from-file=dbt-project.tar.gz="$TMP/dbt-project.tar.gz" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    # Forceer Airflow scheduler-rollout zodat manifest-decompress init opnieuw runt.
    kubectl -n uwv-platform delete pod -l app.kubernetes.io/component=scheduler --ignore-not-found >/dev/null 2>&1 || true
    printf '\033[1;32mOK\033[0m dbt-manifest ConfigMap geseed (manifest.json.gz=%s, dbt-project.tar.gz=%s)\n' \
      "$(du -h "$TMP/manifest.json.gz" | cut -f1)" "$(du -h "$TMP/dbt-project.tar.gz" | cut -f1)"
  else
    printf '\033[1;33m!!\033[0m dbt parse leverde geen manifest.json op — Cosmos draait in fallback (lege DAG-set)\n'
  fi
  rm -rf "$TMP"
else
  printf '\033[1;33m!!\033[0m uwv/dbt-trino:1.9.0-uwv image niet gevonden — `make dbt-image` eerst draaien\n'
fi

log "Deploy-platform fase 1 stub klaar."
echo "Run wordt pas zinvol vanaf fase 2. Zie WORKLOG.md."
