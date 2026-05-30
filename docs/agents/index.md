# AI agents on the platform

The platform runs AI agents in **three lanes**. They share one principle —
*agents propose, humans dispose*: every change to `main` passes **two human
gates**, and the in-cluster agents can only ever read and file tasks, never
mutate the platform.

## The three lanes

| Lane | Component | Audience | What it does |
|---|---|---|---|
| **Observe** | [`platform/19-nanitics-observatory`](../../platform/19-nanitics-observatory/README.md) | engineers / stewards | in-cluster agents that read signals and **file Multica tasks** |
| **Build** | [`platform/17-multica`](../../platform/17-multica/agents/README.md) | engineers | coding agents that **fulfil tasks by opening PRs** |
| **Ask** | [`platform/21-nao`](../../platform/21-nao/README.md) | business / data users | natural-language → SQL analytics over Trino |

> "What's our gold-zone WIA payout rate by month?" → **nao**.
> "WIA funnel conversion dropped last month." → an **observer** files a task.
> "Build the dbt model + fix that." → a **Multica** coding agent opens a PR.

## The loop

```
   OBSERVE                         BUILD
   (Nanitics, in-cluster)          (Multica, dev laptops + GitHub)

   read-only signals               ┌── gate 1 (you) ──┐   ┌── gate 2 (you) ──┐
   Trino · OpenMetadata            ▼                  ▼   ▼                  ▼
   Prometheus · logs · events  →  task ──approve+──► coding ──opens──► PR ──review──► merge
        │                         on the   assign    agent             (draft         to main
        └── file task (no ───────►backlog            runs              if CI red)
            `approved` label)
```

Two gates, by construction: **(1)** a human adds the `approved` label and
assigns the task; **(2)** a human reviews and merges the PR. No auto-merge
exists anywhere. The observers' only write capability is *filing a task* — no
Trino writes, no Kubernetes writes.

## Observe — Nanitics agents

In-cluster ReAct agents (`platform/19-nanitics-observatory/app/`). Each files
at most one Multica task per run, without `approved`.

| Agent | UC | Watches |
|---|---|---|
| `watcher` | — | platform health (Alertmanager, Prometheus, OpenSearch, K8s events) |
| `funnel-anomaly` | UC-01 | WIA funnel stage-conversion drops |
| `dq-sentinel` | UC-07 | OpenMetadata DQ failures + profiler drift |
| `cost-anomaly` | UC-12 | FOCUS cost regressions |
| `journey-miner` | UC-11 | klantreis cohort phase patterns |
| `damage-forecaster` | UC-06 | schadelast vs a simple expectation |
| `access-triage` | — | routing recommendation for an access request |

## Build — Multica coding agents

Version-controlled briefings in
[`platform/17-multica/agents/`](../../platform/17-multica/agents/README.md).
Each opens a PR on `fresh-minds/FreshStackableDataPlatform`.

- **Tier 1:** `compliance-mapping-auditor`, `dbt-test-generator`,
  `opa-policy-author`, `openmetadata-description-filler`
- **Tier 2 (UC):** `dpia-iama-drafter` (UC-02), `bias-fairness-reviewer` (UC-03),
  `client-360-view-builder` (UC-05), `intervention-effectiveness-analyst` (UC-09),
  `canonical-schema-drafter` (UC-10)
- **Tier 3 (platform care):** `adr-drafter`, `mode-drift-detector`,
  `smoke-test-maintainer`, `doc-code-drift-watcher`, `helm-values-pruner`,
  `retention-bewaartermijn-enforcer`, `pseudonymization-pr-bot`,
  `use-case-scaffolder`

## Ask — nao + doc-rag

Two read-only Q&A surfaces:

- **`nao`** (`platform/21-nao`) turns business questions into Trino SQL and
  runs them under the caller's identity, so OPA row/column policies still
  apply — it answers from *data*.
- **`doc-rag`** (a Nanitics agent) answers from *documentation* — architecture,
  ADRs, use-cases, compliance — with semantic search (pgvector embeddings over
  the docs corpus, with a lexical fallback) and cites the source files.

Both answer; neither changes the platform.

## Governance & AI Act

- **High-risk (AI Act Annex III):** UC-02 (Wajong) and UC-03 (WW risk). No
  agent here ships an autonomous decision model — the `dpia-iama-drafter` and
  `bias-fairness-reviewer` produce **artifacts and controls for human
  sign-off** (art. 14 human oversight).
- **Sensitive vault:** only `pseudonymization-pr-bot` may reference
  `sensitive.*`, and only to *mask/pseudonymize* — never to read values.
  Observers never extract row-level data or PII; they report counts and rates.
- **Doelbinding by design:** access changes go through `opa-policy-author`
  with an explicit purpose, behind both gates.
- See [`compliance-mapping.md`](../compliance-mapping.md); the
  `compliance-mapping-auditor` keeps it current.

## Getting started (recommended order)

1. **Wire GitHub** — follow "Connecting Multica to GitHub" in the
   [agents README](../../platform/17-multica/agents/README.md): install the
   App, protect `main`, confirm `.github/CODEOWNERS`.
2. **Seed** workspaces + labels —
   [`workspace-seed.md`](../../platform/17-multica/agents/workspace-seed.md).
3. **Prove the loop, low-risk** — enable `compliance-mapping-auditor` and
   `openmetadata-description-filler` (markdown/YAML only).
4. **Add value** — `dbt-test-generator`, `opa-policy-author`.
5. **Turn on observers** — un-suspend one CronJob at a time after checking its
   manual run (see the nanitics README); start with `dq-sentinel` or
   `cost-anomaly`.
6. **Tackle the hard ones** — UC-12 cost, then UC-02 DPIA/IAMA with DPO review.
