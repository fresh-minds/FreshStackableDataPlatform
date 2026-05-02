#!/usr/bin/env bash
# Smoke test 06 — Superset draait, init-Job complete, Trino-database geregistreerd.
#
# Voorwaarden: fase 0+1+2+3+7 (en idealiter fase 5/6 voor dbt/airflow).
set -euo pipefail

NS="${NS:-uwv-platform}"

log()  { printf '\033[1;34m  ==>\033[0m %s\n' "$*"; }
pass() { printf '\033[1;32m  OK\033[0m  %s\n' "$*"; }
fail() { printf '\033[1;31m  FAIL\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Pods Ready
log "SupersetCluster pod Ready"
kubectl -n "$NS" rollout status deploy/uwv-superset-node-default --timeout=10m >/dev/null 2>&1 \
  || kubectl -n "$NS" rollout status statefulset/uwv-superset-node-default --timeout=10m >/dev/null 2>&1 \
  || fail "SupersetCluster pod niet Ready"
pass "Superset Ready"

# 2. Init-Job complete
log "Init-Job status"
phase=$(kubectl -n "$NS" get job superset-init -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "")
if [[ "$phase" != "True" ]]; then
  log "Init-Job niet (nog) Complete; logs:"
  kubectl -n "$NS" logs job/superset-init --tail=50 || true
  fail "superset-init Job niet succesvol"
fi
pass "superset-init Job Complete"

# 3. Trino-database geregistreerd via API
log "Database 'uwv-trino' in Superset"
super_pod=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=superset \
              -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$super_pod" ]]; then
  fail "Geen Superset-pod gevonden"
fi

# Login + lijst databases
admin_pw=$(kubectl -n "$NS" get secret superset-postgres-credentials \
            -o jsonpath='{.data.adminPassword}' | base64 -d)

token_resp=$(kubectl -n "$NS" exec "$super_pod" -c superset -- \
  curl -fsS -X POST http://localhost:8088/api/v1/security/login \
       -H 'Content-Type: application/json' \
       -d "{\"username\":\"uwvplatform\",\"password\":\"$admin_pw\",\"provider\":\"db\",\"refresh\":false}" \
  2>/dev/null || echo "")

token=$(echo "$token_resp" | python3 -c "import sys, json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
if [[ -z "$token" ]]; then
  fail "Kan geen access-token krijgen — login response: $token_resp"
fi

dbs=$(kubectl -n "$NS" exec "$super_pod" -c superset -- \
  curl -fsS http://localhost:8088/api/v1/database/ \
       -H "Authorization: Bearer $token" \
  2>/dev/null || echo "{}")

if echo "$dbs" | grep -q '"database_name": "uwv-trino"'; then
  pass "Trino-database 'uwv-trino' aanwezig"
else
  fail "Trino-database 'uwv-trino' niet gevonden — response:\n$dbs"
fi

# 4. Datasets aanwezig
log "Datasets aanwezig"
datasets=$(kubectl -n "$NS" exec "$super_pod" -c superset -- \
  curl -fsS http://localhost:8088/api/v1/dataset/ \
       -H "Authorization: Bearer $token" \
  2>/dev/null || echo "{}")

# We verwachten minstens 3 datasets (uc01, uc06_*, uc07).
n=$(echo "$datasets" | python3 -c "import sys, json; print(json.load(sys.stdin).get('count', 0))" 2>/dev/null || echo 0)
if [[ "$n" -ge 3 ]]; then
  pass "Datasets: $n geregistreerd"
else
  fail "Te weinig datasets ($n); verwacht ≥3"
fi

echo
pass "smoke 06-superset-up: alle checks groen"
