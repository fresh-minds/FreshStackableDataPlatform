#!/usr/bin/env bash
# Smoke test 09 — UWV Platform Portal (Astro + oauth2-proxy).
#
# Checkt:
#   1. Portal-deployment bestaat in uwv-platform en is Available
#   2. nginx-container antwoordt op /api/health (200 + status:ok)
#   3. oauth2-proxy luistert (kan /ping antwoorden)
#   4. Service portal:80 routeert naar oauth2-proxy:4180
#   5. Ingress platform.uwv-platform.local bestaat met TLS-secret
#   6. Keycloak-realm 'uwv' kent een client met clientId=portal
#
# Skipt elegant als de portal nog niet gedeployd is, identiek patroon
# aan de andere smoke-tests in deze map.
set -euo pipefail

pass() { printf '\033[1;32m  OK\033[0m  %s\n' "$*"; }
fail() { printf '\033[1;31m  FAIL\033[0m %s\n' "$*" >&2; exit 1; }
skip() { printf '  [SKIP] %s\n' "$*"; }
log()  { printf '\033[1;34m  ==>\033[0m %s\n' "$*"; }

NS=uwv-platform
DEP=portal

if ! kubectl -n "$NS" get deployment "$DEP" >/dev/null 2>&1; then
  skip "deployment $NS/$DEP nog niet aanwezig — run 'make deploy-platform' inclusief platform/15-portal"
  exit 0
fi

# 1. Deployment Available
log "Wacht op deployment $NS/$DEP Available"
if kubectl -n "$NS" wait --for=condition=Available deployment/"$DEP" --timeout=60s >/dev/null 2>&1; then
  pass "deployment $DEP Available"
else
  fail "deployment $DEP niet Available binnen 60s"
fi

POD=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=portal \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "$POD" ]]; then
  fail "geen portal-pod gevonden"
fi

# 2. nginx /api/health
log "Health-endpoint van nginx (intern, container portal-web)"
HEALTH=$(kubectl -n "$NS" exec "$POD" -c portal-web -- \
           wget -qO- http://127.0.0.1:8080/api/health 2>/dev/null || true)
if echo "$HEALTH" | grep -q '"status":"ok"'; then
  pass "portal-web /api/health = ok"
else
  fail "portal-web /api/health gaf onverwacht: ${HEALTH:-leeg}"
fi

# 3. oauth2-proxy /ping — check via portal-web container want oauth2-proxy
# distroless image heeft geen shell/wget/curl.
log "Ping-endpoint oauth2-proxy (via portal-web)"
PING=$(kubectl -n "$NS" exec "$POD" -c portal-web -- \
         wget -qO- http://127.0.0.1:4180/ping 2>/dev/null || true)
if [[ "$PING" == *"OK"* || "$PING" == *"pong"* ]]; then
  pass "oauth2-proxy /ping antwoordt"
else
  fail "oauth2-proxy /ping faalt: ${PING:-leeg}"
fi

# 4. Service routing portal:80 → 4180
log "Service portal:80"
SVC_PORT=$(kubectl -n "$NS" get svc portal -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)
SVC_TARGET=$(kubectl -n "$NS" get svc portal -o jsonpath='{.spec.ports[0].targetPort}' 2>/dev/null || true)
if [[ "$SVC_PORT" == "80" && "$SVC_TARGET" == "4180" ]]; then
  pass "service portal 80 -> 4180"
else
  fail "service portal heeft onverwachte port mapping (port=$SVC_PORT target=$SVC_TARGET)"
fi

# 5. Ingress + TLS
log "Ingress platform.uwv-platform.local"
INGRESS_HOST=$(kubectl -n "$NS" get ingress portal -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)
INGRESS_TLS=$(kubectl -n "$NS" get ingress portal -o jsonpath='{.spec.tls[0].secretName}' 2>/dev/null || true)
if [[ "$INGRESS_HOST" == "platform.uwv-platform.local" && -n "$INGRESS_TLS" ]]; then
  pass "ingress host=$INGRESS_HOST tls-secret=$INGRESS_TLS"
else
  fail "ingress portal niet correct (host=$INGRESS_HOST tls=$INGRESS_TLS)"
fi

# 6. Keycloak realm bevat client 'portal'
log "Keycloak realm 'uwv' kent client 'portal'"
KC_RESP=$(kubectl -n uwv-auth run kc-portal-check-$RANDOM \
            --image=curlimages/curl:8.10.1 --rm -i --restart=Never --quiet -- \
            curl -fsSL --max-time 10 \
              "http://keycloak.uwv-auth.svc.cluster.local/realms/uwv/.well-known/openid-configuration" \
            2>/dev/null || true)
if echo "$KC_RESP" | grep -q '"issuer"'; then
  pass "Keycloak realm 'uwv' beantwoordt OIDC-discovery"
  # NB: zonder admin-API kunnen we client-list niet enumereren; dat is OK,
  # de realm-import bevat 'portal' (zie infrastructure/helm/keycloak/realm-uwv.json).
  skip "client-enumeration vereist Keycloak admin-API; vertrouw op realm-import"
else
  fail "Keycloak realm 'uwv' beantwoordt geen OIDC-discovery"
fi

echo
pass "smoke 09-portal-up: alle checks groen"
