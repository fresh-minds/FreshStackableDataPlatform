#!/usr/bin/env bash
# Deploy platform manifests on the AKS cluster.
# Thin wrapper around scripts/deploy-platform.sh with AKS-specific post-steps:
#  - CoreDNS hosts-override (`coredns-custom` ConfigMap) zodat
#    keycloak.uwv-platform.local in-cluster routeert naar de keycloak-external
#    Service in ingress-nginx (zie platform/02-authentication/keycloak-external-svc.yaml).
#  - MinIO restart zodat de OIDC-discovery slaagt na de DNS-fix (Console toont
#    anders geen Keycloak SSO knop).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

log()   { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
error() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

ctx="$(kubectl config current-context 2>/dev/null || true)"
case "$ctx" in
  uwv-platform-aks|*aks*) ;;
  *) error "kubectl context is '$ctx', not the AKS cluster. Run: make aks-context" ;;
esac
log "kubectl context: $ctx"

bash "$ROOT/scripts/deploy-platform.sh"

# ---- AKS-only post-deploy: CoreDNS hosts-override ----
# AKS CoreDNS gebruikt een 'coredns-custom' ConfigMap met *.override files
# die geïmporteerd worden via `import custom/*.override` in de hoofd-Corefile.
# We pinnen `keycloak.uwv-platform.local` op de ClusterIP van de
# keycloak-external Service (zie platform/02-authentication/keycloak-external-svc.yaml).
log "AKS-post: CoreDNS hosts-override voor keycloak.uwv-platform.local"
KCEXT_IP=""
for i in $(seq 1 30); do
  KCEXT_IP=$(kubectl -n ingress-nginx get svc keycloak-external -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  [[ -n "$KCEXT_IP" && "$KCEXT_IP" != "None" ]] && break
  sleep 2
done
if [[ -z "$KCEXT_IP" || "$KCEXT_IP" == "None" ]]; then
  warn "keycloak-external Service nog niet beschikbaar; sla CoreDNS-patch over"
else
  log "  keycloak-external ClusterIP: $KCEXT_IP"
  kubectl -n kube-system create configmap coredns-custom \
    --from-literal=keycloak.override="hosts {
    $KCEXT_IP keycloak.uwv-platform.local
    fallthrough
}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n kube-system rollout restart deploy coredns >/dev/null
  kubectl -n kube-system rollout status deploy coredns --timeout=60s >/dev/null || warn "CoreDNS rollout traag"
  log "  CoreDNS gepatched + herstart"
fi

# ---- Keycloak runtime patches (profile + email scopes, policy attribute) ----
# realm-uwv.json import skipt deze omdat het IGNORE_EXISTING strategy gebruikt
# en alleen scopes aanmaakt die expliciet in de JSON staan. Zonder deze patch
# faalt SSO met `invalid_scope: Invalid scopes: openid profile email roles`.
log "AKS-post: Keycloak realm patches (profile + email scopes, attach to clients)"
KCPOD=$(kubectl -n uwv-auth get pods -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "$KCPOD" ]]; then
  warn "Keycloak pod niet gevonden; sla realm-patches over"
else
  # Wacht tot Keycloak bereikbaar is
  TOKEN=""
  for i in $(seq 1 30); do
    TOKEN=$(kubectl -n uwv-auth exec "$KCPOD" -c keycloak -- curl -fsS \
      -d "client_id=admin-cli" -d "username=kcadmin" \
      -d "password=uwv-dev-only-CHANGE-ME-2026" -d "grant_type=password" \
      http://localhost:8080/realms/master/protocol/openid-connect/token 2>/dev/null \
      | sed 's/.*access_token":"\([^"]*\)".*/\1/' || true)
    [[ -n "$TOKEN" && "$TOKEN" != *"error"* ]] && break
    sleep 3
  done

  if [[ -z "$TOKEN" ]]; then
    warn "Keycloak admin-token niet verkregen; sla realm-patches over"
  else
    kubectl -n uwv-auth exec "$KCPOD" -c keycloak -- bash -c "
