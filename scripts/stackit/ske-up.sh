#!/usr/bin/env bash
# Provision the StackIT SKE cluster + reserved Floating IP via Terraform.
# Idempotent — running on an existing cluster is a no-op (or refresh-only).
#
# Prereqs:
#   - terraform >= 1.5 on PATH
#   - STACKIT_SERVICE_ACCOUNT_KEY_PATH pointing at a valid SA key JSON
#     (defaults to ~/.config/stackit/sa-key.json if unset)
#
# After this script, the rest of the lifecycle is mode-aware (see ske-
# bootstrap.sh, ske-deploy.sh, portal-publish.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

log()   { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
error() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

: "${STACKIT_SERVICE_ACCOUNT_KEY_PATH:=$HOME/.config/stackit/sa-key.json}"
export STACKIT_SERVICE_ACCOUNT_KEY_PATH

if [[ ! -r "$STACKIT_SERVICE_ACCOUNT_KEY_PATH" ]]; then
  error "STACKIT_SERVICE_ACCOUNT_KEY_PATH=$STACKIT_SERVICE_ACCOUNT_KEY_PATH not readable. Create a non-SKE-managed SA (see feedback_stackit_ske_managed_sa.md) and save the key JSON there."
fi

cd infrastructure/stackit/terraform

if [[ ! -d .terraform ]]; then
  log "terraform init"
  terraform init -input=false
fi

log "terraform apply (cluster + Floating IP; ~13 min on fresh provisioning)"
terraform apply -auto-approve -input=false

echo
log "outputs:"
terraform output
echo
log "Next: \`eval \$(make stackit-context)\` to load the generated kubeconfig, then \`make stackit-bootstrap\`."
