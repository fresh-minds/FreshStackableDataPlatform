# Power BI in-portal embed — AKS + Entra ID SSO

End-state: een gebruiker logt op `https://platform.eu-sovereigndataplatform.com/`
in via **Microsoft Entra ID** (via de Keycloak-broker, [ADR-0008](../adr/0008-entra-broker-via-keycloak.md)),
klikt links op **Dashboarding → Power BI**, en ziet het UC-12 FinOps-rapport
**ingebed in de portal-shell** zonder iframe-blok of "Open in nieuw tabblad"-omweg.

Werkt door:
- Microsoft's restrictieve `frame-ancestors`-CSP op `app.fabric.microsoft.com`
  te **omzeilen** met de Power BI Embedded SDK (`powerbi-client-react`) —
  die rendert tegen `app.powerbi.com/reportEmbed`, een surface die wél
  cross-origin embedden accepteert mits het een geldig embed-token krijgt.
- De portal-backend te laten **server-mint** van dat embed-token via een
  Service Principal (de bestaande UC-11/UC-12 SP); `effectiveIdentity`
  draagt de gefedereerde Entra-mail uit oauth2-proxy mee voor audit + RLS.

Resultaat: échte SSO via Entra, géén per-user Power BI-licentie nodig,
audit-spoor met de echte gebruikersnaam, en de rest van het portal-shell
(rail · top-bar · cmdk) blijft eromheen staan.

---

## Architectuur

```
┌─────────────────────────────────────────────────────────────────────┐
│ Browser                                                              │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ Astro portal — /embed/powerbi/                              │    │
│  │  PowerBIEmbed.tsx (React Island)                            │    │
│  │   1. fetch /api/portal/powerbi/embed/<reportId>             │    │
│  │   2. <PowerBIEmbed config={token,url}/>                     │    │
│  │     ── iframe ─▶ https://app.powerbi.com/reportEmbed?...    │    │
│  └─────────────────────────────────────────────────────────────┘    │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ cookie van oauth2-proxy
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│ AKS / uwv-platform namespace                                         │
│                                                                      │
│  oauth2-proxy ── X-Auth-Request-Email ─▶  portal-backend (FastAPI)   │
│       │                                       │                       │
│       │ /oauth2/sign_in                       │ POST /api/portal/    │
│       ▼                                       │    powerbi/embed/<id> │
│  ┌──────────┐  brokered OIDC  ┌─────────┐    │                       │
│  │ Keycloak │ ──────────────▶ │  Entra  │    │  1. client_credentials│
│  │  realm   │ ◀────────────── │   ID    │    │     SP token          │
│  └──────────┘     id_token     └─────────┘    │  2. GET .../reports/x │
│                                                │  3. POST .../Generate │
│                                                │     Token + identity  │
│                                                ▼                       │
│                                  Service Principal env-vars            │
│                                  (Secret powerbi-embed-creds)          │
└──────────────────────────────────────────────────────────────────────┘
```

Twee belangrijke punten:
- **Keycloak IdP-brokering is alleen voor de portal-login** (oauth2-proxy
  praat met Keycloak, Keycloak doet de OIDC-handshake met Entra). De
  user's Entra **access-token** wordt niet doorgegeven — Keycloak heeft
  z'n eigen sessie. De portal-backend kent alleen de e-mail van de
  ge-federeerde Entra-identiteit (via `X-Auth-Request-Email`).
- **De embed-token komt van de SP**, niet van de user. Dit is bewust:
  - pure User-Owns-Data (user → MSAL → Entra → eigen Power BI-token) zou
    elke viewer een Pro/PPU-licentie kosten;
  - App-Owns-Data + `effectiveIdentity` levert dezelfde audit + RLS
    zonder per-user licentie. Werkt op elke F SKU.

---

## Voorvereisten