T=\$(curl -fsS -d 'client_id=admin-cli' -d 'username=kcadmin' -d 'password=uwv-dev-only-CHANGE-ME-2026' -d 'grant_type=password' http://localhost:8080/realms/master/protocol/openid-connect/token | sed 's/.*access_token\":\"\\([^\"]*\\)\".*/\\1/')
KC=http://localhost:8080
A='Authorization: Bearer '\"\$T\"

# 1. profile + email scopes aanmaken (idempotent; realm-import skipt deze)
curl -fsS -H \"\$A\" \"\$KC/admin/realms/uwv/client-scopes\" 2>/dev/null | grep -q '\"name\":\"profile\"' || \\
  curl -sS -X POST -H \"\$A\" -H 'Content-Type: application/json' \"\$KC/admin/realms/uwv/client-scopes\" -d '{\"name\":\"profile\",\"protocol\":\"openid-connect\",\"attributes\":{\"include.in.token.scope\":\"true\"},\"protocolMappers\":[{\"name\":\"username\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-usermodel-property-mapper\",\"config\":{\"user.attribute\":\"username\",\"claim.name\":\"preferred_username\",\"jsonType.label\":\"String\",\"id.token.claim\":\"true\",\"access.token.claim\":\"true\",\"userinfo.token.claim\":\"true\"}}]}' -o /dev/null

curl -fsS -H \"\$A\" \"\$KC/admin/realms/uwv/client-scopes\" 2>/dev/null | grep -q '\"name\":\"email\"' || \\
  curl -sS -X POST -H \"\$A\" -H 'Content-Type: application/json' \"\$KC/admin/realms/uwv/client-scopes\" -d '{\"name\":\"email\",\"protocol\":\"openid-connect\",\"attributes\":{\"include.in.token.scope\":\"true\"},\"protocolMappers\":[{\"name\":\"email\",\"protocol\":\"openid-connect\",\"protocolMapper\":\"oidc-usermodel-property-mapper\",\"config\":{\"user.attribute\":\"email\",\"claim.name\":\"email\",\"jsonType.label\":\"String\",\"id.token.claim\":\"true\",\"access.token.claim\":\"true\",\"userinfo.token.claim\":\"true\"}}]}' -o /dev/null

# 2. scopes assignen aan alle OIDC-clients (idempotent — PUT geeft 204 ook bij re-assign)
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

# 2b. Lange access-tokens + geen-refresh voor de openmetadata client.
# Pac4j (OM 1.5) probeert id_token te refreshen; bij Keycloak-pod-restart
# zijn in-memory sessies weg en faalt de refresh met 'Session not active'.
# Met use.refresh.tokens=false gaat OM bij token-expiry naar Keycloak's
# SSO-cookie ipv refresh-token, en met access.token.lifespan=86400 hoeft
# dat ook niet binnen een werkdag.
OM_CID=\$(curl -fsS -H \"\$A\" \"\$KC/admin/realms/uwv/clients?clientId=openmetadata\" 2>/dev/null | grep -oE '\"id\":\"[^\"]*\"' | head -1 | cut -d'\"' -f4)
if [ -n \"\$OM_CID\" ]; then
  curl -sS -X PUT -H \"\$A\" -H 'Content-Type: application/json' \"\$KC/admin/realms/uwv/clients/\$OM_CID\" -d '{\"attributes\":{\"access.token.lifespan\":\"86400\",\"client.session.max.lifespan\":\"86400\",\"client.session.idle.timeout\":\"28800\",\"use.refresh.tokens\":\"false\"}}' -o /dev/null
fi

# 3. Unmanaged attribute policy enablen — Keycloak 24+ heeft Declarative
#    User Profile met unmanaged-attributes standaard UIT. Zonder deze
#    setting wordt de \\\"policy\\\" custom attribute silently genegeerd
#    (PUT geeft 204 maar er wordt niets opgeslagen).
PROFILE_CFG=\$(curl -fsS -H \"\$A\" \"\$KC/admin/realms/uwv/users/profile\" 2>/dev/null)
if ! echo \"\$PROFILE_CFG\" | grep -q '\"unmanagedAttributePolicy\":\"ADMIN_EDIT\"'; then
  echo \"\$PROFILE_CFG\" | sed -e 's/}\$/,\"unmanagedAttributePolicy\":\"ADMIN_EDIT\"}/' > /tmp/up.json
  curl -sS -X PUT -H \"\$A\" -H 'Content-Type: application/json' \"\$KC/admin/realms/uwv/users/profile\" --data @/tmp/up.json -o /dev/null
fi

# 4. policy attribute voor MinIO consoleAdmin op demo-admins. NB: PUT
#    moet email + enabled MEEsturen — partial body wist andere velden.
for u in wia.beoordelaar platform.admin; do
  KCUID=\$(curl -fsS -H \"\$A\" \"\$KC/admin/realms/uwv/users?username=\$u\" 2>/dev/null | grep -oE '\"id\":\"[^\"]*\"' | head -1 | cut -d'\"' -f4)
  [ -z \"\$KCUID\" ] && continue
  curl -sS -X PUT -H \"\$A\" -H 'Content-Type: application/json' \"\$KC/admin/realms/uwv/users/\$KCUID\" \\
    -d \"{\\\"username\\\":\\\"\$u\\\",\\\"email\\\":\\\"\$u@uwv-platform.local\\\",\\\"emailVerified\\\":true,\\\"enabled\\\":true,\\\"attributes\\\":{\\\"policy\\\":[\\\"consoleAdmin\\\"]}}\" -o /dev/null
done

# 5. TOTP-requirement clearen voor demo-admins zodat eerste login simpel is
for u in platform.admin wajong.arbeidsdeskundige data.engineer; do
  KCUID=\$(curl -fsS -H \"\$A\" \"\$KC/admin/realms/uwv/users?username=\$u\" 2>/dev/null | grep -oE '\"id\":\"[^\"]*\"' | head -1 | cut -d'\"' -f4)
  [ -z \"\$KCUID\" ] && continue
  curl -sS -X PUT -H \"\$A\" -H 'Content-Type: application/json' \"\$KC/admin/realms/uwv/users/\$KCUID\" -d \"{\\\"username\\\":\\\"\$u\\\",\\\"email\\\":\\\"\$u@uwv-platform.local\\\",\\\"emailVerified\\\":true,\\\"enabled\\\":true,\\\"requiredActions\\\":[]}\" -o /dev/null
  curl -sS -X DELETE -H \"\$A\" \"\$KC/admin/realms/uwv/attack-detection/brute-force/users/\$KCUID\" -o /dev/null
done
" >/dev/null 2>&1
    log "  Keycloak realm-patches toegepast"
  fi
fi

# ---- MinIO restart zodat OIDC-discovery slaagt ----
# MinIO doet OIDC discovery alleen bij startup. Als de pod al bestond vóór
# de DNS-fix klaar was, faalt OIDC en is er geen Keycloak-knop in Console.
if kubectl -n uwv-platform get deployment minio >/dev/null 2>&1; then
  log "AKS-post: MinIO herstart (OIDC discovery na DNS-fix)"
  kubectl -n uwv-platform rollout restart deployment minio >/dev/null
  kubectl -n uwv-platform rollout status deployment minio --timeout=120s >/dev/null \
    || warn "MinIO rollout traag"
fi

log "AKS deploy klaar."
