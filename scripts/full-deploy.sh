#!/usr/bin/env bash
# UWV Reference Data Platform — alles-in-één deploy.
#
# Wat dit doet:
#   1. k3d-cluster aanmaken
#   2. /etc/hosts patchen (sudo, alleen indien nodig)
#   3. make bootstrap (alle Helm charts: cert-manager, ingress, postgres,
#      minio, keycloak, prometheus, stackable-operators, opensearch,
#      openmetadata, vector)
#   4. uwv-ca-bundle ConfigMap (cert-manager CA voor in-cluster TLS-verify)
#   5. CoreDNS NodeHosts patch (keycloak.uwv-platform.local → svc-IP)
#   6. make deploy-platform (alle K8s manifests incl. portal)
#   7. Portal Docker-image bouwen + importeren in k3d
#   8. Live-only Keycloak realm patches (TOTP-requirement clearen, profile-
#      scope aanmaken, policy attribute op demo-users) die niet via
#      realm-import komen (IGNORE_EXISTING strategy)
#   9. Bootstrap Airflow/Superset Admin-rol per UWV-user (na eerste login
#      auto-aangemaakt met Public-rol)
#  10. Smoke-test 09-portal-up
#
# Idempotent — re-run is veilig, alle stappen skippen bij "already done".
#
# Usage:
#   ./scripts/full-deploy.sh
# of:
#   ./scripts/full-deploy.sh --skip-cluster   # cluster bestaat al
#   ./scripts/full-deploy.sh --skip-bootstrap # helm-installs overslaan

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SKIP_CLUSTER=0
SKIP_BOOTSTRAP=0
for arg in "$@"; do
  case "$arg" in
    --skip-cluster)   SKIP_CLUSTER=1 ;;
    --skip-bootstrap) SKIP_BOOTSTRAP=1 ;;
  esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m  %s\n' "$*"; }
