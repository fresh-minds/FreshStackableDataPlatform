#!/usr/bin/env bash
# Seed — genereer en laad synthetische data via een Kubernetes Job.
#
# Stappen:
#   1. ConfigMaps maken uit data-generation/generators/ en data-generation/*.py
#   2. Job submitten (data-generation/k8s/seed-job.yaml)
#   3. Wachten tot Job complete
#   4. Logs printen voor inspectie
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="${NS:-uwv-platform}"
COUNT="${COUNT:-10000}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

if [[ ! -d "$ROOT/data-generation/generators" ]]; then
  fail "data-generation/generators/ niet gevonden"
fi

command -v kubectl >/dev/null || fail "kubectl niet gevonden"

# Wacht tot Kafka echt bereikbaar is. `make deploy-platform` returnt zodra
# kustomize klaar is, maar de KafkaCluster pod heeft daarna nog tijd nodig:
# Stackable operator moet de StatefulSet maken, pod moet ~370MB image pullen,
# Kafka moet ZooKeeper-quorum vinden. Als seed daarvoor draait, krijgt-ie
# `NoBrokersAvailable` en faalt de Job na backoffLimit=1.
log "Wacht tot Kafka broker Ready is (max 10 min)"
if ! kubectl -n "$NS" rollout status statefulset/uwv-kafka-broker-default \
       --timeout=10m >/dev/null 2>&1; then
  warn "Kafka broker StatefulSet niet Ready binnen 10 min — seed gaat waarschijnlijk falen."
fi
# Extra: bootstrap-service moet endpoints hebben voor de Kafka API.
log "Wacht tot uwv-kafka-broker-default-bootstrap endpoints heeft"
for i in {1..60}; do
  eps=$(kubectl -n "$NS" get endpoints uwv-kafka-broker-default-bootstrap \
          -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
  [[ -n "$eps" ]] && break
  sleep 5
done
[[ -z "${eps:-}" ]] && warn "Bootstrap-service nog steeds zonder endpoints — seed kan falen."

log "ConfigMap data-generation-generators (uit data-generation/generators/)"
kubectl -n "$NS" create configmap data-generation-generators \
  --from-file="$ROOT/data-generation/generators/" \
  --dry-run=client -o yaml | kubectl apply -f -

log "ConfigMap data-generation-scripts (load_to_kafka.py + load_to_minio_staging.py)"
kubectl -n "$NS" create configmap data-generation-scripts \
  --from-file=load_to_kafka.py="$ROOT/data-generation/load_to_kafka.py" \
  --from-file=load_to_minio_staging.py="$ROOT/data-generation/load_to_minio_staging.py" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Verwijder eventueel bestaande seed-Job"
kubectl -n "$NS" delete job seed-data-generation --ignore-not-found

log "Apply seed Job (count=${COUNT})"
# COUNT en SEED zijn in de Job-yaml hardcoded op 10000/2026. Voor variatie:
# kustomize patch of een alternative manifest.
kubectl apply -f "$ROOT/data-generation/k8s/seed-job.yaml"

log "Wacht op Job completion (max 10 min)"
if ! kubectl -n "$NS" wait --for=condition=complete --timeout=10m \
       job/seed-data-generation; then
  warn "Job is niet binnen 10 min Complete; print logs:"
  kubectl -n "$NS" logs job/seed-data-generation --tail=200 || true
  fail "seed-Job niet succesvol"
fi

log "Job-logs:"
kubectl -n "$NS" logs job/seed-data-generation --tail=50

log "Klaar. Spark-streaming-job pikt nu de Kafka-events op (kan 1-2 min duren voor batch verschijnt)."
