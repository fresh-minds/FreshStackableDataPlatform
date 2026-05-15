#!/usr/bin/env bash
# Idempotent setup van de om-access-bridge Keycloak-client + service-account
# roles. Gebruikt port-forward + admin-API; geen Keycloak-restart nodig.
#
# Achtergrond: Keycloak's realm-import draait met strategy IGNORE_EXISTING op
# subsequent boots. Nieuwe clients die we toevoegen aan realm-uwv.json komen
# pas in een gereset-cluster mee — niet bij re-applies. Dit script dicht
# dat gat consistent dichter bij de make-target.
#
# Idempotent: bestaande client + bestaande role-assignments → exit 0 zonder
# wijzigingen.

set -euo pipefail

NS="${KC_NS:-uwv-auth}"
KC_ADMIN_USER="${KC_ADMIN_USER:-kcadmin}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-uwv-dev-only-CHANGE-ME-2026}"
CLIENT_ID="om-access-bridge"
CLIENT_SECRET="${OM_BRIDGE_KC_SECRET:-uwv-dev-only-CHANGE-ME-om-access-bridge-secret}"
PF_PORT="${PF_PORT:-18080}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
pass() { printf '\033[1;32mOK\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

PF_PID=
cleanup() { [ -n "$PF_PID" ] && kill $PF_PID 2>/dev/null || true; }
trap cleanup EXIT

log "Port-forward keycloak → 127.0.0.1:${PF_PORT}"
kubectl -n "$NS" port-forward svc/keycloak ${PF_PORT}:80 >/tmp/kc-pf.log 2>&1 &
PF_PID=$!
for i in 1 2 3 4 5 6 7 8 9 10; do
  curl -fsS --max-time 2 "http://127.0.0.1:${PF_PORT}/realms/master" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS --max-time 5 "http://127.0.0.1:${PF_PORT}/realms/master" >/dev/null 2>&1 \
  || fail "port-forward niet bereikbaar — check kubelet health: $(tail -3 /tmp/kc-pf.log)"

log "Admin-login als ${KC_ADMIN_USER}"
T=$(curl -fsS -d "client_id=admin-cli" -d "username=${KC_ADMIN_USER}" -d "password=${KC_ADMIN_PASSWORD}" -d "grant_type=password" \
  "http://127.0.0.1:${PF_PORT}/realms/master/protocol/openid-connect/token" | sed 's/.*access_token":"\([^"]*\)".*/\1/')
[ -n "$T" ] || fail "admin-token lookup faalde"
A="Authorization: Bearer $T"
KC="http://127.0.0.1:${PF_PORT}"

log "Client ${CLIENT_ID} aanwezig?"
CLIENT_UUID=$(curl -fsS -H "$A" "$KC/admin/realms/uwv/clients?clientId=${CLIENT_ID}" | grep -oE '"id":"[^"]+"' | head -1 | cut -d'"' -f4)
if [ -z "$CLIENT_UUID" ]; then
  log "  client ontbreekt — POST /admin/realms/uwv/clients"
  STATUS=$(curl -sS -o /tmp/c.json -w '%{http_code}' -X POST -H "$A" -H 'Content-Type: application/json' \
    "$KC/admin/realms/uwv/clients" -d "{
      \"clientId\":\"${CLIENT_ID}\",
      \"name\":\"OpenMetadata Access Bridge (service account)\",
      \"description\":\"Service-account voor de om-access-bridge; kent realm-roles data_access:<catalog>.<schema> toe na approval in OpenMetadata. Zie ADR-0008.\",
      \"enabled\":true,
      \"protocol\":\"openid-connect\",
      \"publicClient\":false,
      \"secret\":\"${CLIENT_SECRET}\",
      \"standardFlowEnabled\":false,
      \"directAccessGrantsEnabled\":false,
      \"serviceAccountsEnabled\":true,
      \"redirectUris\":[],
      \"webOrigins\":[],
      \"defaultClientScopes\":[\"profile\",\"roles\"],
      \"fullScopeAllowed\":false,
      \"attributes\":{\"use.refresh.tokens\":\"false\"}
    }")
  [ "$STATUS" = "201" ] || fail "client POST=$STATUS body=$(cat /tmp/c.json)"
  CLIENT_UUID=$(curl -fsS -H "$A" "$KC/admin/realms/uwv/clients?clientId=${CLIENT_ID}" | grep -oE '"id":"[^"]+"' | head -1 | cut -d'"' -f4)
  pass "client aangemaakt (uuid=$CLIENT_UUID)"
else
  pass "client al aanwezig (uuid=$CLIENT_UUID)"
fi

SA_USER_ID=$(curl -fsS -H "$A" "$KC/admin/realms/uwv/clients/$CLIENT_UUID/service-account-user" | grep -oE '"id":"[^"]+"' | head -1 | cut -d'"' -f4)
[ -n "$SA_USER_ID" ] || fail "service-account user-id niet gevonden"

RM_UUID=$(curl -fsS -H "$A" "$KC/admin/realms/uwv/clients?clientId=realm-management" | grep -oE '"id":"[^"]+"' | head -1 | cut -d'"' -f4)
[ -n "$RM_UUID" ] || fail "realm-management client niet gevonden"

HAVE=$(curl -fsS -H "$A" "$KC/admin/realms/uwv/users/$SA_USER_ID/role-mappings/clients/$RM_UUID" | grep -oE '"name":"[^"]+"' | tr -d '"' | tr '\n' ' ')

log "Service-account roles diff'en met {manage-users, view-users, view-realm}"
NEED=0
ROLES_JSON='['
SEP=''
for r in manage-users view-users view-realm; do
  echo "$HAVE" | grep -q "name:$r" && continue
  RID=$(curl -fsS -H "$A" "$KC/admin/realms/uwv/clients/$RM_UUID/roles/$r" | grep -oE '"id":"[^"]+"' | head -1 | cut -d'"' -f4)
  [ -n "$RID" ] || { log "  warn: role $r niet vindbaar in realm-management"; continue; }
  ROLES_JSON="${ROLES_JSON}${SEP}{\"id\":\"$RID\",\"name\":\"$r\",\"containerId\":\"$RM_UUID\",\"clientRole\":true}"
  SEP=','
  NEED=$((NEED+1))
done
ROLES_JSON="${ROLES_JSON}]"

if [ "$NEED" -gt 0 ]; then
  STATUS=$(curl -sS -o /tmp/r.json -w '%{http_code}' -X POST -H "$A" -H 'Content-Type: application/json' \
    "$KC/admin/realms/uwv/users/$SA_USER_ID/role-mappings/clients/$RM_UUID" -d "$ROLES_JSON")
  [ "$STATUS" = "204" ] || fail "role-assign HTTP=$STATUS body=$(cat /tmp/r.json)"
  pass "$NEED role(s) toegekend aan service-account"
else
  pass "alle 3 service-account roles al toegekend"
fi
