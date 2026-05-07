#!/usr/bin/env bash
# Full teardown — destroys EVERYTHING terraform created in dev-stackable-rg:
#   AKS cluster, VPN Gateway, VNet, Public IP, certs.
# After this completes, Azure cost for this stack is €0.
# The dev-stackable-rg resource group itself is preserved (it's a data source).
#
# VPN Gateway delete is the slow part (~10-15 min).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

log()   { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
error() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f scripts/azure/env.sh ]] || error "scripts/azure/env.sh ontbreekt."
# shellcheck source=/dev/null
source scripts/azure/env.sh

log "terraform destroy (~10-20 min — VPN Gateway is the slow one)"
bash scripts/azure/aks-down.sh

log "Verifying nothing is left in dev-stackable-rg that we created"
az resource list -g dev-stackable-rg \
  --query "[?tags.managed_by=='terraform'].{name:name, type:type}" -o table 2>/dev/null \
  || true

log "Done. Cost from this stack: €0."
