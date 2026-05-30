# 21 — nao

Deploys [nao](https://github.com/getnao/nao) — an open-source **analytics agent** —
on the UWV reference platform. nao turns natural-language questions into
SQL against the platform's Trino warehouse and shows the result in a
chat UI.

> **Status: working on k3d** (exploratory; not yet wired into
> `make deploy-platform`). Runs on a patch-on-top fork image
> (`karelgo/nao:trino-tls-jwt-857`, k3d-imported) that layers two changes
> on the upstream OSS release: the TLS fix from
> [PR #859](https://github.com/getnao/nao/pull/859) plus a `jwt_token` /
> `jwt_token_file` field on the Trino connector (for OAuth2 bearer auth —
> not yet upstreamed). The agent chats via Azure AI Foundry (gpt-4o) and
> queries the gold/silver lakehouse through Trino under a read-only OPA
> identity. When both patches land upstream and a release is tagged, swap
> the `images:` block back to `getnao/nao:<tag>` and drop `nao-interim/`.

---

## Trino auth chain (the load-bearing part)

Trino on this cluster is **OAuth2-only** — no basic/static auth, despite the
stale comment in `platform/09-trino/trinocluster.yaml`. nao reaches it like
this:

```
init + refresh sidecar
  └─ POST Keycloak /token (client_credentials, client=nao-trino, secret)
       → JWT with preferred_username=nao-agent   (hardcoded mapper)
       → /var/run/nao/trino-token   (Memory emptyDir, rotated every 30m)

nao FastAPI /execute_sql  (per query: reload config + new connection)
  └─ TrinoConfig.connect() reads jwt_token_file fresh
       → ibis.trino.connect(http_scheme=https, auth=JWTAuthentication(token),
                            user="nao-agent")  → sends Bearer + X-Trino-User
       → Trino OAuth2 authenticator: principal = nao-agent
       → OPA: user==nao-agent → read-only `nao_agent` role
            (silver+gold, wildcard purpose, NO PII/medical/sensitive, NO writes)
```

The `nao_agent` role + binding live in `opa-policies-src/` (role in
`data/uwv_role_mappings.json`, principal binding in `trino/trino-base.rego`,
tests in `trino/trino-nao-agent_test.rego`). The `nao-trino` Keycloak client
lives in `infrastructure/helm/keycloak/realm-uwv.json`.

**Governance note — wildcard purpose.** `nao_agent` carries `purposes: ["*"]`
so the agent can read every use-case mart without declaring a per-query
purpose (it isn't doelbinding-aware). This is a deliberate trade-off: nao runs
under a standing analytical (sturingsinfo/beleid) mandate. The *hard* limits
still bite — read-only, no PII/medical/bankrekening columns (OPA column
masks), silver+gold only (no bronze/sensitive), and a distinct audit principal
separate from `nanitics-observer`.

---

## How this differs from `17-multica` and `19-nanitics-observatory`

Three agent-flavoured components on this platform, three different lanes:

|                | **17 — Multica**                          | **19 — Nanitics**                    | **21 — nao (this)**                      |
|----------------|-------------------------------------------|--------------------------------------|------------------------------------------|
| Lane           | Dev-loop / build-time                     | Runtime / inside-the-platform        | **Analytics loop / user-facing**         |
| What runs      | Postgres (pgvector) + Go backend + Next.js| FastAPI + Nanitics SDK               | Bun TS backend + Python FastAPI sidecar  |
| Where agents run | On developer laptops                   | In-cluster                           | In-cluster                               |
| Audience       | Engineers assigning tasks to coding agents| Engineers debugging agent traces     | **Business / data users asking questions** |
| Talks to       | Coding agents on laptops (JWT)            | Azure AI Foundry, Multica events     | LLM (Anthropic/OpenAI/…) + Trino         |

"What's our gold-zone WIA payout rate by month?" — nao.
"Write a dbt model that produces that table" — Multica (assigns to Claude Code).
"Why did the last agent run hang?" — Nanitics.

---

## Layout

```
platform/21-nao/
├── README.md                     ← this file
├── kustomization.yaml            ← resources + image pin + configMapGenerator
├── postgres.yaml                 ← vanilla Postgres 16 (better-auth + chat state)
├── configmap.yaml                ← non-secret env (BETTER_AUTH_URL, paths)
├── deployment.yaml               ← nao single-container, dual-process via supervisord
├── service.yaml                  ← ClusterIP :80 → :5005
├── configmap-oauth2-proxy.yaml   ← Keycloak gate config (k3d hosts)
├── oauth2-proxy.yaml             ← oauth2-proxy Deployment + Service
├── secret-oauth2-proxy.yaml      ← DEV-ONLY cookie+client secret
├── ingress.yaml                  ← nao.uwv-platform.local
├── secrets.template.yaml         ← documentation-only Secret template (gitignored
│                                   pattern; apply real values out-of-band)
└── context/                      ← mounted into the pod via configMapGenerator
    ├── nao_config.yaml           ← project schema, Trino connection, repos
    └── RULES.md                  ← agent constraints (lane separation, read-only, …)
```

Mode overlays under `platform-overlays/{aks,stackit}/21-nao/` patch only
the hostname, the cert-issuer, and the BETTER_AUTH_URL — same shape as
the `17-multica` overlays.

---

## First-time install (k3d)

```bash
# 1. Add the host alias (one-time)
echo "127.0.0.1 nao.uwv-platform.local" | sudo tee -a /etc/hosts

# 2. Provision required Secrets (NOT applied by kustomize on purpose,
#    see secrets.template.yaml comment for the rationale)
PG_PW=$(openssl rand -hex 24)
kubectl -n uwv-platform create secret generic nao-postgres \
  --from-literal=POSTGRES_PASSWORD="$PG_PW" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n uwv-platform create secret generic nao \
  --from-literal=BETTER_AUTH_SECRET="$(openssl rand -hex 32)" \
  --from-literal=DB_URI="postgres://nao:${PG_PW}@nao-postgres:5432/nao" \
  --from-literal=ANTHROPIC_API_KEY="<your-key>" \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. Add the 'nao' OIDC client to Keycloak realm 'uwv'
#    Client-ID = "nao", client-secret = matches secret-oauth2-proxy.yaml,
#    redirect URI = https://nao.uwv-platform.local:8443/oauth2/callback,
#    web-origin   = +
#    (For AKS/StackIT replace the host.)

# 4. Deploy
kubectl apply -k platform/21-nao/

# 5. Smoke
kubectl -n uwv-platform rollout status deployment/nao --timeout=180s
curl -k -I https://nao.uwv-platform.local:8443
```

First page load goes through Keycloak; once authenticated you land on
nao's first-run wizard. Pick Anthropic (or any provider) for the model,
confirm the Trino DB connection picked up from `nao_config.yaml`, and
set the Trino password (Phase 1 uses the `smoketest` static user from
[`platform/09-trino/trino-static-auth.yaml`](../09-trino/trino-static-auth.yaml)).

---

## Known gotchas

- **SQL execution on k3d works via the interim fork image.**
  `karelgo/nao:trino-tls-jwt-857` is a patch-on-top of `getnao/nao:latest`
  that ships the [PR #859](https://github.com/getnao/nao/pull/859)
  TLS-aware Trino connector **plus** `jwt_token`/`jwt_token_file` fields for
  OAuth2 bearer auth. The image is k3d-imported (`k3d image import …`); it is
  NOT on a public registry. AKS/StackIT overlays cannot use it as-is.
- **Token lifecycle.** The Keycloak `nao-trino` access token lifespan is set
  to 1h; the refresh sidecar rewrites the token file every 30m. Because
  `execute_sql` opens a fresh connection per query and the connector re-reads
  `jwt_token_file` each time, rotation is seamless — no nao restart needed.
- **AKS/StackIT still need an unblock.** Either wait for upstream to merge the
  TLS + JWT changes and tag a release, or push the patched image to a registry
  the managed clusters can reach. See `~/Documents/programming/sandbox/nao-interim/Dockerfile`
  for the build recipe (one COPY on top of upstream). The OPA role, Keycloak
  client, and manifests are already mode-agnostic.
- **`verify: false` on the Trino TLS.** The connector skips CA verification
  (in-cluster pod→svc). Mounting the platform internal CA bundle and setting
  `verify: /path/to/ca.crt` is a hardening follow-up.
- **OSS license = no native OIDC.** SAML/OIDC is enterprise-gated in
  nao. We use oauth2-proxy as edge SSO; inside nao every authenticated
  user shares one nao identity. For per-user OPA enforcement on Trino,
  upstream support for OIDC + Trino impersonation is needed.
- **arm64 Macs work.** The upstream image is published multi-arch
  (linux/amd64 + linux/arm64), so local k3d on Apple Silicon and
  AKS/StackIT amd64 nodes share the same digest.
- **Boxlite sandboxing is disabled in-cluster.** nao's image looks for
  `/dev/kvm` to run Boxlite (an inner code-execution sandbox). We do
  not mount kvm; nao falls back to in-process execution. Acceptable
  for analytics-only workloads.

---

## Resource cost

Roughly **0.5 vCPU / 1 GB RAM** request, ~2 vCPU / 2.5 GB limit, plus
**5 GB PVC** for Postgres. Cold-start ~60 s (Bun + Drizzle migrations).

## Related

- Spike notes: see the chat transcript on this branch — Trino connector
  verified at the source-code level, single-container supervisord layout
  verified by a local `docker run`.
- Lane comparison memo for Multica vs Nanitics:
  `docs/explorations/multica-vs-nanitics.md` (existing).
