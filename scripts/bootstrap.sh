#!/usr/bin/env bash
# Bootstrap — installeer Helm-charts en Stackable-operators op een lege cluster.
#
# Volgorde:
#   1. cert-manager (CRDs first, --wait)
#   2. ClusterIssuer (self-signed CA voor *.uwv-platform.local)
#   3. ingress-nginx
#   4. PostgreSQL (gedeeld voor HMS, Airflow, Superset, OpenMetadata, Keycloak)
#   5. MinIO (S3-compatible, single-node)
#   6. Keycloak (OIDC IdP, met UWV-realm via ConfigMap-import)
#   7. Prometheus stack (incl. Grafana)
#   8. Stackable Data Platform 26.3 operators
#
# Idempotent: helm upgrade --install per chart; ConfigMaps en kubectl apply
# zijn ook idempotent.
#
# Eindresultaat: alle kruisbestuiving-services draaien; Stackable-CRDs zijn
# beschikbaar; klaar voor `make deploy-platform` (fase 2+).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Versies — bewust vastgepind; updates via PR.
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.2}"
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-4.11.3}"
POSTGRES_VERSION="${POSTGRES_VERSION:-16.0.6}"
MINIO_VERSION="${MINIO_VERSION:-5.3.0}"
KEYCLOAK_VERSION="${KEYCLOAK_VERSION:-22.2.6}"
PROM_VERSION="${PROM_VERSION:-65.5.1}"

log()   { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
error() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

# Voorvereisten check
command -v helm >/dev/null     || error "helm niet gevonden"
command -v kubectl >/dev/null  || error "kubectl niet gevonden"
command -v stackablectl >/dev/null || error "stackablectl niet gevonden — zie scripts/doctor.sh"

warn "Dev-only credentials in dit bootstrap. NIET gebruiken in productie. Zie infrastructure/helm/*/values.yaml."

# 0. Helm repo's
log "Helm repos toevoegen / updaten"
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null
helm repo add minio https://charts.min.io/ >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null

# 1. cert-manager
log "Install cert-manager ${CERT_MANAGER_VERSION}"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --values "${ROOT}/infrastructure/helm/cert-manager/values.yaml" \
  --wait --timeout 5m

# 2. ClusterIssuer (na cert-manager — CRDs moeten ready zijn)
log "Apply uwv-platform ClusterIssuer (self-signed CA)"
# Wacht expliciet tot de CRD bestaat (cert-manager helm --wait dekt dit, maar zekerheid)
kubectl wait --for=condition=Established crd/clusterissuers.cert-manager.io --timeout=2m
kubectl apply -f "${ROOT}/infrastructure/helm/cert-manager/cluster-issuer.yaml"

# 3. ingress-nginx
log "Install ingress-nginx ${INGRESS_NGINX_VERSION}"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --version "${INGRESS_NGINX_VERSION}" \
  --values "${ROOT}/infrastructure/helm/ingress-nginx/values.yaml" \
  --wait --timeout 5m

# 4. PostgreSQL (shared)
log "Install PostgreSQL ${POSTGRES_VERSION} (gedeeld)"
kubectl create namespace uwv-data --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install postgres bitnami/postgresql \
  --namespace uwv-data \
  --version "${POSTGRES_VERSION}" \
  --values "${ROOT}/infrastructure/helm/postgresql/values.yaml" \
  --wait --timeout 5m

# 5. MinIO
log "Install MinIO ${MINIO_VERSION}"
kubectl create namespace uwv-platform --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install minio minio/minio \
  --namespace uwv-platform \
  --version "${MINIO_VERSION}" \
  --values "${ROOT}/infrastructure/helm/minio/values.yaml" \
  --wait --timeout 10m

# 6. Keycloak — eerst realm-ConfigMap, daarna chart die hem mountt
log "ConfigMap: Keycloak UWV-realm"
kubectl create namespace uwv-auth --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap keycloak-uwv-realm \
  --namespace uwv-auth \
  --from-file=uwv-realm.json="${ROOT}/infrastructure/helm/keycloak/realm-uwv.json" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Install Keycloak ${KEYCLOAK_VERSION}"
helm upgrade --install keycloak bitnami/keycloak \
  --namespace uwv-auth \
  --version "${KEYCLOAK_VERSION}" \
  --values "${ROOT}/infrastructure/helm/keycloak/values.yaml" \
  --wait --timeout 10m

# 7. Prometheus + Grafana
log "Install kube-prometheus-stack ${PROM_VERSION}"
kubectl create namespace uwv-monitoring --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace uwv-monitoring \
  --version "${PROM_VERSION}" \
  --values "${ROOT}/infrastructure/helm/prometheus-stack/values.yaml" \
  --wait --timeout 10m

# 8. Stackable operators
log "Install Stackable operators (release uwv-platform-26.3)"
stackablectl operator install --release-file "${ROOT}/infrastructure/stackablectl/release.yaml"

log "Wachten tot Stackable operator-pods Ready zijn (timeout 5m)"
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/managed-by=stackablectl \
  -A --timeout=5m || warn "Niet alle Stackable operator-pods zijn (nog) Ready — check 'kubectl get pods -A'"

log "Bootstrap voltooid."
echo
echo "Endpoints (na /etc/hosts injectie + ingress-nginx ready):"
echo "  https://keycloak.uwv-platform.local:8443      (kcadmin / dev-only-pw)"
echo "  https://minio-console.uwv-platform.local:8443 (uwvadmin / dev-only-pw)"
echo "  https://grafana.uwv-platform.local:8443       (admin / dev-only-pw)"
echo
echo "Volgende stap: make deploy-platform"
