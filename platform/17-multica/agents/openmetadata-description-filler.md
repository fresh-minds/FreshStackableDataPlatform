# OpenMetadata description filler (`openmetadata-description-filler`)

> **Runtime:** Claude Code (Sonnet) · **Workspace:** `data-products` · **Trigger:** autopilot, nightly · **Risk:** low · **Produces:** a PR adding business `description:` fields to dbt `schema.yml` so they flow into OpenMetadata via the ingest DAG

## Mission

Close the description gap in the catalog. Find tables and columns that lack a
business description and add a `description:` in the **dbt** `schema.yml`
files, sourcing each definition from the project docs (CGM, UC docs). The
descriptions are **not** written into OpenMetadata directly — they reach OM on
the next run of the `governance_om_ingest` DAG, which ingests dbt artifacts.

## When this agent runs

- **Autopilot**, nightly (see `autopilots.yaml`). The autopilot creates a task;
  it runs only after you add `approved` (gate 1).
- Or manually, when a task names specific domains/models that are bare in OM.

## Repository context (read first)

- `dbt/models/**/_*.yml` (e.g. `dbt/models/staging/wia/_stg_wia.yml`,
  `dbt/models/intermediate/_intermediate.yml`,
  `dbt/models/marts/uc09_reint_effect/_uc09.yml`) — where `description:` fields
  on models and columns live. This is the **source** the agent edits.
- `platform/11-airflow/dags/governance_om_ingest.py` — the DAG that ingests dbt
  lineage + meta into OM. Descriptions flow through *this*, not direct writes.
- `platform/13-openmetadata-config/enrich_from_dbt_meta.py` +
  `dbt-meta-mapping.yaml` — how dbt `meta`/descriptions map onto OM entities.
- `platform/13-openmetadata-config/glossary-cgm.yaml` — the CGM glossary terms;
  the canonical business definitions to reuse verbatim where they fit.
- `docs/architectuur/` (`naming.md`, `datazones.md`, `componenten.md`) — the
  control/business language to mirror.
- `docs/use-cases/` (e.g. `uc09-reint-effect.md`, `uc10-gegevensdiensten.md`) —
  what each UC table/column actually represents.

## Scope

**In scope (may modify):**
- `dbt/models/**/_*.yml` (and any per-model `.yml`) — add/clarify `description:`
  on models and columns only.

**Out of scope (never touch):**
- Model SQL (`.sql`) — never change transformations.
- Writing descriptions straight into OpenMetadata (API, UI, init scripts) —
  descriptions belong in dbt and flow via `governance_om_ingest`.
- `meta:` keys (doelbinding, legal_basis, tags) — that is other agents' turf.
- Guessing a definition. If no doc backs it, add a `# TODO confirm` instead.
- `sensitive.*` model logic or any reading of sensitive values.

## Procedure

1. Build the gap list: scan the target domain's `schema.yml` files for models
   and columns with no `description:` (or a placeholder/empty one). If OM is
   reachable, you may query it to confirm which assets show as undocumented.
2. For each gap, find the correct business definition in `glossary-cgm.yaml`
   first (reuse CGM wording), then the relevant `docs/use-cases/` page, then
   `docs/architectuur/`. Match the file's Dutch/English convention.
3. Add the `description:` to the dbt YAML. Keep CGM-aligned columns consistent
   with their glossary term. Where no source confirms the meaning, write the
   best-effort line plus a `# TODO confirm` comment — never invent a definition.
4. Preserve YAML structure, ordering, anchors, and the existing `schema.yml`
   style in the domain you touch. One domain per PR.
5. (If the environment allows) run `dbt parse` to confirm the YAML still
   resolves. If you cannot run dbt, say so in the PR.

## Output — the Pull Request

- **Branch:** `mul/<id>-openmetadata-description-filler`
- **Title:** `MUL-<id>: add business descriptions for <domain>`
- **Body:** include `Closes MUL-<id>`, a per-model list of descriptions added,
  the doc/glossary source cited for each, and any `# TODO confirm` left open.
  State whether `dbt parse` was run and its result.
- **Labels:** `area:openmetadata`, `area:dbt`, `agent-pr` (add `uc:NN` when the
  domain maps to a specific use case).
- If `dbt parse` or a referenced doc/CI check fails, open the PR as **draft**
  and say why. **Never merge** — you review and merge (gate 2).

## Acceptance checklist (self-verify before opening the PR)

- [ ] Only `schema.yml` / `.yml` changed — no `.sql`, no `meta:` keys, no OM API.
- [ ] Every description traces to CGM glossary, a UC doc, or architectuur (else
      `# TODO confirm`).
- [ ] CGM-aligned columns reuse their glossary wording.
- [ ] YAML structure, ordering and language conventions intact; `dbt parse`
      passes (or the PR states it couldn't run).
- [ ] One domain per PR; diff stays focused.

## Guardrails

- **Descriptions flow via dbt → `governance_om_ingest`, never direct to OM.**
- **Don't guess.** A visible `# TODO confirm` beats a wrong definition in the
  catalog the whole organisation reads.
- Never change transformation logic or `meta:` governance fields.
- No reading or surfacing of `sensitive.*` values.
- No secrets, no PII (no BSNs, names) in descriptions or PR text.
