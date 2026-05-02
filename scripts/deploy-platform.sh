#!/usr/bin/env bash
# Deploy alle platform-manifests onder platform/ (fasen 2-9).
#
# STUB voor fase 1 — wordt in fase 2 verder ingevuld zodra
# platform/00-namespaces / 01-secrets / etc. bestaan.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# Trino catalog templates renderen voor we 09-trino aanraken.
log "Rendering Trino catalogs (TABLE_FORMAT=${TABLE_FORMAT:-from-config})"
python3 "$ROOT/scripts/render-trino-catalogs.py"

# Spark-jobs sync — kustomize kan niet uit ../../<dir> laden zonder
# load-restrictor=None, dus we kopieren naar platform/08-spark/scripts/.
log "Syncing spark-jobs/ -> platform/08-spark/scripts/"
mkdir -p "$ROOT/platform/08-spark/scripts"
cp "$ROOT/spark-jobs/streaming_kafka_to_lakehouse.py" "$ROOT/platform/08-spark/scripts/"
cp "$ROOT/spark-jobs/lib/lakehouse_io.py"             "$ROOT/platform/08-spark/scripts/"

# Volgorde van applicatie. Per directory een README.md (TODO fase 2+).
LAYERS=(
  "platform/00-namespaces"
  "platform/01-secrets"
  "platform/02-authentication"
  "platform/03-storage"
  "platform/04-zookeeper"
  "platform/05-hive-metastore"
  "platform/06-kafka"
  "platform/07-nifi"
  "platform/08-spark"
  "platform/09-trino"
  "platform/10-opa"
  "platform/11-airflow"
  "platform/12-superset"
  "platform/13-openmetadata-config"
  "platform/14-monitoring"
  "platform/15-portal"
)

for layer in "${LAYERS[@]}"; do
  if [[ -d "$ROOT/$layer" ]] && find "$ROOT/$layer" -maxdepth 2 -name '*.yaml' | grep -q .; then
    log "Apply $layer"
    kubectl apply -k "$ROOT/$layer" 2>/dev/null \
      || kubectl apply -f "$ROOT/$layer/" --recursive
  else
    log "$layer — leeg, skip (wordt in latere fase ingevuld)"
  fi
done

log "Deploy-platform fase 1 stub klaar."
echo "Run wordt pas zinvol vanaf fase 2. Zie WORKLOG.md."
