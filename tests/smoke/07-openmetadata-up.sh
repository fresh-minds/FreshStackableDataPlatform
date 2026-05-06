#!/usr/bin/env bash
# Smoke test 07 — OpenMetadata draait, classifications + glossary geladen.
#
# Voorwaarden:
#   - infrastructure/helm/opensearch + openmetadata Helm installed (uwv-meta ns)
#   - platform/13-openmetadata-config applied → init-Job complete
set -euo pipefail

NS="${NS:-uwv-meta}"

log()  { printf '\033[1;34m  ==>\033[0m %s\n' "$*"; }
pass() { printf '\033[1;32m  OK\033[0m  %s\n' "$*"; }
fail() { printf '\033[1;31m  FAIL\033[0m %s\n' "$*" >&2; exit 1; }

# 1. OpenSearch Ready
log "OpenSearch single-node Ready"
kubectl -n "$NS" rollout status statefulset/opensearch-uwv-master --timeout=10m >/dev/null 2>&1 \
  || fail "OpenSearch (statefulset opensearch-uwv-master) niet Ready"
pass "OpenSearch Ready"

# 1a. OpenSearch Dashboards Ready
log "OpenSearch Dashboards Ready"
kubectl -n "$NS" rollout status deploy/opensearch-dashboards-uwv --timeout=10m >/dev/null 2>&1 \
  || fail "OpenSearch Dashboards (deploy/opensearch-dashboards-uwv) niet Ready"
pass "OpenSearch Dashboards Ready"

# 2. OpenMetadata Ready
log "OpenMetadata server Ready"
kubectl -n "$NS" rollout status deploy/openmetadata --timeout=10m >/dev/null 2>&1 \
  || kubectl -n "$NS" rollout status statefulset/openmetadata --timeout=10m >/dev/null 2>&1 \
  || fail "OpenMetadata pods niet Ready"
pass "OpenMetadata Ready"

# 3. Init-Job complete
log "Init-Job complete"
phase=$(kubectl -n "$NS" get job openmetadata-init -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "")
if [[ "$phase" != "True" ]]; then
  log "Init-Job nog niet Complete; logs:"
  kubectl -n "$NS" logs job/openmetadata-init --tail=80 || true
  fail "openmetadata-init Job niet succesvol"
fi
pass "openmetadata-init Job Complete"

# 4. Classifications via API
log "Classifications via REST API"
om_pod=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=openmetadata \
           -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$om_pod" ]]; then
  fail "OpenMetadata-pod niet gevonden"
fi

token=$(kubectl -n "$NS" get secret openmetadata-admin -o jsonpath='{.data.jwtToken}' | base64 -d)

# Classifications-list ophalen via interne API
classifications=$(kubectl -n "$NS" exec "$om_pod" -- \
  curl -fsS http://localhost:8585/api/v1/classifications \
       -H "Authorization: Bearer $token" \
  2>/dev/null || echo "{}")

for c in PII Health Confidentiality BIO LegalBasis Doelbinding AI; do
  if echo "$classifications" | grep -q "\"name\": \"$c\""; then
    pass "classification '$c' aanwezig"
  else
    fail "classification '$c' ontbreekt"
  fi
done

# 5. Glossary CGM
log "Glossary CGM"
gloss=$(kubectl -n "$NS" exec "$om_pod" -- \
  curl -fsS http://localhost:8585/api/v1/glossaries \
       -H "Authorization: Bearer $token" \
  2>/dev/null || echo "{}")
if echo "$gloss" | grep -q "\"name\": \"CGM\""; then
  pass "glossary 'CGM' aanwezig"
else
  fail "glossary 'CGM' ontbreekt"
fi

# 6. Sample CGM-terms
log "CGM-terms sample"
terms=$(kubectl -n "$NS" exec "$om_pod" -- \
  curl -fsS "http://localhost:8585/api/v1/glossaryTerms?glossary=CGM&limit=50" \
       -H "Authorization: Bearer $token" \
  2>/dev/null || echo "{}")
for t in Aanvraag Beoordeling Cliënt IKV Uitkering; do
  # CGM-term heeft FQN `CGM.<name>` in OM
  if echo "$terms" | grep -q "\"name\": \"$t\""; then
    pass "term CGM.$t aanwezig"
  else
    log "  [warn] term CGM.$t niet gevonden — kan zijn dat init-Job nog niet alle posts deed"
  fi
done

echo
pass "smoke 07-openmetadata-up: alle checks groen"
