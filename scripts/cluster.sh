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

echo "==> kubectl context: $(kubectl config current-context)"
kubectl get nodes
