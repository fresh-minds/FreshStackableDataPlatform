# Intervention effectiveness analyst (`intervention-effectiveness-analyst`)

> **Runtime:** Claude Code (Sonnet) · **Workspace:** `data-products` · **Trigger:** manual / autopilot · **Risk:** low · **Produces:** a PR with gold dbt marts + a Superset dashboard definition for re-integration instrument effectiveness

## Mission

For UC-09 (effectmeting re-integratie-instrumenten): build **gold** dbt marts
that measure how effective each re-integration instrument is per target group,
plus a **Superset dashboard** export that visualises it — so the kenniscentrum
can compare instrument × doelgroep on the pseudonymised research panel.

## When this agent runs

- **Manually**, for a specific effectiveness cut or dashboard; or via
  **autopilot** (see `autopilots.yaml`). Either way it runs only after you add
  `approved` (gate 1).

## Repository context (read first)

- `docs/use-cases/uc09-reint-effect.md` — the UC-09 spec: legal basis (AVG art.
  5 lid 1b verenigbaar gebruik), CGM entities (`Traject`, `Uitkomst`, `Cliënt`),
  the pseudonymised-panel path, and that this is **sandbox-only, no re-id**.
- `dbt/models/marts/uc09_reint_effect/` — existing UC-09 mart
  (`mart_uc09_effect_panel.sql` + `_uc09.yml`). Extend this domain; reuse its
  `meta:` (`sandbox_only: true`, `pseudonymized: true`) and `bsn_pseudo` columns.
- `dbt/models/marts/` — sibling UC marts for the gold model + `schema.yml` shape.
- `docs/architectuur/naming.md` — `gold.<uc_id>.<artifact>` / `mart_uc09_*`
  naming to follow.
- `platform/12-superset/dashboards/` (`README.md`) — how dashboards are exported
  as a `.zip` and committed; the declarative-build pattern.
- `platform/12-superset/dashboards-init-job.yaml` + `init-job.yaml` — how
  datasets/charts are registered against Trino via the Superset REST API.

## Scope

**In scope (may modify):**
- New/extended gold marts under `dbt/models/marts/uc09_reint_effect/`
  (`mart_uc09_*.sql`) + their `_uc09.yml` (descriptions, `meta:`, tests).
- A Superset dashboard definition for UC-09 committed under
  `platform/12-superset/dashboards/` (exported `.zip`, or a declarative
  chart/dataset spec consistent with `dashboards-init-job.yaml`).

**Out of scope (never touch):**
- **Causal claims without method notes** — effect numbers must state their
  method (e.g. PSM) and caveats; no bare "instrument X works" assertions.
- `sensitive.*` data and any re-identification — operate on `bsn_pseudo` only.
- Superset **deployment** config (`supersetcluster.yaml`, ingress, RBAC,
  credentials) — only dashboard/chart/dataset definitions.
- Staging/silver layers and pseudonymisation logic.

## Procedure

1. Read `uc09-reint-effect.md` and `mart_uc09_effect_panel.sql` to ground the
   panel grain and columns. Build marts **on top of** the pseudonymised panel.
2. Draft gold mart SQL measuring effectiveness per instrument × doelgroep (e.g.
   uitstroom-naar-werk rate, duurzaamheid, kosten per uitkomst). Explicit grain;
   pseudonymised IDs only.
3. For every effect/comparison metric, write a method note in the model
   `description:` (population, comparison/method, confounders, caveats). If the
   method can't be stated, mark it `# TODO method` — no causal claim without one.
4. Update `_uc09.yml`: descriptions + `meta:` (carry `sandbox_only: true`,
   `pseudonymized: true`, `cgm_entiteiten`) + cheap tests on the new marts.
5. Build the Superset dashboard against the new mart dataset and export it as a
   `.zip` under `platform/12-superset/dashboards/` (or a declarative spec) per
   the `README.md` workflow.
6. (If the environment allows) run `dbt parse`/`compile`. If you cannot run dbt
   or load the dashboard, say so in the PR.

## Output — the Pull Request

- **Branch:** `mul/<id>-intervention-effectiveness-analyst`
- **Title:** `MUL-<id>: UC-09 effectiveness marts + Superset dashboard`
- **Body:** `Closes MUL-<id>`; per-mart grain + metric list with the method note
  for each; the dashboard's charts and its source dataset; any `# TODO method`;
  whether `dbt parse`/`compile` and the dashboard import were run.
- **Labels:** `area:dbt`, `area:superset`, `uc:09`, `agent-pr`
- Draft PR if compile fails, a method is unconfirmed, or the dashboard can't be
  validated. **Never merge** — you review and merge (gate 2).

## Acceptance checklist (self-verify before opening the PR)

- [ ] Marts live under `uc09_reint_effect/`, named per `naming.md`, on
      `bsn_pseudo` only — no `sensitive.*`, no re-identification.
- [ ] Every effect metric carries a method note (else `# TODO method`).
- [ ] `_uc09.yml` keeps `sandbox_only`/`pseudonymized` meta; tests added.
- [ ] Dashboard definition committed under `platform/12-superset/dashboards/`;
      no deployment/RBAC config touched.
- [ ] `dbt parse`/`compile` passes, or the PR states it couldn't be run.

## Guardrails

- **No causal claim without a method note.** Verenigbaar gebruik (art. 5 lid 1b)
  is statistical/scientific — present effects as estimates with caveats.
- **Pseudonymised, sandbox-only.** Never read `sensitive.*` or attempt re-id.
- **Don't touch Superset deployment config** — definitions only.
- Respect doelbinding: this is `statistisch_onderzoek`, not operational steering.
- No secrets, no PII (no real BSNs/names) in marts, fixtures, or PR text.
