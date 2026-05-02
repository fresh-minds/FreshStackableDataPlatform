#!/usr/bin/env bash
# Doctor — controleer of de host de vereiste tooling heeft.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required=(
  "docker     version 24+"
  "k3d        version 5.6+"
  "kubectl    version 1.29+"
  "helm       version 3.14+"
  "stackablectl version 25+ (https://github.com/stackabletech/stackable-cockpit)"
  "jq         (JSON in shells)"
  "yq         (YAML in shells)"
  "opa        (Rego — fase 9)"
  "python3    3.11+"
)

optional=(
  "mc         (MinIO client — handig voor seed)"
  "psql       (PostgreSQL client)"
  "yamllint   (CI lint)"
  "ruff       (Python lint)"
)

missing=0
warn=0

check() {
  local name="$1"
  local critical="$2"
  if command -v "$name" >/dev/null 2>&1; then
    printf "  [OK]   %-12s -> %s\n" "$name" "$(command -v "$name")"
  else
    if [[ "$critical" == "yes" ]]; then
      printf "  [MISS] %-12s\n" "$name"
      missing=$((missing+1))
    else
      printf "  [warn] %-12s (optioneel)\n" "$name"
      warn=$((warn+1))
    fi
  fi
}

echo "== Vereiste tooling =="
for line in "${required[@]}"; do
  bin="${line%% *}"
  check "$bin" yes
done

echo
echo "== Optionele tooling =="
for line in "${optional[@]}"; do
  bin="${line%% *}"
  check "$bin" no
done

echo
echo "== /etc/hosts check =="
hosts=(
  trino.uwv-platform.local
  keycloak.uwv-platform.local
  superset.uwv-platform.local
  airflow.uwv-platform.local
  nifi.uwv-platform.local
  minio.uwv-platform.local
  minio-console.uwv-platform.local
  openmetadata.uwv-platform.local
  grafana.uwv-platform.local
)
hosts_missing=0
for h in "${hosts[@]}"; do
  if grep -q "$h" /etc/hosts 2>/dev/null; then
    printf "  [OK]   %s\n" "$h"
  else
    printf "  [MISS] %s\n" "$h"
    hosts_missing=$((hosts_missing+1))
  fi
done

if [[ $hosts_missing -gt 0 ]]; then
  echo
  echo "Voeg toe aan /etc/hosts (sudo vereist):"
  echo "  127.0.0.1 ${hosts[*]}"
fi

echo
if [[ $missing -gt 0 || $hosts_missing -gt 0 ]]; then
  echo "FAIL: ontbrekende vereisten."
  exit 1
fi

echo "OK: alle vereiste tooling aanwezig."
[[ $warn -gt 0 ]] && echo "  ($warn optionele tools ontbreken — niet blokkerend)"

echo
echo "== AKS / Azure tooling (alleen nodig voor 'make aks-*') =="
azure_tools=(az terraform jq)
for bin in "${azure_tools[@]}"; do
  check "$bin" no
done
if [[ -f "$ROOT/scripts/azure/env.sh" ]]; then
  printf "  [OK]   %-12s -> %s\n" "env.sh" "$ROOT/scripts/azure/env.sh"
else
  printf "  [warn] %-12s (kopieer scripts/azure/env.sh.example en vul de SP-secret in)\n" "env.sh"
fi
if command -v az >/dev/null 2>&1; then
  acct="$(az account show --query name -o tsv 2>/dev/null || true)"
  if [[ -n "$acct" ]]; then
    printf "  [OK]   az login        -> %s\n" "$acct"
  else
    printf "  [warn] az login        (nog niet ingelogd: az login)\n"
  fi
fi
