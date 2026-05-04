#!/usr/bin/env bash
# Bootstrap helm charts + Stackable operators on the AKS cluster.
# Runs scripts/bootstrap.sh with HELM_OVERRIDES_DIR pointing at the AKS
# helm overlays, which switch local-path storage class to managed-csi.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

log()   { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
error() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

# Safety: refuse to run against a non-AKS context.
ctx="$(kubectl config current-context 2>/dev/null || true)"
case "$ctx" in
  uwv-platform-aks|*aks*) ;;
  *) error "kubectl context is '$ctx', not the AKS cluster. Run: make aks-context" ;;
esac
log "kubectl context: $ctx"

export HELM_OVERRIDES_DIR="$ROOT/infrastructure/azure/helm-overrides"
log "Using helm overrides from: $HELM_OVERRIDES_DIR"

bash "$ROOT/scripts/bootstrap.sh"

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
  echo "  $LB_IP keycloak.uwv-platform.local minio-console.uwv-platform.local grafana.uwv-platform.local openmetadata.uwv-platform.local trino.uwv-platform.local airflow.uwv-platform.local superset.uwv-platform.local nifi.uwv-platform.local"
else
  warn "LoadBalancer IP not yet allocated; run 'kubectl -n ingress-nginx get svc' later."
fi
