#!/usr/bin/env bash
# Stop the AKS cluster — deallocates the node VMs (no compute charge while stopped).
# Disks and the cluster object remain. Resume with scripts/azure/aks-start.sh.
set -euo pipefail

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

RG="${AKS_RESOURCE_GROUP:-dev-stackable-rg}"
NAME="${AKS_CLUSTER_NAME:-uwv-platform-aks}"

log "Stopping AKS cluster '$NAME' in '$RG' (deallocates nodes)"
az aks stop --resource-group "$RG" --name "$NAME"

log "Stopped. Cluster object still exists; nodes are deallocated."
log "Resume with: make aks-start"
log "Full teardown (zero cost): make aks-down"
