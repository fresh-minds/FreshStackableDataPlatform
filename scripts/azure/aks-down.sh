#!/usr/bin/env bash
# Destroy the AKS cluster via Terraform. Zero ongoing cost after this completes.
# The existing resource group dev-stackable-rg is preserved (it's a data source).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="$ROOT/infrastructure/azure/terraform"

log()   { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
error() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

[[ -n "${ARM_CLIENT_SECRET:-}"       ]] || error "ARM_CLIENT_SECRET not set. Run: source scripts/azure/env.sh"
[[ -n "${TF_VAR_sp_client_secret:-}" ]] || error "TF_VAR_sp_client_secret not set."

cd "$TF_DIR"

log "terraform destroy"
terraform destroy -auto-approve

log "Destroyed. The existing resource group dev-stackable-rg is preserved."
