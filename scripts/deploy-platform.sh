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

log "Deploy-platform fase 1 stub klaar."
echo "Run wordt pas zinvol vanaf fase 2. Zie WORKLOG.md."
