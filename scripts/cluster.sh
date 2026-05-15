#!/usr/bin/env bash
# Maak (of hergebruik) de k3d-cluster.
# Idempotent: als de cluster al bestaat, doet niets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLUSTER_NAME="${CLUSTER_NAME:-uwv-platform}"
CONFIG="$ROOT/infrastructure/k3d/k3d-cluster.yaml"

if ! command -v k3d >/dev/null 2>&1; then
  echo "ERROR: k3d niet gevonden. Installeer: https://k3d.io/" >&2
  exit 1
fi

if k3d cluster list -o json 2>/dev/null | jq -e ".[] | select(.name==\"${CLUSTER_NAME}\")" >/dev/null; then
  servers_running=$(k3d cluster list -o json | jq -r ".[] | select(.name==\"${CLUSTER_NAME}\") | .serversRunning")
  if [[ "${servers_running}" -gt 0 ]]; then
    echo "k3d cluster '${CLUSTER_NAME}' bestaat al en draait. Overslaan."
  else
    echo "==> k3d cluster '${CLUSTER_NAME}' bestaat maar staat stil. Starten..."
    k3d cluster start "${CLUSTER_NAME}"
  fi
else
  echo "==> Cluster aanmaken vanaf $CONFIG"
  k3d cluster create --config "$CONFIG"
fi

# Pin kubectl's current-context to the local cluster.
#
# `k3d cluster create` sets the context on first creation, but
# `k3d cluster start` (the idempotent re-run path above) does NOT touch
# kubeconfig. Meanwhile `scripts/azure/aks-context.sh` (via
# `az aks get-credentials --overwrite-existing`) flips current to AKS.
# So after even one round-trip — "did some AKS work, came back locally,
# re-ran make cluster" — the current-context is still AKS and every
# kubectl that followed silently targeted the wrong cluster.
# This line closes the hole symmetrically with the AKS path.
echo "==> setting kubectl context: k3d-${CLUSTER_NAME}"
kubectl config use-context "k3d-${CLUSTER_NAME}"
kubectl get nodes
