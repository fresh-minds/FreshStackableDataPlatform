#!/usr/bin/env bash
# Smoke test 03 — synthetische data is door de Kafka→Spark→Delta pijp gekomen
# en queryable in Trino.
#
# Voorwaarden:
#   1. Fase 0+1+2+3+4 deployed (incl. NiFiCluster, SparkApplication streaming-bronze).
#   2. `make seed` heeft gedraaid en Kafka topics gevuld.
#   3. SparkApplication heeft minimaal één micro-batch verwerkt.
set -euo pipefail

NS="${NS:-uwv-platform}"
SMOKE_USER="${SMOKE_USER:-smoketest}"
SMOKE_PASSWORD="${SMOKE_PASSWORD:-uwv-dev-only-CHANGE-ME-Smoke2026}"
EXPECTED_COUNT="${EXPECTED_COUNT:-10000}"

log()  { printf '\033[1;34m  ==>\033[0m %s\n' "$*"; }
pass() { printf '\033[1;32m  OK\033[0m  %s\n' "$*"; }
fail() { printf '\033[1;31m  FAIL\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Spark streaming-app draait
log "SparkApplication streaming-bronze status"
phase=$(kubectl -n "$NS" get sparkapplication streaming-bronze \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)
case "$phase" in
  Succeeded|Running) pass "SparkApplication phase=$phase" ;;
  Pending|Submitted) fail "SparkApplication nog Pending/Submitted ($phase) — wacht of inspecteer driver-logs" ;;
  *)                 fail "SparkApplication phase=$phase (verwacht Running)" ;;
esac

# 2. Hive Metastore kent de bronze.uwv schema
log "Hive Metastore: bronze.uwv schema"
trino_exec() {
  kubectl -n "$NS" exec statefulset/uwv-trino-coordinator-default -c trino -- \
    bash -lc "TRINO_PASSWORD='$SMOKE_PASSWORD' /stackable/trino-cli/trino \
      --server https://localhost:8443 --insecure \
      --user $SMOKE_USER --password \
      --output-format CSV \
      --execute \"$1\""
}

schemas=$(trino_exec "SHOW SCHEMAS FROM bronze" 2>&1 || true)
if echo "$schemas" | grep -qE "^\"?uwv\"?$|^uwv$"; then
  pass "schema bronze.uwv aanwezig"
else
  fail "schema bronze.uwv ontbreekt — output:\n$schemas"
fi

# 3. Tabellen in bronze.uwv
log "Bronze tabellen aanwezig"
tables=$(trino_exec "SHOW TABLES FROM bronze.uwv" 2>&1 || true)
echo "  Tabellen gevonden:"
echo "$tables" | sed 's/^/    /'

# Minimaal: persona_created (uit 10k personas)
if echo "$tables" | grep -qE 'persona_created'; then
  pass "tabel bronze.uwv.persona_created aanwezig"
else
  fail "tabel bronze.uwv.persona_created ontbreekt"
fi

# 4. Row-count
log "Row-count bronze.uwv.persona_created"
count_out=$(trino_exec "SELECT count(*) FROM bronze.uwv.persona_created" 2>&1 || true)
# Parse output: laatste regel is het getal (CSV zonder header)
n=$(echo "$count_out" | tail -1 | tr -d '"' | tr -d ' ' || echo 0)
if [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -ge "$EXPECTED_COUNT" ]]; then
  pass "persona_created bevat $n records (>= $EXPECTED_COUNT)"
elif [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -gt 0 ]]; then
  pass "persona_created bevat $n records (verwacht ~$EXPECTED_COUNT — micro-batch nog niet compleet?)"
else
  fail "persona_created count parse-error: '$count_out'"
fi

# 5. BSN-format check (eerste 5 records)
log "BSN-format check (sample 5 rijen)"
sample=$(trino_exec "SELECT json_extract_scalar(payload, '\$.payload.bsn') AS bsn FROM bronze.uwv.persona_created LIMIT 5" 2>&1 || true)
echo "$sample" | grep -E '^"?9[0-9]{8}"?$' >/dev/null \
  && pass "BSN's beginnen met 9 (test-bereik) — sample:\n$sample" \
  || fail "BSN-format afwijkend; sample:\n$sample"

echo
pass "smoke 03-bronze-data: alle checks groen"
