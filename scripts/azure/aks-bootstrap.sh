#!/usr/bin/env bash
# Bootstrap helm charts + Stackable operators on the AKS cluster.
# Thin wrapper around scripts/bootstrap.sh --mode=aks; the mode flag selects
# the values-aks.yaml overlays per chart (managed-csi storage, LoadBalancer
# service, public-domain hostnames).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# Force mode=aks regardless of what the caller passed — this script only
# makes sense for AKS.
export DEPLOYMENT_MODE=aks
# shellcheck source=../lib/mode.sh
source "$ROOT/scripts/lib/mode.sh"
parse_mode_args   # picks up DEPLOYMENT_MODE=aks from env
require_context

bash "$ROOT/scripts/bootstrap.sh" --mode=aks

# AKS-specific post-install: the Bitnami postgres chart's first-init silently
# fails on AKS — the data dir gets created but the chart's
# postgresql_initialize_database step that sets the postgres password and
# creates the custom user (uwvplatform) doesn't actually take effect. We fix
# that here via Unix-socket trust auth, then apply the database-creation Job.
log "Wait for postgres pod Ready"
kubectl -n uwv-data wait --for=condition=Ready pod -l app.kubernetes.io/name=postgresql --timeout=5m

log "Reconcile postgres superuser password + uwvplatform role (idempotent)"
PG_PW=$(kubectl -n uwv-data get secret postgres-postgresql -o jsonpath='{.data.postgres-password}' | base64 -d)
# Bitnami chart defaults pg_hba.conf to md5 for local connections, so we
# always pass PGPASSWORD. The ALTER USER is a no-op if the chart already set
# the password correctly; it's a safety net for the case where the chart's
# init silently fails on a fresh AKS PVC.
kubectl -n uwv-data exec postgres-postgresql-0 -- env PGPASSWORD="${PG_PW}" \
  psql -U postgres -c "ALTER USER postgres WITH PASSWORD '${PG_PW}';" >/dev/null
kubectl -n uwv-data exec postgres-postgresql-0 -- env PGPASSWORD="${PG_PW}" bash -c \
  "psql -U postgres -tAc \"SELECT 1 FROM pg_roles WHERE rolname='uwvplatform'\" | grep -q 1 || \
   psql -U postgres -c \"CREATE USER uwvplatform WITH PASSWORD '${PG_PW}' CREATEDB;\""

log "Apply postgres-create-databases Job"
kubectl apply -f "$ROOT/infrastructure/azure/postgres-create-databases.yaml"
kubectl -n uwv-data wait --for=condition=Complete job/postgres-create-databases --timeout=2m \
  || warn "postgres-create-databases Job did not complete; check 'kubectl -n uwv-data logs job/postgres-create-databases'"

# AKS-specific: OpenMetadata's helm chart hardcodes the database-credential
# secret name as 'mysql-secrets' with key 'openmetadata-mysql-password',
# even when the configured driver is postgres. The base bootstrap doesn't
# create it (the k3d setup probably tolerated the failure or had it created
# by a follow-up Job in platform/13-openmetadata-config). Create it here so
# the openmetadata Deployment can finish init.
log "Create OpenMetadata mysql-secrets (workaround for chart's hardcoded name)"
kubectl create namespace uwv-meta --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n uwv-meta create secret generic mysql-secrets \
  --from-literal=openmetadata-mysql-password="${PG_PW}" \
  --dry-run=client -o yaml | kubectl apply -f -

log "AKS bootstrap done."

# Show LoadBalancer IP so user can update /etc/hosts.
log "Waiting for ingress-nginx LoadBalancer IP..."
for i in $(seq 1 60); do
  LB_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "$LB_IP" ]]; then
    break
  fi
  sleep 5
done

if [[ -n "${LB_IP:-}" ]]; then
  log "Ingress LoadBalancer IP: $LB_IP"
  echo "Add to /etc/hosts:"
  echo "  $LB_IP keycloak.uwv-platform.local minio-console.uwv-platform.local grafana.uwv-platform.local openmetadata.uwv-platform.local airflow.uwv-platform.local superset.uwv-platform.local spark.uwv-platform.local"
else
  warn "LoadBalancer IP not yet allocated; run 'kubectl -n ingress-nginx get svc' later."
fi