| | Status | Notitie |
|---|---|---|
| AKS cluster up + bootstrap | ✓ in `scripts/azure/aks-up.sh` + `make aks-all` | Public DNS `*.eu-sovereigndataplatform.com` + Let's Encrypt |
| Keycloak realm `uwv` met Entra IdP | ✓ in deze branch (ADR-0008 cherry-picked) | Realm-import bevat IdP `entra` met `REPLACE_ME` placeholders |
| Service Principal met Workspace-Contributor op de Fabric workspace | ✓ — UC-11/UC-12 reuse | Zelfde SP uit `secrets/local/uc11-multiplatform.env` |
| Power BI API delegated permissions op de SP | ❌ **Te doen** (Entra portal) | Zie [§ Setup-stappen](#setup-stappen) |
| K8s Secret `powerbi-embed-creds` in `uwv-platform` namespace | ❌ **Te doen** (één `kubectl` commando) | Template in `platform/15-portal/powerbi-embed-creds-template.yaml` |
| Power BI report om te embedden | ✓ — UC-12 dashboard `3f508254-…` | Default report-id in `PowerBIEmbed.tsx` |

---

## Setup-stappen

### 1. Entra App Registration permissions

De UC-11/UC-12 SP heeft workspace-Contributor maar mist mogelijk de
**Power BI Service** API-permissions die `GenerateToken` nodig heeft.

In de Azure Portal:

1. Navigeer naar **Entra ID → App registrations → `<uw SP-naam>`**.
2. **API permissions → Add permission → Power BI Service**:
   - `Dataset.Read.All` (Application)
   - `Report.Read.All` (Application)
   - `Workspace.Read.All` (Application)
3. **Grant admin consent for `<tenant>`** (klik de knop; zonder dit
   schijnt de permissie wel maar werkt 'm niet).

Verifieer dat de Power BI tenant-setting **"Service principals can use
Power BI APIs"** aanstaat (Fabric Admin Portal → Tenant settings → Developer
settings). Bij voorkeur scope het op een security-group waarin alleen deze
SP zit.

### 2. Keycloak Entra IdP

Vul de placeholders in `infrastructure/helm/keycloak/realm-uwv.json`
(of in de runtime-Secret `keycloak-entra-broker` — zie
[platform/02-authentication/README.md](../../platform/02-authentication/README.md)):

```
REPLACE_ME_ENTRA_TENANT_ID  → <uw tenant GUID>
REPLACE_ME_ENTRA_CLIENT_ID  → <App Registration client ID>
REPLACE_ME_ENTRA_CLIENT_SECRET → <client secret value>
```

De realm-import gebeurt bij de eerste boot van het Keycloak-StatefulSet;
voor een running cluster: patch via de Admin REST API of doe een
`kubectl rollout restart` na een `make aks-bootstrap`-rerun.

Stel daarna de **Redirect URI** in de Entra app-registration in op:
```
https://keycloak.eu-sovereigndataplatform.com/realms/uwv/broker/entra/endpoint
```

### 3. K8s Secret voor de SP-creds

Vanuit repo-root, met je SP-creds in de shell:

```bash
set -a; source secrets/local/uc11-multiplatform.env; set +a
kubectl -n uwv-platform create secret generic powerbi-embed-creds \
  --from-literal=FABRIC_TENANT_ID="$FABRIC_TENANT_ID" \
  --from-literal=FABRIC_CLIENT_ID="$FABRIC_CLIENT_ID" \
  --from-literal=FABRIC_CLIENT_SECRET="$FABRIC_CLIENT_SECRET" \
  --from-literal=FABRIC_WORKSPACE_ID="$FABRIC_WORKSPACE_ID"

kubectl -n uwv-platform rollout restart deploy/udp-portal-backend
kubectl -n uwv-platform rollout status  deploy/udp-portal-backend --timeout=120s
```

### 4. Deploy de portal-update

```bash
make deploy MODE=aks
```

Bouwt het portal-image (`uwv-platform/portal:dev`) inclusief de
nieuwe `powerbi-client-react` deps en de aangepaste nginx-CSP,
ship't 'm via de ConfigMap-tarball (zie `scripts/azure/portal-publish.sh`),
en rollt de Deployment uit. De portal-backend wordt automatisch herstart
omdat z'n Deployment-spec is gewijzigd (4 nieuwe env-refs).

### 5. Verifieer

```bash
# Backend reachable?
kubectl -n uwv-platform exec deploy/udp-portal-backend -- \
  curl -s http://localhost:8089/api/portal/_ping

# Backend kan SP-token ophalen?
# (vereist dat je via oauth2-proxy bent ingelogd; lokale dev: skip)

# Open in browser:
open https://platform.eu-sovereigndataplatform.com/embed/powerbi/
```

Verwacht gedrag:
1. Login-redirect naar Keycloak (eerste bezoek).
2. Keycloak toont login-knop **"Microsoft Entra ID"** + lokale login-form.
3. Klik op de Entra-knop → Entra login → terug naar Keycloak → terug naar
   portal met cookie.
4. `/embed/powerbi/` laadt; "Power BI rapport laden…" spinner verschijnt
   even, daarna het UC-12 FinOps-dashboard volledig ingebed.

---

## Files in deze slice

| File | Wat |
|---|---|
| [`portal/src/components/powerbi/PowerBIEmbed.tsx`](../../portal/src/components/powerbi/PowerBIEmbed.tsx) | React Island; fetch token → render `<PowerBIEmbedRC>` |
| [`portal/src/layouts/PowerBIEmbedLayout.astro`](../../portal/src/layouts/PowerBIEmbedLayout.astro) | Sub-bar + viewport rond de Island |
| [`portal/src/pages/embed/[id].astro`](../../portal/src/pages/embed/[id].astro) | Branch op `id === 'powerbi'` naar de Island-layout |
| [`portal/scripts/portal-backend.py`](../../portal/scripts/portal-backend.py) | `/api/portal/powerbi/reports` + `.../embed/{report_id}` |
| [`portal/nginx.conf`](../../portal/nginx.conf) | CSP — `app.powerbi.com` + `api.powerbi.com` toegevoegd |
| [`platform/15-portal/portal-backend.yaml`](../../platform/15-portal/portal-backend.yaml) | 4 secretKeyRef-envs voor de SP-creds |
| [`platform/15-portal/powerbi-embed-creds-template.yaml`](../../platform/15-portal/powerbi-embed-creds-template.yaml) | Template voor de `kubectl create secret`-stap |
| [`docs/adr/0008-entra-broker-via-keycloak.md`](../adr/0008-entra-broker-via-keycloak.md) | Architectuur-beslissing IdP-brokering |
| [`infrastructure/helm/keycloak/realm-uwv.json`](../../infrastructure/helm/keycloak/realm-uwv.json) | Entra als IdP in het `uwv` realm |
| [`tests/smoke/10-entra-broker.sh`](../../tests/smoke/10-entra-broker.sh) | Structuur-check van de realm-import |

---

## Bekende beperkingen / open issues

| Item | Status | Notitie |
|---|---|---|
| Pure User-Owns-Data | Niet geïmplementeerd | Vereist per-user PBI-licentie + MSAL.js flow apart van Keycloak. Hybride is bewust gekozen — zie architectuur §. |
| Token-refresh tijdens lange sessies | Werkt | React Island refresht 5min voor expiry zonder remount via `setAccessToken`. |
| Listing reports in de UI | Wel endpoint (`/api/portal/powerbi/reports`), nog geen dropdown | UC-12 is hardcoded als default. Volgende slice: dropdown + URL-param `?report=<id>`. |
| RLS per role / effectiveIdentity | Endpoint accepteert `{effectiveIdentity, roles, customData}` in de POST-body — **vereist eerst "fixed identity"-cloud-connection op de semantic model** | Zonder fixed identity geeft Power BI 403 "Creating embed token with effective identity is not supported for this datasource" voor Direct Lake. Configureer in Fabric UI: dataset → *Gateway and cloud connections* → fixed identity = de UC-11 SP. |
| ADR-0008 nummer-collision | Twee files met `0008-` prefix: `entra-broker-via-keycloak.md` (deze branch) + `self-service-data-access.md` (main) | Hernoemen bij merge naar `0011-entra-broker-via-keycloak.md`. |
| Power BI tenant-setting "SP can use APIs" | Handmatige Fabric Admin-actie | Niet automatiseerbaar via Terraform. |
| K8s Secret is een dev-pattern | Werkt | Productie: Azure Key Vault + Workload Identity (zie infrastructure/azure/README.md). |

---

## Lessons learned — wat tijdens k3d-verify scheef ging (en werd gefixt)

1. **`X-Auth-Request-Email` arriveert niet aan upstream.** oauth2-proxy met
   `set_xauthrequest=true` zet die header alleen op de `/oauth2/auth`-RESPONSE
   (voor nginx `auth_request`-flow); upstream POST/GET-requests krijgen
   `X-Forwarded-Email` (door `pass_user_headers=true`). De portal-backend
   las alleen `X-Auth-Request-Email` en gaf dus 401 op álle endpoints —
   inclusief de bestaande `/api/portal/recents`. **Fix**: backend
   `_email_from_request` valt nu door drie headers heen
   (`X-Auth-Request-Email` → `X-Forwarded-Email` → `X-Auth-Request-User`).
2. **`POST /reports/<id>/GenerateToken` mint V1-tokens; Direct Lake vereist V2.**
   Symptoom: `400 InvalidRequest "Embedding a DirectLake dataset is not
   supported with V1"`. **Fix**: V2-endpoint `POST /GenerateToken` met
   `{datasets[], reports[], targetWorkspaces[]}` body (Power BI Datasets API).
3. **`effectiveIdentity` zonder fixed-identity-connection wordt geweigerd voor
   Direct Lake.** Symptoom: `403 InvalidRequest "Creating embed token with
   effective identity is not supported for this datasource"`. **Werkrond**:
   backend stuurt `identities` alleen mee als de caller expliciet
   `effectiveIdentity=true` (of `roles`/`customData`) doorgeeft. Audit-only
   doorgifte van de user-email blijft via de log-regel werken. Volgende stap
   is de "fixed identity"-cloud-connection configureren op het semantic
   model (zie open issues hierboven), dan kan RLS terug aan via een POST-body
   met `effectiveIdentity: true`.
