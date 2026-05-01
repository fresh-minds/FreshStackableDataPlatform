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

if k3d cluster list -o json 2>/dev/null | grep -q "\"name\": \"${CLUSTER_NAME}\""; then
  echo "k3d cluster '${CLUSTER_NAME}' bestaat al. Overslaan."
else
  echo "==> Cluster aanmaken vanaf $CONFIG"
  k3d cluster create --config "$CONFIG"
fi

echo "==> kubectl context: $(kubectl config current-context)"
kubectl get nodes
