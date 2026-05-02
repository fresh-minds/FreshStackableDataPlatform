#!/usr/bin/env bash
# Resume a stopped AKS cluster.
set -euo pipefail

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

RG="${AKS_RESOURCE_GROUP:-dev-stackable-rg}"
NAME="${AKS_CLUSTER_NAME:-uwv-platform-aks}"

log "Starting AKS cluster '$NAME' in '$RG'"
az aks start --resource-group "$RG" --name "$NAME"

log "Started. Refresh kubeconfig: make aks-context"
