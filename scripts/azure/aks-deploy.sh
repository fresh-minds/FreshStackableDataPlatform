#!/usr/bin/env bash
# Deploy platform manifests on the AKS cluster.
# Thin wrapper around scripts/deploy-platform.sh with an AKS context safety check.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

log()   { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
error() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

ctx="$(kubectl config current-context 2>/dev/null || true)"
case "$ctx" in
  uwv-platform-aks|*aks*) ;;
  *) error "kubectl context is '$ctx', not the AKS cluster. Run: make aks-context" ;;
esac
log "kubectl context: $ctx"

bash "$ROOT/scripts/deploy-platform.sh"