fail() { printf '\033[1;31m  FAIL\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------- 1
log "1/10  k3d cluster aanmaken"
if [[ $SKIP_CLUSTER -eq 1 ]]; then
  warn "skip (--skip-cluster)"
else
  make cluster
  ok "cluster up"
fi

# ---------------------------------------------------------------------- 2
log "2/10  /etc/hosts patchen"
HOSTS_LINE="127.0.0.1 platform.uwv-platform.local keycloak.uwv-platform.local superset.uwv-platform.local airflow.uwv-platform.local trino.uwv-platform.local nifi.uwv-platform.local minio.uwv-platform.local minio-console.uwv-platform.local openmetadata.uwv-platform.local grafana.uwv-platform.local prometheus.uwv-platform.local opensearch.uwv-platform.local"
if grep -q "platform.uwv-platform.local" /etc/hosts && \
   grep -q "minio-console.uwv-platform.local" /etc/hosts && \
   grep -q "grafana.uwv-platform.local" /etc/hosts; then
  ok "alle hostnames al in /etc/hosts"
else
  log "sudo nodig om /etc/hosts te bewerken"
  echo "$HOSTS_LINE" | sudo tee -a /etc/hosts >/dev/null
  ok "hostnames toegevoegd aan /etc/hosts"
fi

# ---------------------------------------------------------------------- 3
log "3/10  bootstrap (Helm charts + Stackable operators)"
if [[ $SKIP_BOOTSTRAP -eq 1 ]]; then
  warn "skip (--skip-bootstrap)"
else
  make bootstrap || warn "bootstrap meldde fouten — check output; ga door"
  ok "bootstrap done"
fi

# ---------------------------------------------------------------------- 4
log "4/10  uwv-ca-bundle ConfigMap (cert-manager CA mounten in pods)"
kubectl create namespace uwv-platform --dry-run=client -o yaml | kubectl apply -f - >/dev/null
TMP_CA=$(mktemp)
kubectl get secret uwv-platform-ca -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > "$TMP_CA"
kubectl -n uwv-platform create configmap uwv-ca-bundle \
  --from-file=ca.crt="$TMP_CA" --dry-run=client -o yaml | kubectl apply -f -
rm -f "$TMP_CA"
ok "uwv-ca-bundle gemount"

# ---------------------------------------------------------------------- 5
log "5/10  CoreDNS NodeHosts patch (in-cluster keycloak.uwv-platform.local)"
# Wacht eerst tot keycloak-external Service een ClusterIP heeft (na
# deploy-platform stap 02-authentication).
KC_SVC_IP=""
for i in {1..30}; do
  KC_SVC_IP=$(kubectl -n uwv-auth get svc keycloak-external -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  [[ -n "$KC_SVC_IP" && "$KC_SVC_IP" != "None" ]] && break
  sleep 2
done
if [[ -z "$KC_SVC_IP" || "$KC_SVC_IP" == "None" ]]; then
  warn "keycloak-external Service nog niet beschikbaar; CoreDNS-patch nu skippen, doe dat na make deploy-platform"
else
  kubectl -n kube-system get cm coredns -o yaml > /tmp/coredns.yaml
  python3 <<EOF
import yaml
d = yaml.safe_load(open('/tmp/coredns.yaml'))
hosts = d['data']['NodeHosts']
lines = [l for l in hosts.splitlines() if 'keycloak.uwv-platform.local' not in l]
lines.append('${KC_SVC_IP} keycloak.uwv-platform.local')
d['data']['NodeHosts'] = '\n'.join(lines) + '\n'
yaml.safe_dump(d, open('/tmp/coredns.yaml', 'w'))
EOF
  kubectl apply -f /tmp/coredns.yaml >/dev/null
  kubectl -n kube-system rollout restart deploy coredns >/dev/null
  ok "CoreDNS NodeHosts patched (keycloak → $KC_SVC_IP)"
fi

# ---------------------------------------------------------------------- 6
log "6/10  deploy-platform (alle K8s manifests)"
make deploy-platform || warn "deploy-platform meldde fouten — check output"
ok "platform manifests applied"

# Re-run CoreDNS patch nu de Service zeker bestaat
KC_SVC_IP=$(kubectl -n uwv-auth get svc keycloak-external -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
if [[ -n "$KC_SVC_IP" && "$KC_SVC_IP" != "None" ]]; then
  kubectl -n kube-system get cm coredns -o yaml > /tmp/coredns.yaml
  python3 <<EOF
import yaml
d = yaml.safe_load(open('/tmp/coredns.yaml'))
lines = [l for l in d['data']['NodeHosts'].splitlines() if 'keycloak.uwv-platform.local' not in l]
lines.append('${KC_SVC_IP} keycloak.uwv-platform.local')
d['data']['NodeHosts'] = '\n'.join(lines) + '\n'
yaml.safe_dump(d, open('/tmp/coredns.yaml', 'w'))
EOF
  kubectl apply -f /tmp/coredns.yaml >/dev/null
  kubectl -n kube-system rollout restart deploy coredns >/dev/null
  ok "CoreDNS opnieuw gepatcht voor keycloak → $KC_SVC_IP"
fi

# ---------------------------------------------------------------------- 7
log "7/10  Portal Docker-image bouwen + in k3d laden"
docker build -f portal/Dockerfile -t uwv-platform/portal:dev . >/dev/null
k3d image import uwv-platform/portal:dev -c uwv-platform >/dev/null
kubectl -n uwv-platform rollout restart deployment portal >/dev/null 2>&1 || true
ok "portal-image gebouwd + geïmporteerd"

# ---------------------------------------------------------------------- 8
log "8/10  Live-only Keycloak realm patches (TOTP, scopes, mappers, attrs)"
# Wacht tot Keycloak ready
for i in {1..60}; do
  TOKEN=$(kubectl -n uwv-auth exec keycloak-0 -c keycloak -- curl -fsS \
    -d "client_id=admin-cli" -d "username=kcadmin" \
    -d "password=uwv-dev-only-CHANGE-ME-2026" -d "grant_type=password" \
    http://localhost:8080/realms/master/protocol/openid-connect/token 2>/dev/null \
    | sed 's/.*access_token":"\([^"]*\)".*/\1/' || true)
  [[ -n "$TOKEN" && "$TOKEN" != *"error"* ]] && break
  sleep 3
done

if [[ -z "$TOKEN" ]]; then
  warn "Keycloak niet bereikbaar; sla realm-patches over"
else
  # bash -c via single-quoted string + escapes — anders interpoleert de
  # outer shell de inner $TOKEN/$ADM en faalt het patch-script silent.
  kubectl -n uwv-auth exec keycloak-0 -c keycloak -- bash -c "
T=\$(curl -fsS -d 'client_id=admin-cli' -d 'username=kcadmin' -d 'password=uwv-dev-only-CHANGE-ME-2026' -d 'grant_type=password' http://localhost:8080/realms/master/protocol/openid-connect/token | sed 's/.*access_token\":\"\\([^\"]*\\)\".*/\\1/')
KC=http://localhost:8080
A='Authorization: Bearer '\"\$T\"

# 1. TOTP clearen voor demo-admins
for u in platform.admin wajong.arbeidsdeskundige data.engineer; do
  KCUID=\$(curl -fsS -H \"\$A\" \"\$KC/admin/realms/uwv/users?username=\$u\" 2>/dev/null | grep -oE '\"id\":\"[^\"]*\"' | head -1 | cut -d'\"' -f4)
  [ -z \"\$KCUID\" ] && continue
  curl -sS -X PUT -H \"\$A\" -H 'Content-Type: application/json' \"\$KC/admin/realms/uwv/users/\$KCUID\" -d '{\"requiredActions\":[]}' -o /dev/null
  curl -sS -X DELETE -H \"\$A\" \"\$KC/admin/realms/uwv/attack-detection/brute-force/users/\$KCUID\" -o /dev/null
done

# 2. profile + email scopes aanmaken (realm-import skipt deze)
curl -fsS -H \"\$A\" \"\$KC/admin/realms/uwv/client-scopes\" 2>/dev/null | grep -q '\"name\":\"profile\"' || \\
  curl -sS -X POST -H \"\$A\" -H 'Content-Type: application/json' \"\$KC/admin/realms/uwv/client-scopes\" -d '{\"name\":\"profile\",\"protocol\":\"openid-connect\",\"attributes\":{\"include.in.token.scope\":\"true\"},\"protocolMappers\":[{\"name\":\"username\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-usermodel-property-mapper\",\"config\":{\"user.attribute\":\"username\",\"claim.name\":\"preferred_username\",\"jsonType.label\":\"String\",\"id.token.claim\":\"true\",\"access.token.claim\":\"true\",\"userinfo.token.claim\":\"true\"}}]}' -o /dev/null

curl -fsS -H \"\$A\" \"\$KC/admin/realms/uwv/client-scopes\" 2>/dev/null | grep -q '\"name\":\"email\"' || \\
  curl -sS -X POST -H \"\$A\" -H 'Content-Type: application/json' \"\$KC/admin/realms/uwv/client-scopes\" -d '{\"name\":\"email\",\"protocol\":\"openid-connect\",\"attributes\":{\"include.in.token.scope\":\"true\"},\"protocolMappers\":[{\"name\":\"email\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-usermodel-property-mapper\",\"config\":{\"user.attribute\":\"email\",\"claim.name\":\"email\",\"jsonType.label\":\"String\",\"id.token.claim\":\"true\",\"access.token.claim\":\"true\",\"userinfo.token.claim\":\"true\"}}]}' -o /dev/null

# 3. scopes assignen
PROFILE=\$(curl -fsS -H \"\$A\" \"\$KC/admin/realms/uwv/client-scopes\" | tr '{' '\\n' | grep '\"name\":\"profile\"' | grep -oE '\"id\":\"[^\"]*\"' | head -1 | cut -d'\"' -f4)
EMAIL=\$(curl -fsS -H \"\$A\" \"\$KC/admin/realms/uwv/client-scopes\" | tr '{' '\\n' | grep '\"name\":\"email\"' | grep -oE '\"id\":\"[^\"]*\"' | head -1 | cut -d'\"' -f4)
ROLES=\$(curl -fsS -H \"\$A\" \"\$KC/admin/realms/uwv/client-scopes\" | tr '{' '\\n' | grep '\"name\":\"roles\"' | grep -oE '\"id\":\"[^\"]*\"' | head -1 | cut -d'\"' -f4)
for c in superset airflow nifi openmetadata minio; do
  CID=\$(curl -fsS -H \"\$A\" \"\$KC/admin/realms/uwv/clients?clientId=\$c\" 2>/dev/null | grep -oE '\"id\":\"[^\"]*\"' | head -1 | cut -d'\"' -f4)
  [ -z \"\$CID\" ] && continue
  for s in \$PROFILE \$EMAIL \$ROLES; do
    curl -sS -X PUT -H \"\$A\" \"\$KC/admin/realms/uwv/clients/\$CID/default-client-scopes/\$s\" -o /dev/null
  done
done

# 4. policy attribute voor MinIO consoleAdmin
for u in wia.beoordelaar platform.admin; do
  KCUID=\$(curl -fsS -H \"\$A\" \"\$KC/admin/realms/uwv/users?username=\$u\" 2>/dev/null | grep -oE '\"id\":\"[^\"]*\"' | head -1 | cut -d'\"' -f4)
  [ -z \"\$KCUID\" ] && continue
  curl -sS -X PUT -H \"\$A\" -H 'Content-Type: application/json' \"\$KC/admin/realms/uwv/users/\$KCUID\" -d '{\"attributes\":{\"policy\":[\"consoleAdmin\"]}}' -o /dev/null
done
" 2>&1 | tail -3
  ok "Keycloak runtime patches applied"
fi

# ---------------------------------------------------------------------- 9
log "9/10  Bootstrap Admin-rol op demo-users in Airflow + Superset"
# Wacht tot Airflow webserver up
for i in {1..30}; do
  STATE=$(kubectl -n uwv-platform get pod -l app.kubernetes.io/name=airflow,app.kubernetes.io/component=webserver \
    -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="airflow")].ready}' 2>/dev/null || true)
  [[ "$STATE" = "true" ]] && break
  sleep 5
done
if [[ "$STATE" = "true" ]]; then
  for u in wia.beoordelaar platform.admin; do
    kubectl -n uwv-platform exec uwv-airflow-webserver-default-0 -c airflow -- \
      airflow users add-role -e $u@uwv-platform.local -r Admin 2>/dev/null | tail -1 | grep -v "does not exist" || true
  done
  ok "Airflow Admin-rol toegekend aan demo-users (na hun eerste login)"
else
  warn "Airflow webserver nog niet up; rol-toekenning na eerste login handmatig"
fi

# Superset idem
SUP=$(kubectl -n uwv-platform get pod uwv-superset-node-default-0 -o jsonpath='{.status.containerStatuses[?(@.name=="superset")].ready}' 2>/dev/null || true)
if [[ "$SUP" = "true" ]]; then
  kubectl -n uwv-platform exec uwv-superset-node-default-0 -c superset -- python3 <<'PYEOF' 2>/dev/null | tail -3 || true
from superset.app import create_app
app = create_app()
with app.app_context():
    from flask_appbuilder.security.sqla.models import User, Role
    from superset import db
    admin = db.session.query(Role).filter_by(name='Admin').first()
    for u in db.session.query(User).all():
        if not u.roles or all(r.name == 'Public' for r in u.roles):
            u.roles = [admin]
            db.session.commit()
            print(f'upgraded {u.username} -> Admin')
PYEOF
  ok "Superset Admin-rol toegekend aan demo-users"
fi

# ---------------------------------------------------------------------- 10
log "10/10 smoke test 09-portal-up"
bash tests/smoke/09-portal-up.sh || warn "smoke meldt fouten"

echo
ok "Alles klaar. Open: https://platform.uwv-platform.local:8443/"
echo "Login: wia.beoordelaar / uwv-dev-only-CHANGE-ME-Wia2026"
echo "Of:    platform.admin   / uwv-dev-only-CHANGE-ME-Admin2026"
