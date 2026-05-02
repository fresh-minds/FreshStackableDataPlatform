#!/usr/bin/env bash
# Provision the AKS cluster via Terraform. Idempotent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="$ROOT/infrastructure/azure/terraform"

log()   { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
error() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

[[ -n "${ARM_CLIENT_ID:-}"        ]] || error "ARM_CLIENT_ID not set. Run: source scripts/azure/env.sh"
[[ -n "${ARM_CLIENT_SECRET:-}"    ]] || error "ARM_CLIENT_SECRET not set. Run: source scripts/azure/env.sh"
[[ -n "${ARM_TENANT_ID:-}"        ]] || error "ARM_TENANT_ID not set."
[[ -n "${ARM_SUBSCRIPTION_ID:-}"  ]] || error "ARM_SUBSCRIPTION_ID not set."
[[ -n "${TF_VAR_sp_client_secret:-}" ]] || error "TF_VAR_sp_client_secret not set."

if [[ ! -f "$TF_DIR/terraform.tfvars" ]]; then
  log "Creating $TF_DIR/terraform.tfvars from example"
  cp "$TF_DIR/terraform.tfvars.example" "$TF_DIR/terraform.tfvars"
fi

cd "$TF_DIR"

log "terraform init"
terraform init -upgrade

log "terraform plan"
terraform plan -out=tfplan

log "terraform apply"
terraform apply -auto-approve tfplan
rm -f tfplan

log "Outputs:"
terraform output

log "Done. Next: make aks-context"
