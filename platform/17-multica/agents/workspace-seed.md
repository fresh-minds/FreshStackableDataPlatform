# Workspace & label seeding

Multica filters and routes on labels, and the two-gate model depends on a few
of them existing in each workspace. Seed these **once per workspace**
(UI: Workspace → Labels, or the `multica` CLI). This extends the labels the
nanitics watcher already requires (`watcher-filed`, `severity:*`, `area:*`,
`approved`).

## Workspaces

| Workspace | Purpose | Filed into by |
|---|---|---|
| `platform-ops` | platform health, infra, governance, compliance | watcher, ops/governance observers, Tier 1 & 3 agents |
| `data-products` | dbt models, marts, dashboards, UC data work | data observers, Tier 2 agents |

> The nanitics observers file into a single `MULTICA_WORKSPACE`
> (default `platform-ops`, in `platform/19-nanitics-observatory/configmap.yaml`).
> Coding agents can still live in `data-products` — assignment is by **user
> membership**, not workspace tier, so a task filed in `platform-ops` can be
> assigned to any agent user that belongs to that workspace.

## Labels (create in every workspace)

**Gate / lifecycle**

- `approved` — **gate 1**. A human adds this; the Multica daemon only runs
  approved tasks. Never add it programmatically.
- `agent-pr` — task is expected to produce a PR.
- `autopilot` — task was created by an autopilot.
- `watcher-filed` — filed by a nanitics watcher/observer.

**Severity** (observers): `severity:info` · `severity:warning` · `severity:critical`

**Risk** (review intensity): `risk:low` · `risk:medium` · `risk:high`

**AI Act**: `ai-act:high-risk` — UC-02, UC-03, and anything Annex III.

**Area** (workload / concern):
`area:trino` · `area:spark` · `area:kafka` · `area:jupyter` · `area:k8s` ·
`area:dbt` · `area:opa` · `area:governance` · `area:compliance` ·
`area:finops` · `area:architecture` · `area:docs` · `area:helm` ·
`area:retention` · `area:sensitive` · `area:tests` · `area:portal` ·
`area:security`

**Use case**: `uc:01` … `uc:12`

## Coding-agent users

Create a Multica user per coding runtime you use (e.g. `claude-code@…`,
`codex@…`), add it to both workspaces, and generate its daemon token. At
gate 1 you assign the approved task to one of these users; its laptop daemon
claims the task and opens the PR. The nanitics observers use a separate
`platform-watcher@…` user (see the nanitics README) — keep it distinct so
"who filed" and "who fixes" never collapse into one identity.
