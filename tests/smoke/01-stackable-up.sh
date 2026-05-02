#!/usr/bin/env bash
# Smoke test 01 — bootstrap-status na `make bootstrap`.
#
# Checkt:
#   1. Cluster bereikbaar
#   2. Verwachte namespaces aanwezig
#   3. Helm-releases up
#   4. Keycloak UWV-realm imported (HTTP-discovery endpoint reachable)
#   5. MinIO buckets aangemaakt
#   6. Stackable operators Ready
#   7. cert-manager ClusterIssuer Ready
set -euo pipefail

log()  { printf '\033[1;34m  ==>\033[0m %s\n' "$*"; }
pass() { printf '\033[1;32m  OK\033[0m  %s\n' "$*"; }
fail() { printf '\033[1;31m  FAIL\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Cluster
kubectl cluster-info >/dev/null || fail "kubectl cluster-info werkt niet"
pass "kubectl cluster bereikbaar ($(kubectl config current-context))"

# 2. Namespaces
for ns in cert-manager ingress-nginx uwv-platform uwv-data uwv-auth uwv-monitoring stackable-operators; do
  kubectl get namespace "$ns" >/dev/null 2>&1 || fail "namespace $ns ontbreekt"
done
pass "verwachte namespaces aanwezig"

# 3. Helm releases
required_releases=(
  "cert-manager:cert-manager"
  "ingress-nginx:ingress-nginx"
  "uwv-data:postgres"
  "uwv-platform:minio"
  "uwv-auth:keycloak"
  "uwv-monitoring:prometheus"
)
for entry in "${required_releases[@]}"; do
  ns="${entry%%:*}"
  rel="${entry##*:}"
  if helm status -n "$ns" "$rel" >/dev/null 2>&1; then
    pass "helm release '$rel' deployed in '$ns'"
  else
    fail "helm release '$rel' ontbreekt in namespace '$ns'"
  fi
done

# 4. ClusterIssuer ready
if kubectl get clusterissuer uwv-platform-issuer >/dev/null 2>&1; then
  if kubectl get clusterissuer uwv-platform-issuer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True; then
    pass "ClusterIssuer uwv-platform-issuer Ready"
  else
    fail "ClusterIssuer uwv-platform-issuer NIET Ready"
  fi
else
  fail "ClusterIssuer uwv-platform-issuer ontbreekt"
fi

# 5. MinIO buckets (via mc-job hook in chart)
log "Check MinIO buckets via API"
mc_pod=$(kubectl -n uwv-platform get pod -l app=minio -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$mc_pod" ]]; then
  buckets=$(kubectl -n uwv-platform exec "$mc_pod" -- mc ls local/ 2>/dev/null | awk '{print $NF}' | tr -d '/' | sort)
  for b in uwv-bronze uwv-silver uwv-gold uwv-sensitive uwv-staging uwv-checkpoints uwv-meta; do
    if echo "$buckets" | grep -qx "$b"; then
      pass "bucket $b bestaat"
    else
      fail "bucket $b ontbreekt"
    fi
  done
else
  log "MinIO pod nog niet schedulable; sla bucket-check over (warning)"
fi

# 6. Stackable operators Ready
log "Stackable operator pods"
not_ready=$(kubectl get pods -n stackable-operators --no-headers 2>/dev/null \
  | awk '{print $1, $2, $3}' \
  | grep -vE 'Running|Completed' \
  || true)
if [[ -z "$not_ready" ]]; then
  pass "alle Stackable operator pods Running/Completed"
else
  fail "Stackable operator pods niet Ready: \n$not_ready"
fi

# 7. Keycloak OIDC discovery
log "Keycloak OIDC discovery (in-cluster)"
discovery=$(kubectl -n uwv-auth run kc-test-$RANDOM \
  --image=curlimages/curl:8.10.1 --rm -i --restart=Never --quiet -- \
  curl -fsSL --max-time 10 \
    "http://keycloak.uwv-auth.svc.cluster.local/realms/uwv/.well-known/openid-configuration" \
  2>/dev/null | head -c 200 || true)
if echo "$discovery" | grep -q '"issuer"'; then
  pass "Keycloak realm 'uwv' beantwoordt OIDC-discovery"
else
  fail "Keycloak realm 'uwv' beantwoordt geen OIDC-discovery"
fi

# ----------------------------------------------------------------------
# Foundation services (fase 2). Skipt elegant als deze nog niet zijn applied.
# ----------------------------------------------------------------------
log "Foundation services (fase 2) — als reeds applied"

ready_or_skip() {
  local kind="$1" name="$2" ns="${3:-uwv-platform}"
  if ! kubectl -n "$ns" get "$kind" "$name" >/dev/null 2>&1; then
    printf "  [SKIP] %s/%s — nog niet applied (run 'make deploy-platform')\n" "$kind" "$name"
    return 0
  fi
  # Wacht maximaal 30s op Ready-pods voor deze workload-label.
  if kubectl -n "$ns" wait --for=condition=Ready pod \
       -l app.kubernetes.io/instance="$name" --timeout=30s >/dev/null 2>&1; then
    pass "$kind/$name pods Ready"
  else
    fail "$kind/$name pods NIET Ready"
  fi
}

ready_or_skip zookeepercluster uwv-zookeeper
ready_or_skip hivecluster uwv-hive
ready_or_skip kafkacluster uwv-kafka

# Stackable-CRDs aanwezig (basisset uit release.yaml)
log "Stackable CRD-installatie check"
expected_crds=(
  zookeeperclusters.zookeeper.stackable.tech
  hiveclusters.hive.stackable.tech
  kafkaclusters.kafka.stackable.tech
  trinoclusters.trino.stackable.tech
  trinocatalogs.trino.stackable.tech
  sparkapplications.spark.stackable.tech
  airflowclusters.airflow.stackable.tech
  supersetclusters.superset.stackable.tech
  nificlusters.nifi.stackable.tech
  opaclusters.opa.stackable.tech
  authenticationclasses.authentication.stackable.tech
  s3connections.s3.stackable.tech
  secretclasses.secrets.stackable.tech
)
crd_missing=0
for crd in "${expected_crds[@]}"; do
  if kubectl get crd "$crd" >/dev/null 2>&1; then
    : # ok, niet luid loggen — anders te veel ruis
  else
    printf "  [MISS] CRD %s\n" "$crd"
    crd_missing=$((crd_missing+1))
  fi
done
if [[ $crd_missing -eq 0 ]]; then
  pass "Stackable CRDs aanwezig (${#expected_crds[@]} stuks)"
else
  fail "$crd_missing Stackable CRDs ontbreken"
fi

# Foundation-resources die in fase 2 zijn aangemaakt
log "Foundation custom resources (skip indien afwezig)"
for r in \
  "secretclass/s3-credentials-minio:" \
  "secretclass/oidc-client-credentials:" \
  "authenticationclass/keycloak-uwv:" \
  "s3connection/s3-minio:uwv-platform" \
  "zookeepercluster/uwv-zookeeper:uwv-platform" \
  "zookeeperznode/uwv-zookeeper-znode-kafka:uwv-platform"
do
  kind_name="${r%%:*}"
  ns="${r##*:}"
  ns_arg=""
  [[ -n "$ns" ]] && ns_arg="-n $ns"
  if kubectl get "$kind_name" $ns_arg >/dev/null 2>&1; then
    pass "$kind_name aanwezig"
  else
    printf "  [SKIP] %s — nog niet applied\n" "$kind_name"
  fi
done

echo
pass "smoke 01-stackable-up: alle checks groen"
