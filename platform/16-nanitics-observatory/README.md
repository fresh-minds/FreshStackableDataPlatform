# 16 — Nanitics Observatory

Deploys the [Nanitics](https://github.com/nanitics/nanitics) Observatory
(an agent-trace viewer) on the UWV reference data platform, wired to an
**Azure AI Foundry** model endpoint as the LLM provider.

The Observatory is a developer-facing UI for inspecting agent runs —
LLM calls, tool invocations, span tree, capability panels (memory,
planning, HITL, evaluation). The Python app shipped here is a thin
glue layer: it serves the Observatory router under `/api/observatory/`
and exposes four agent-type endpoints so each Observatory view (ReAct,
ReWOO plan, Reflexion retry, LATS MCTS tree) has traces to render.

| Endpoint | Agent | What lights up in Observatory |
|---|---|---|
| `POST /run/react` | `ReActAgent` | Standard span tree, LLM calls, tool calls |
| `POST /run/rewoo` | `ReWOOAgent` | Plan view: `planning.plan.created`, `planning.step.updated`, parallel-step layout |
| `POST /run/reflexion` | `ReflexionAgent` | Evaluation panel: `evaluation.result` per attempt, reflection/retry loop |
| `POST /run/lats` | `LATSAgent` | MCTS tree view: `tree_search.node.*`, `mcts.iteration`, `mcts.backpropagation`, `tree_search.complete` |
| `POST /run` | (legacy alias for `/run/react`) | Same as `/run/react` |
| `GET /agents` | — | JSON index of the four agents and their default tasks |

> **Status: dev-only.** Per the SDK docs, Observatory v0.1.0 is not a
> production observability platform — no built-in auth, no
> multi-tenancy, no retention, no credential scrubber. We rely on the
> existing nginx-ingress + cert-manager chain for TLS and treat the
> endpoint as trusted-network only. See
> [docs/guides/observatory-integration.md](https://github.com/nanitics/nanitics/blob/main/docs/guides/observatory-integration.md)
> in the SDK repo for production seams.

---

## Layout

```
platform/16-nanitics-observatory/
├── README.md                  ← this file
├── build-and-load.sh          ← build image + k3d import
├── kustomization.yaml         ← kustomize entry point
├── configmap.yaml             ← non-sensitive config (endpoint URL, model)
├── secret.yaml                ← Azure AI Foundry API key (placeholder!)
├── deployment.yaml            ← single-pod Deployment
├── service.yaml               ← ClusterIP :80 → :8001
├── ingress.yaml               ← nanitics.uwv-platform.local
└── app/
    ├── Dockerfile             ← Python 3.11 + nanitics[api] + uvicorn
    ├── app.py                 ← FastAPI + Observatory + ReAct demo
    ├── .gitignore             ← excludes the synced UI bundle
    └── observatory-ui/        ← (synced at build time, gitignored)
```

---

## One-time setup

### 1. Provision an Azure AI Foundry model

In the Azure portal, create or pick an **Azure AI Foundry** project,
deploy a chat model (e.g., `gpt-4o-mini`), and grab two values:

- **Endpoint URL** — looks like
  `https://<your-resource>.services.ai.azure.com/openai/v1`
  (Foundry's OpenAI-compatible v1 surface).
- **API key** — from the deployment's keys & endpoint page.

> **If you only have an old-style Azure OpenAI deployment**
> (URL contains `/openai/deployments/<name>/...`), Nanitics' OpenAI
> client cannot call it directly. See [Variant: deployment-style Azure
> OpenAI via LiteLLM](#variant-deployment-style-azure-openai-via-litellm)
> below.

### 2. Add the hostname to your hosts file

```sh
echo "127.0.0.1 nanitics.uwv-platform.local" | sudo tee -a /etc/hosts
```

> **Note on the port:** the k3d serverlb maps `host:8080 → cluster:80`
> and `host:8443 → cluster:443`. All UWV ingress URLs are reached at
> `:8443`, not `:443`. If you see a connection refused / hanging
> browser, that's why. The portal at `platform.uwv-platform.local`
> behaves the same way — same `:8443` quirk.

### 3. Set the endpoint in the ConfigMap and the API key as a Secret

Endpoint goes in `configmap.yaml` (it's an identifier, not a credential):

```sh
$EDITOR configmap.yaml   # set AZURE_AI_FOUNDRY_ENDPOINT and LLM_MODEL
```

The `AZURE_AI_FOUNDRY_ENDPOINT` should end at `/openai/v1` (strip any
`/responses` or `/chat/completions` suffix the portal showed you — the
SDK appends the operation path itself). `LLM_MODEL` must match a
deployment name in your project.

> **Find your deployment name** by probing the endpoint with curl:
> ```sh
> for m in gpt-4o gpt-4o-mini gpt-4 gpt-5 gpt-5-mini; do
>   echo -n "$m: "
>   curl -s -o /dev/null -w "%{http_code}\n" \
>     -X POST "https://<your-resource>.services.ai.azure.com/api/projects/proj-default/openai/v1/chat/completions" \
>     -H "Authorization: Bearer <your-key>" \
>     -H "Content-Type: application/json" \
>     --data "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}"
> done
> ```
> 200 = deployment exists, 404 `DeploymentNotFound` = it doesn't.

API key goes into a Kubernetes Secret created **out-of-band** — never
written to disk:

```sh
kubectl -n uwv-platform create secret generic nanitics-azure-foundry \
  --from-literal=AZURE_AI_FOUNDRY_API_KEY='<paste-your-key>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

> **Why not in `secret.yaml`?** The committed `secret.yaml` exists only
> as a *template* showing the expected shape. It is **deliberately
> excluded from `kustomization.yaml`** — if it were a managed resource,
> every `kubectl apply -k .` would overwrite the real key with the
> placeholder. (We learned that the hard way during initial deploy.)
> For prod, replace `kubectl create secret` with External Secrets /
> Vault / a Workload Identity binding.

### 4. Make sure the dist-embed UI bundle exists

The build script copies `<nanitics-repo>/observatory/dist-embed` into
the build context. If it's stale or missing:

```sh
cd /Users/karelgoense/Documents/programming/sandbox/nanitics
just observatory-build
```

(Requires Node.js. The bundle is already committed in this repo for
convenience — usually you can skip this.)

---

## Deploy

```sh
# From repo root.
cd platform/16-nanitics-observatory

# Build the image and import it into the running k3d cluster.
./build-and-load.sh

# Apply the Kubernetes manifests (does NOT touch the Secret — see step 3 above).
kubectl apply -k .

# Watch the pod come up.
kubectl -n uwv-platform get pods -l app.kubernetes.io/component=nanitics-observatory -w
```

Then open the UI:

- <https://nanitics.uwv-platform.local:8443/api/observatory/>

The first time you'll see an empty run list. Trigger one run per agent
type so every Observatory view has traces to render:

```sh
curl -k -X POST https://nanitics.uwv-platform.local:8443/run/react \
  -H 'Content-Type: application/json' \
  -d '{"task":"Greet the UWV team in Dutch and describe the platform."}'

curl -k -X POST https://nanitics.uwv-platform.local:8443/run/rewoo \
  -H 'Content-Type: application/json' \
  -d '{"task":"Search for data lakehouse and data warehouse, summarize each, then compare in one sentence."}'

curl -k -X POST https://nanitics.uwv-platform.local:8443/run/reflexion \
  -H 'Content-Type: application/json' \
  -d '{"task":"Describe the UWV platform storage layer in at least 80 characters."}'

curl -k -X POST https://nanitics.uwv-platform.local:8443/run/lats \
  -H 'Content-Type: application/json' \
  -d '{"task":"Find the best tool to introspect the UWV platform layout. Finish with DONE."}'
```

Each call returns `{"run_id": "...", "agent_type": "...", "result": "..."}`.
Refresh the Observatory UI — the four runs appear in the run list with
distinct event signatures. Click each to compare:

- **ReAct** trace: linear span tree, one LLM call → tool → LLM call → done.
- **ReWOO** trace: plan-creation event, parallel step execution, only 2 LLM calls regardless of step count.
- **Reflexion** trace: at least one `evaluation.result`; if the first attempt fails the substantive-output check, you'll also see a `reflection.generated` event and a second attempt.
- **LATS** trace: a tree of `tree_search.node.created` / `tree_search.node.evaluated` events, `mcts.iteration` and `mcts.backpropagation` events tracking the search, and a final `tree_search.complete` summary.

---

## Switching to a real LLM vs. mock

The pod ships configured for `LLM_PROVIDER=azure-foundry`. To smoke-test
without burning Azure credits, override at deploy time:

```sh
kubectl -n uwv-platform set env deploy/nanitics-observatory LLM_PROVIDER=mock
```

The mock provider is a scripted two-turn ReAct response — useful for
verifying the trace pipeline works before wiring real keys.

To switch back:

```sh
kubectl -n uwv-platform set env deploy/nanitics-observatory LLM_PROVIDER=azure-foundry
```

---

## Day-2 ops

| Action | Command |
|---|---|
| Tail logs | `kubectl -n uwv-platform logs -f deploy/nanitics-observatory` |
| Restart after secret change | `kubectl -n uwv-platform rollout restart deploy/nanitics-observatory` |
| Port-forward (if ingress is broken) | `kubectl -n uwv-platform port-forward svc/nanitics-observatory 8001:80` then visit <http://localhost:8001/api/observatory/> |
| Health check | `curl -k https://nanitics.uwv-platform.local:8443/health` |
| Tear down | `kubectl delete -k .` |

---

## How it fits the platform

```
                  Browser                      curl / portal
                     │                              │
                     ▼                              ▼
            ┌──────────────────────────────────────────────┐
            │        nginx-ingress (cert-manager TLS)      │
            └──────────────────────────────────────────────┘
                                  │
                                  ▼
            ┌──────────────────────────────────────────────┐
            │  nanitics-observatory pod (uwv-platform ns)  │
            │  ┌────────────────────────────────────────┐  │
            │  │ FastAPI                                │  │
            │  │  ├─ /api/observatory/  (React bundle)  │  │
            │  │  ├─ /api/observatory/runs/...  (REST)  │  │
            │  │  ├─ /api/observatory/runs/{id}/stream  │  │
            │  │  │   (SSE — live trace updates)        │  │
            │  │  ├─ /run     → ReActAgent demo         │  │
            │  │  └─ /health                            │  │
            │  └────────────────────────────────────────┘  │
            │           │                                  │
            │           ▼                                  │
            │     OpenAILLMClient(base_url=<foundry>)      │
            └──────────────────────────────────────────────┘
                          │ HTTPS
                          ▼
            ┌──────────────────────────────────────────────┐
            │   Azure AI Foundry (/openai/v1/...)          │
            └──────────────────────────────────────────────┘
```

The `TracedExecutor` writes events to an in-memory
`PersistentTraceStore`. For durable storage across pod restarts, swap
in `PostgresTraceStore` (a separate Postgres deployment is needed; see
[Adding durable trace storage](#adding-durable-trace-storage) below).

---

## Customising the demo agents

`app/app.py` currently exposes five toy tools (`greet`,
`describe_platform`, `search`, `summarize`, `analyze`) wired into four
agent types. To make this useful for your platform, replace the toy
tools with ones that call the actual services:

```python
@tool("query_trino", "Run a read-only SQL query against the data warehouse.")
async def query_trino(sql: str) -> str:
    # connect to trino-coordinator.uwv-data:8080 internally
    ...

@tool("trigger_airflow_dag", "Trigger an Airflow DAG by id.")
async def trigger_airflow_dag(dag_id: str, conf: dict) -> str:
    # call airflow.uwv-platform internally
    ...
```

Then add them to the `ReActAgent(tools=[...])` list in `app.py`.

> **Wrap destructive tools with `ApprovalGate`.** See
> [`examples/hitl/approval_gate.py`](https://github.com/nanitics/nanitics/blob/main/examples/hitl/approval_gate.py)
> in the SDK repo. You don't want an agent dropping a Hive table.

---

## Variant: deployment-style Azure OpenAI via LiteLLM

If your endpoint shape is
`https://<resource>.openai.azure.com/openai/deployments/<deployment>/chat/completions?api-version=...`,
the OpenAI Python SDK can't call it directly. Two options:

1. **Migrate to a Foundry "v1" endpoint** (recommended; same models,
   OpenAI-compatible URL).
2. **Use LiteLLM** as a translator. Add `nanitics[litellm]` to the
   Dockerfile and switch `app.py` to:

   ```python
   from nanitics import LiteLLMClient
   client = LiteLLMClient(model="azure/<deployment-name>")
   # set env vars: AZURE_API_KEY, AZURE_API_BASE, AZURE_API_VERSION
   ```

   The ConfigMap/Secret keys change to `AZURE_API_*`. LiteLLM handles
   the deployment-style URL transparently.

---

## Adding durable trace storage

The default `InMemoryPersistentTraceStore` loses everything on pod
restart. To upgrade:

1. Deploy a small Postgres in `uwv-platform` (or reuse an existing
   one — check what `05-hive-metastore` already runs).
2. Install the `nanitics[postgres]` extra in the Dockerfile.
3. In `app.py`, replace:
   ```python
   from nanitics import PostgresTraceStore
   store = PostgresTraceStore(dsn=os.environ["TRACE_DB_DSN"])
   await store.bootstrap_schema()
   ```
4. Add the DSN to the ConfigMap (host) and the password to the Secret.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `ERR_CERT_AUTHORITY_INVALID` in browser | cert-manager hasn't issued the cert yet. Check `kubectl -n uwv-platform get certificate nanitics-observatory-tls`. |
| `502 Bad Gateway` | Pod not ready. `kubectl logs` it; check the readiness probe at `/health`. |
| `/run` returns 500 with `LLMProviderError: 404 DeploymentNotFound` | `LLM_MODEL` doesn't match a deployment in your Foundry project. Probe with the curl loop in step 3 to find a working name. |
| `/run` returns 500 with `LLMProviderError: 401 invalid subscription key` | Either the secret is missing/wrong, OR somebody re-applied the placeholder via kustomize. Run the `kubectl create secret` from step 3 again. |
| UI shows fallback page instead of React app | `observatory-ui/` wasn't synced. Re-run `./build-and-load.sh`. |
| Run list is empty after `/run` succeeded | Browser cached an old page; hard-refresh. SSE stream and run list both proxy through the same ingress. |

---

## Security notes

- The Observatory UI has **no built-in auth**. The ingress is
  reachable from anything that can resolve `nanitics.uwv-platform.local`
  — fine on a developer laptop, not fine in shared environments.
  For a shared cluster, put it behind the same `oauth2-proxy` sidecar
  pattern as `15-portal/`.
- Tool inputs/outputs are recorded verbatim in the trace store. If
  you add tools that touch PII or secrets, implement a `RedactionHook`
  (see SDK observability guide) before exposing the UI.
- The Azure key sits in a vanilla K8s `Secret` — base64, not
  encrypted at rest unless you've configured KMS encryption on the
  k3d datastore. Use Vault/External Secrets for anything beyond local
  dev.
