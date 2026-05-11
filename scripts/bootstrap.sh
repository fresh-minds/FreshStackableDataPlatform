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
OPENSEARCH_VERSION="${OPENSEARCH_VERSION:-2.27.1}"
OPENSEARCH_DASHBOARDS_VERSION="${OPENSEARCH_DASHBOARDS_VERSION:-2.26.0}"
OPENMETADATA_VERSION="${OPENMETADATA_VERSION:-1.12.6}"
VECTOR_VERSION="${VECTOR_VERSION:-0.36.1}"

log()   { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32mOK\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
error() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

# Voorvereisten check
command -v helm >/dev/null     || error "helm niet gevonden"
command -v kubectl >/dev/null  || error "kubectl niet gevonden"
command -v stackablectl >/dev/null || error "stackablectl niet gevonden — zie scripts/doctor.sh"

warn "Dev-only credentials in dit bootstrap. NIET gebruiken in productie. Zie infrastructure/helm/*/values.yaml."

# Optional per-chart override directory (set by AKS/EKS/GKE wrappers).
# Looked up file: ${HELM_OVERRIDES_DIR}/<chart>-values-aks.yaml — appended via -f after base values.
chart_override_args() {
  local chart="$1"
  if [[ -n "${HELM_OVERRIDES_DIR:-}" && -f "${HELM_OVERRIDES_DIR}/${chart}-values-aks.yaml" ]]; then
    printf -- '--values %s' "${HELM_OVERRIDES_DIR}/${chart}-values-aks.yaml"
  fi
}

# 0. Helm repo's
log "Helm repos toevoegen / updaten"
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null
helm repo add minio https://charts.min.io/ >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add opensearch https://opensearch-project.github.io/helm-charts/ >/dev/null
helm repo add open-metadata https://helm.open-metadata.org/ >/dev/null
helm repo add vector https://helm.vector.dev >/dev/null
helm repo update >/dev/null

# 1. cert-manager
log "Install cert-manager ${CERT_MANAGER_VERSION}"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --values "${ROOT}/infrastructure/helm/cert-manager/values.yaml" \
  --force-conflicts \
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
  $(chart_override_args ingress-nginx) \
  --wait --timeout 5m

# 4. PostgreSQL (shared)
log "Install PostgreSQL ${POSTGRES_VERSION} (gedeeld)"
kubectl create namespace uwv-data --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install postgres bitnami/postgresql \
  --namespace uwv-data \
  --version "${POSTGRES_VERSION}" \
  --values "${ROOT}/infrastructure/helm/postgresql/values.yaml" \
  $(chart_override_args postgres) \
  --atomic --wait --timeout 10m

# 4b. MinIO TLS-secret voorbereiden (vóór helm install minio).
# MinIO chart values pinnen `tls.certSecret: minio-tls-internal-fixed`,
# verwachten keys public.crt + private.key. cert-manager produceert
# tls.crt/tls.key. Daarom: maak Certificate, wacht op secret, re-key
# met juiste keynamen.
log "Prepare MinIO TLS secret via cert-manager"
kubectl create namespace uwv-platform --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<'EOF' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: minio-tls-internal
  namespace: uwv-platform
spec:
  secretName: minio-tls-internal
  issuerRef:
    name: uwv-platform-issuer
    kind: ClusterIssuer
  commonName: minio.uwv-platform.svc.cluster.local
  dnsNames:
    - minio.uwv-platform.svc.cluster.local
    - minio.uwv-platform.svc
    - minio
    - minio.uwv-platform.local
  duration: 8760h
EOF
# Wacht tot Secret bestaat
for i in {1..30}; do
  kubectl -n uwv-platform get secret minio-tls-internal >/dev/null 2>&1 && break
  sleep 2
done
# Re-key naar de naam + sleutels die MinIO chart verwacht
TMPCRT=$(mktemp); TMPKEY=$(mktemp); TMPCA=$(mktemp)
kubectl -n uwv-platform get secret minio-tls-internal -o jsonpath='{.data.tls\.crt}' | base64 -d > "$TMPCRT"
kubectl -n uwv-platform get secret minio-tls-internal -o jsonpath='{.data.tls\.key}' | base64 -d > "$TMPKEY"
kubectl -n uwv-platform get secret minio-tls-internal -o jsonpath='{.data.ca\.crt}' | base64 -d > "$TMPCA"
kubectl -n uwv-platform create secret generic minio-tls-internal-fixed \
  --from-file=public.crt="$TMPCRT" --from-file=private.key="$TMPKEY" --from-file=ca.crt="$TMPCA" \
  --dry-run=client -o yaml | kubectl apply -f -
# CA-bundle voor S3Connection (Stackable Trino + Spark server-verify).
# tls.crt + tls.key zijn ook nodig: Stackable secret-operator levert deze
# in format `tls-pkcs12` (Spark eist PKCS12-truststore), wat een complete
# keypair in de bron-secret vereist — anders faalt PVC-mount op
# 'missing required file tls.crt'.
kubectl -n uwv-platform create secret generic minio-ca-bundle \
  --from-file=ca.crt="$TMPCA" \
  --from-file=tls.crt="$TMPCRT" \
  --from-file=tls.key="$TMPKEY" \
  --dry-run=client -o yaml | \
  sed 's|^metadata:|metadata:\n  labels:\n    secrets.stackable.tech/class: minio-ca|' | \
  kubectl apply -f -
# uwv-ca-bundle: initial bundle = UWV self-signed CA + public roots (Mozilla
# bundle from curl.se/cacert.pem). Public roots are required so workloads
# that point REQUESTS_CA_BUNDLE/SSL_CERT_FILE at /etc/uwv-ca/ca.crt (Airflow,
# Superset) can verify Let's Encrypt-issued certs on
# {keycloak,airflow,...}.eu-sovereigndataplatform.com. Without this, Airflow's
# OIDC token exchange fails with 'unable to get local issuer certificate'.
# Stackable secret-operator's CA gets appended further down this script.
#
# We use delete+create (not `apply`) because the bundle exceeds 256KB once
# concatenated; `apply` records the whole resource as a metadata annotation
# (limit 256 KB) and rejects it. Delete+create avoids that path.
TMPPUB=$(mktemp)
log "Fetching Mozilla CA bundle (public roots) for uwv-ca-bundle"
curl -fsSL https://curl.se/ca/cacert.pem -o "$TMPPUB"
TMPCOMBINED=$(mktemp)
cat "$TMPPUB" "$TMPCA" > "$TMPCOMBINED"
kubectl -n uwv-platform delete configmap uwv-ca-bundle --ignore-not-found >/dev/null
kubectl -n uwv-platform create configmap uwv-ca-bundle \
  --from-file=ca.crt="$TMPCOMBINED" >/dev/null
rm -f "$TMPCRT" "$TMPKEY" "$TMPCA" "$TMPPUB" "$TMPCOMBINED"

# 5. MinIO
log "Install MinIO ${MINIO_VERSION}"
kubectl create namespace uwv-platform --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install minio minio/minio \
  --namespace uwv-platform \
  --version "${MINIO_VERSION}" \
  --values "${ROOT}/infrastructure/helm/minio/values.yaml" \
  $(chart_override_args minio) \
  --atomic --wait --timeout 10m

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
  $(chart_override_args keycloak) \
  --atomic --wait --timeout 10m

# 7. Prometheus + Grafana
log "Install kube-prometheus-stack ${PROM_VERSION}"
kubectl create namespace uwv-monitoring --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace uwv-monitoring \
  --version "${PROM_VERSION}" \
  --values "${ROOT}/infrastructure/helm/prometheus-stack/values.yaml" \
  $(chart_override_args prometheus-stack) \
  --atomic --wait --timeout 15m

# 8. Stackable operators
# Stackablectl 1.4+ heeft de `operator install --release-file` syntax laten
# vallen; we gebruiken nu de built-in 26.3 release. Custom pinning kan later
# via 'release install <name> -r <file>' (zie release.yaml).
log "Install Stackable operators (release 26.3)"
stackablectl release install 26.3 --operator-namespace stackable-operators

log "Wachten tot Stackable operator-pods aanwezig zijn (stackablectl returns before pods are scheduled)"
for i in {1..60}; do
  count=$(kubectl -n stackable-operators get pods --no-headers 2>/dev/null | wc -l)
  if [[ "$count" -gt 0 ]]; then break; fi
  sleep 2
done

log "Wachten tot Stackable operator-pods Ready zijn (timeout 5m)"
kubectl wait --for=condition=Ready pod -n stackable-operators \
  -l stackable.tech/vendor=Stackable \
  --timeout=5m || warn "Niet alle Stackable operator-pods zijn (nog) Ready — check 'kubectl get pods -A'"

# uwv-ca-bundle uitbreiden met de Stackable secret-operator self-signed CA.
# Stackable Trino/Hive/Kafka/etc. krijgen pod-certs uit deze CA voor in-cluster
# TLS (tls-internal SecretClass). Zonder deze CA in de bundle weigeren clients
# als Superset (REQUESTS_CA_BUNDLE → /etc/uwv-ca/ca.crt) een SQLAlchemy-
# verbinding naar https://uwv-trino-coordinator:8443 met
# 'self-signed certificate in certificate chain'. De originele uwv-platform-
# issuer CA blijft staan voor extern verkeer (Keycloak via :8443 ingress).
#
# secret-provisioner-tls-ca wordt door secret-operator pas gegenereerd op
# eerste cert-request via de `tls` SecretClass. Forceer dat met een
# kortlevende Pod die zo'n volume mountt.
log "Trigger secret-provisioner-tls-ca generation via dummy CSI volume Pod"
kubectl -n stackable-operators delete pod tls-ca-trigger --ignore-not-found --wait=true >/dev/null 2>&1 || true
cat <<'EOF' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: tls-ca-trigger
  namespace: stackable-operators
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
  - name: idle
    image: registry.k8s.io/pause:3.9
    volumeMounts:
    - name: tls
      mountPath: /tls
  volumes:
  - name: tls
    csi:
      driver: secrets.stackable.tech
      volumeAttributes:
        secrets.stackable.tech/class: tls
        secrets.stackable.tech/scope: pod
EOF

log "Wachten tot secret-provisioner-tls-ca beschikbaar is (timeout 3m)"
SECRET_READY=false
for i in {1..90}; do
  if kubectl -n stackable-operators get secret secret-provisioner-tls-ca >/dev/null 2>&1; then
    SECRET_READY=true
    break
  fi
  sleep 2
done
kubectl -n stackable-operators delete pod tls-ca-trigger --ignore-not-found --wait=false >/dev/null 2>&1 || true

if [[ "$SECRET_READY" == "true" ]]; then
  log "uwv-ca-bundle extenden met Stackable secret-operator CA"
  TMPCA=$(mktemp)
  TMPCAS=$(mktemp)
  kubectl -n uwv-platform get cm uwv-ca-bundle -o jsonpath='{.data.ca\.crt}' > "$TMPCA"
  kubectl -n stackable-operators get secret secret-provisioner-tls-ca \
    -o jsonpath='{.data.0\.ca\.crt}' | base64 -d > "$TMPCAS"
  cat "$TMPCA" "$TMPCAS" > "$TMPCA.combined"
  # delete+create (apply hits 256KB annotation limit — bundle now contains
  # 150+ public roots + UWV CA + Stackable CA).
  kubectl -n uwv-platform delete configmap uwv-ca-bundle --ignore-not-found >/dev/null
  kubectl -n uwv-platform create configmap uwv-ca-bundle \
    --from-file=ca.crt="$TMPCA.combined" >/dev/null
  rm -f "$TMPCA" "$TMPCAS" "$TMPCA.combined"
else
  warn "secret-provisioner-tls-ca niet verschenen binnen 3m — uwv-ca-bundle bevat alleen platform-CA."
  warn "Run 'bash scripts/bootstrap.sh' opnieuw na 'make deploy-platform' om de CA-bundle te complementeren."
fi

# 9. OpenSearch single-node (gedeeld voor Vector logs + OpenMetadata search)
log "Install OpenSearch ${OPENSEARCH_VERSION} (single-node, uwv-meta)"
kubectl create namespace uwv-meta --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install opensearch-uwv opensearch/opensearch \
  --namespace uwv-meta \
  --version "${OPENSEARCH_VERSION}" \
  --values "${ROOT}/infrastructure/helm/opensearch/values.yaml" \
  $(chart_override_args opensearch) \
  --atomic --wait --timeout 10m

# 9a. OpenSearch Dashboards — UI voor logs (uwv-logs-*) en OM-search indices.
log "Install OpenSearch Dashboards ${OPENSEARCH_DASHBOARDS_VERSION} (uwv-meta)"
helm upgrade --install opensearch-dashboards-uwv opensearch/opensearch-dashboards \
  --namespace uwv-meta \
  --version "${OPENSEARCH_DASHBOARDS_VERSION}" \
  --values "${ROOT}/infrastructure/helm/opensearch-dashboards/values.yaml" \
  $(chart_override_args opensearch-dashboards) \
  --atomic --wait --timeout 10m

# 10. OpenMetadata
# Voor de OIDC-koppeling met Keycloak doet de OM-pod server-side een
# token-exchange tegen https://keycloak.uwv-platform.local:8443 (zelf-signed
# CA via uwv-platform-issuer). De pod's Java truststore krijgt die CA via
# een initContainer; daarvoor moet de uwv-ca-bundle ConfigMap óók in de
# uwv-meta namespace bestaan.
log "uwv-ca-bundle ConfigMap kopiëren naar uwv-meta (voor OM Java truststore)"
# delete+create — bundle is >256KB so `apply` rejects it (annotation limit).
TMPCAYAML=$(mktemp)
kubectl -n uwv-platform get configmap uwv-ca-bundle -o jsonpath='{.data.ca\.crt}' > "$TMPCAYAML"
kubectl -n uwv-meta delete configmap uwv-ca-bundle --ignore-not-found >/dev/null
kubectl -n uwv-meta create configmap uwv-ca-bundle --from-file=ca.crt="$TMPCAYAML" >/dev/null
rm -f "$TMPCAYAML"

# OpenMetadata helm-chart hardcodes db-credential secret naam `mysql-secrets`
# met key `openmetadata-mysql-password`, ook bij Postgres. Aanmaken vóór
# install zodat het Deployment niet faalt op missing secret-key.
log "OpenMetadata mysql-secrets (chart-quirk, ook voor Postgres-deploy)"
PG_PW=$(kubectl -n uwv-data get secret postgres-postgresql -o jsonpath='{.data.password}' | base64 -d)
kubectl -n uwv-meta create secret generic mysql-secrets \
  --from-literal=openmetadata-mysql-password="${PG_PW}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# OpenMetadata Helm chart referencet `openmetadata-oidc-client` Secret in
# uwv-meta (Keycloak SSO). Die zit in platform/01-secrets/dev-secrets.yaml en
# wordt normaal door deploy-platform aangemaakt — maar dat draait NÁ bootstrap.
# Pas alle dev-secrets nu vast toe; idempotent en deploy-platform re-applyt ze
# straks gewoon.
log "Apply platform/01-secrets/dev-secrets.yaml (vereist door OM-helm-chart)"
kubectl apply -f "${ROOT}/platform/01-secrets/dev-secrets.yaml" >/dev/null

log "Install OpenMetadata ${OPENMETADATA_VERSION}"
helm upgrade --install openmetadata open-metadata/openmetadata \
  --namespace uwv-meta \
  --version "${OPENMETADATA_VERSION}" \
  --values "${ROOT}/infrastructure/helm/openmetadata/values.yaml" \
  $(chart_override_args openmetadata) \
  --wait --timeout 15m || warn "OpenMetadata install timing out — continue (init-Job kan later draaien)"

# Chart-bug workaround: OIDC_CUSTOM_PARAMS wordt door templates/secrets.yaml
# als `{{ .customParams | quote | b64enc }}` gerenderd. De `quote`-filter
# wraps `{}` in dubbele quotes → in openmetadata.yaml staat dan
# `customParams: "{}"` (een string), terwijl Java's Jackson een Map verwacht.
# Patch de auth-secret zodat `OIDC_CUSTOM_PARAMS` letterlijk `{}` is, en
# herstart de pod zodat envFrom de nieuwe waarde leest.
log "Patch OIDC_CUSTOM_PARAMS (chart-quote-bug workaround) + restart pod"
PATCH_VAL=$(printf '{}' | base64)
kubectl -n uwv-meta patch secret openmetadata-authentication-secret \
  --type='json' \
  -p="[{\"op\":\"replace\",\"path\":\"/data/OIDC_CUSTOM_PARAMS\",\"value\":\"${PATCH_VAL}\"}]" \
  >/dev/null 2>&1 || warn "patch OIDC_CUSTOM_PARAMS faalde — check helm release"
kubectl -n uwv-meta delete pod -l app.kubernetes.io/name=openmetadata >/dev/null 2>&1 || true
kubectl -n uwv-meta rollout status deploy/openmetadata --timeout=10m >/dev/null \
  || warn "OpenMetadata pod niet ready binnen 10m — check 'kubectl -n uwv-meta logs ...'"

# Genereer een admin-JWT op basis van de ingestion-bot in OM's Postgres-DB.
# OM 1.5 met `provider=custom-oidc` heeft geen basic-auth, dus `users/login`
# werkt niet. De `ingestion-bot` user heeft een fernet-encrypted JWT in
# user_entity; we decrypten met de fernet-key uit de OM Secret en patchen
# zowel de uwv-meta `openmetadata-admin` Secret (init-Job) als een kopie
# in uwv-platform (governance_om_ingest DAG draait daar).
log "Genereer admin-JWT (decrypt ingestion-bot fernet-token) + sync naar uwv-platform"
# JWT-block fail-soft: als OM nog niet ready is bestaan secret/db niet → skip met warn.
JWT=""
set +e
FERNET=$(kubectl -n uwv-meta get secret openmetadata-fernetkey-secret -o jsonpath='{.data}' 2>/dev/null \
  | python3 -c 'import json,sys,base64;d=json.load(sys.stdin);print(next(iter(base64.b64decode(v).decode() for v in d.values())))' 2>/dev/null)
ENCRYPTED=$(kubectl -n uwv-data exec postgres-postgresql-0 -c postgresql -- \
  env PGPASSWORD="$(kubectl -n uwv-data get secret postgres-postgresql -o jsonpath='{.data.password}' | base64 -d)" \
  psql -U postgres -d openmetadata -t -A -c \
  "SELECT json->'authenticationMechanism'->'config'->>'JWTToken' FROM user_entity WHERE name='ingestion-bot' LIMIT 1;" \
  2>/dev/null | sed 's/^fernet://')
if [[ -n "${FERNET}" && -n "${ENCRYPTED}" ]]; then
  JWT=$(python3 -c "
from cryptography.fernet import MultiFernet, Fernet
mf = MultiFernet([Fernet(k.encode()) for k in '${FERNET}'.split(',')])
print(mf.decrypt(b'${ENCRYPTED}').decode())
" 2>/dev/null)
fi
set -e
if [[ -n "${JWT:-}" ]]; then
  JWT_B64=$(printf '%s' "$JWT" | base64 | tr -d '\n')
  kubectl -n uwv-meta patch secret openmetadata-admin --type='json' \
    -p="[{\"op\":\"replace\",\"path\":\"/data/jwtToken\",\"value\":\"${JWT_B64}\"}]" >/dev/null
  # Kopie naar uwv-platform — KPO-tasks (governance_om_ingest) draaien daar
  # en lezen `OM_JWT_TOKEN` via secretKeyRef.
  kubectl -n uwv-platform create secret generic openmetadata-admin \
    --from-literal=jwtToken="$JWT" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "admin-JWT geseed in uwv-meta + uwv-platform"
else
  warn "JWT-decrypt faalde — 'kubectl apply -k platform/13-openmetadata-config/' werkt nu niet"
fi

# Kopie van openmetadata-uwv-config ConfigMap naar uwv-platform — de DAG
# `governance_om_ingest` draait KPO-pods in uwv-platform en mountt deze
# ConfigMap op /config voor metadata-ingest workflows.
log "Kopieer openmetadata-uwv-config ConfigMap naar uwv-platform (voor om-ingest DAG)"
kubectl -n uwv-meta get configmap openmetadata-uwv-config -o yaml 2>/dev/null \
  | sed -e 's/namespace: uwv-meta/namespace: uwv-platform/' \
        -e '/resourceVersion:/d' -e '/uid:/d' -e '/creationTimestamp:/d' \
  | kubectl apply -f - >/dev/null \
  || warn "ConfigMap kopie faalde — pas eerst 'kubectl apply -k platform/13-openmetadata-config/' toe"

# 11. Vector (logs collector → OpenSearch)
log "Install Vector ${VECTOR_VERSION} (Agent-mode op alle nodes)"
helm upgrade --install vector vector/vector \
  --namespace uwv-monitoring \
  --version "${VECTOR_VERSION}" \
  --values "${ROOT}/infrastructure/helm/vector/values.yaml" \
  --wait --timeout 5m \
  || warn "Vector install faalde — log-aggregatie inactief, niet kritisch voor portal."

log "Bootstrap voltooid."
echo
echo "Endpoints (na /etc/hosts injectie + ingress-nginx ready):"
echo "  https://keycloak.uwv-platform.local:8443      (kcadmin / dev-only-pw)"
echo "  https://minio-console.uwv-platform.local:8443 (uwvadmin / dev-only-pw)"
echo "  https://grafana.uwv-platform.local:8443       (admin / dev-only-pw)"
echo "  https://openmetadata.uwv-platform.local:8443  (admin@uwv-platform.local / dev-only-pw)"
echo
echo "Genereer een OpenMetadata JWT-token (voor init-Job + Airflow DAGs):"
echo "  kubectl -n uwv-meta exec deploy/openmetadata -- metadata generate-token > /tmp/om-token"
echo "  kubectl -n uwv-meta patch secret openmetadata-admin --type merge \\"
echo "    -p \"{\\\"stringData\\\":{\\\"jwtToken\\\":\\\"\$(cat /tmp/om-token)\\\"}}\""
echo
echo "Volgende stap: make deploy-platform"
