# platform/15-portal — UWV Platform Portal

Rol-aware launchpad + architectuurkaart, bereikbaar op
**`https://platform.uwv-platform.local`** na `make deploy-platform`.

## Architectuur

```
Browser ── ingress-nginx ──► Service portal:80
                              │
                              ▼ targetPort 4180
                        ┌─────────────────────┐
                        │  Pod: portal        │
                        │  ┌───────────────┐  │
                        │  │ oauth2-proxy  │  │  :4180
                        │  │  (sidecar)    │  │
                        │  └───────┬───────┘  │
                        │          │ upstream │
                        │          ▼          │
                        │  ┌───────────────┐  │
                        │  │ nginx-static  │  │  :8080
                        │  │  (Astro dist) │  │  /api/health
                        │  │  /api/status  │──┼──► Prometheus
                        │  └───────────────┘  │
                        └─────────────────────┘
                              │
                              ▼  OIDC redirect/redeem
                       Keycloak realm 'uwv'
```

- **oauth2-proxy** ([`configmap-oauth2-proxy.yaml`](configmap-oauth2-proxy.yaml))
  praat met Keycloak via een _split-URL-patroon_:
  - `oidc_issuer_url` is de **externe** URL (`https://keycloak.uwv-platform.local`)
    omdat Keycloak met `proxy: edge` + `hostname: keycloak.uwv-platform.local`
    draait — issuer-claim in tokens is altijd de externe URL.
  - `redeem_url`, `profile_url`, `oidc_jwks_url` zijn de **in-cluster** URL
    (`http://keycloak.uwv-auth.svc.cluster.local`) zodat de pod ze kan bereiken
    zonder `keycloak.uwv-platform.local` te hoeven resolveren.
- **nginx-unprivileged** serveert de Astro-dist op `:8080` en proxy't
  `/api/status/up?job=…` door naar `prometheus-server.uwv-monitoring.svc`
  voor de live status-badges.
- **Realm-client `portal`** wordt gedeployd via
  [`infrastructure/helm/keycloak/realm-uwv.json`](../../infrastructure/helm/keycloak/realm-uwv.json).
  Secrets staan in [`secret.yaml`](secret.yaml) (DEV-ONLY).

## Image bouwen

```bash
# vanuit repo-root
docker build -f portal/Dockerfile -t uwv-platform/portal:dev .
# Cluster-naam = $CLUSTER_NAME uit Makefile (default: uwv-platform).
k3d image import uwv-platform/portal:dev -c uwv-platform
```

## Smoke

```bash
bash tests/smoke/09-portal-up.sh
```

## Bron-code

Astro-bron staat in [`portal/`](../../portal/).
