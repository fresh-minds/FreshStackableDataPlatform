#!/usr/bin/env bash
# Build (or re-build) the Astro portal under portal/, package the static
# output into a binaryData ConfigMap, and roll the platform-landing
# Deployment so it picks up the new bundle.
#
# Same approach as scripts/azure/portal-publish.sh — `dist/` lives in a
# ConfigMap (~312 KB compressed, under the 1 MiB ConfigMap limit), an
# initContainer extracts it into emptyDir on pod start, and stock
# nginxinc/nginx-unprivileged serves from there. Avoids needing a
# registry SKE can pull from for the Astro build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

log()   { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
error() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

ctx="$(kubectl config current-context 2>/dev/null || true)"
case "$ctx" in
  udp-stackit|*stackit*) ;;
  *) error "kubectl context is '$ctx', not the StackIT cluster. Run: export KUBECONFIG=infrastructure/stackit/terraform/kubeconfig.yaml" ;;
esac

if [[ ! -d portal/dist || -z "$(ls -A portal/dist 2>/dev/null)" ]]; then
  log "portal/dist is missing — building (npm install + astro build)"
  (cd portal && npm install --no-audit --no-fund && npm run build)
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# portal/dist needs to fit in ConfigMaps (1 MiB hard limit each). Split into
# THREE tarballs to handle the current bundle size (~2.1 MB total compressed):
#   - main:      everything except dbt-docs.html and _astro/   (~975 KB)
#   - _astro:    JS bundles + fonts                              (~442 KB)
#   - dbt-docs:  the 4 MB self-contained dbt-docs.html alone    (~706 KB)
# Each must be < 1 MiB. If the portal grows further this WILL fail again —
# at that point switch the platform-landing Deployment to a registry-based
# nginx image (see future Phase 7).
log "Packaging portal/dist (split: main + _astro + dbt-docs)"
tar czf "$TMP/portal-dist.tar.gz" --exclude=dbt-docs.html --exclude=_astro -C portal/dist .
MAIN_SIZE=$(wc -c <"$TMP/portal-dist.tar.gz")
log "  main tarball: $MAIN_SIZE bytes"
if (( MAIN_SIZE > 1000000 )); then
  error "main tarball is larger than 1 MB — split _astro further or switch to a registry-based image."
fi

ASTRO_SIZE=0
if [[ -d portal/dist/_astro ]]; then
  tar czf "$TMP/astro.tar.gz" -C portal/dist _astro
  ASTRO_SIZE=$(wc -c <"$TMP/astro.tar.gz")
  log "  _astro tarball: $ASTRO_SIZE bytes"
  if (( ASTRO_SIZE > 1000000 )); then
    error "_astro tarball is larger than 1 MB — split into chunks or switch to a registry-based image."
  fi
fi

DBT_SIZE=0
if [[ -f portal/dist/dbt-docs.html ]]; then
  tar czf "$TMP/dbt-docs.tar.gz" -C portal/dist dbt-docs.html
  DBT_SIZE=$(wc -c <"$TMP/dbt-docs.tar.gz")
  log "  dbt-docs tarball: $DBT_SIZE bytes"
  if (( DBT_SIZE > 1000000 )); then
    error "dbt-docs tarball is larger than 1 MB — won't fit in a ConfigMap."
  fi
fi

CHECKSUM=$(shasum -a 256 "$TMP/portal-dist.tar.gz" | cut -c1-12)

# kubectl apply records the whole resource as a metadata annotation (limit
# 256 KB) — so for >256 KB tarballs we delete-and-create instead. The
# Deployment is rolled in the next step regardless, so the brief gap is fine.
log "Apply ConfigMap platform-landing-dist (main tarball)"
kubectl -n uwv-platform delete configmap platform-landing-dist --ignore-not-found >/dev/null
kubectl -n uwv-platform create configmap platform-landing-dist \
  --from-file=portal-dist.tar.gz="$TMP/portal-dist.tar.gz" >/dev/null

if (( ASTRO_SIZE > 0 )); then
  log "Apply ConfigMap platform-landing-astro (_astro tarball)"
  kubectl -n uwv-platform delete configmap platform-landing-astro --ignore-not-found >/dev/null
  kubectl -n uwv-platform create configmap platform-landing-astro \
    --from-file=astro.tar.gz="$TMP/astro.tar.gz" >/dev/null
fi

if (( DBT_SIZE > 0 )); then
  log "Apply ConfigMap platform-landing-dbt-docs (dbt-docs.html tarball)"
  kubectl -n uwv-platform delete configmap platform-landing-dbt-docs --ignore-not-found >/dev/null
  kubectl -n uwv-platform create configmap platform-landing-dbt-docs \
    --from-file=dbt-docs.tar.gz="$TMP/dbt-docs.tar.gz" >/dev/null
fi

log "Roll the Deployment so the initContainer re-extracts the new tarballs"
kubectl -n uwv-platform patch deployment platform-landing \
  --type=merge -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"portal.uwv-platform/dist-checksum\":\"$CHECKSUM\"}}}}}" >/dev/null
kubectl -n uwv-platform rollout status deploy/platform-landing --timeout=120s

log "Done. Browse https://platform.freshstackable.com/"
