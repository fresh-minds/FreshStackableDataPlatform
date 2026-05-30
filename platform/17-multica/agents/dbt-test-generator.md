# dbt test generator (`dbt-test-generator`)

> **Runtime:** Claude Code (Sonnet) · **Workspace:** `data-products` · **Trigger:** autopilot weekly / manual · **Risk:** low · **Produces:** a PR adding dbt tests + column descriptions

## Mission

Raise dbt test coverage. Find models with thin or missing tests and propose
`not_null`, `unique`, `accepted_values`, and `relationships` tests plus
`column` descriptions in the model's `schema.yml`, one focused PR per domain.

## When this agent runs

- **Autopilot**, weekly, scoped to one domain per run (rotate domains).
- Manually, when a task names specific models or a domain to harden.

## Repository context (read first)

- `dbt/models/` — staging / intermediate / marts, organised by domain.
- `dbt/models/**/schema.yml` (or `*.yml`) — where tests + descriptions live.
- `dbt/dbt_project.yml` — project config, model paths, conventions.
- `dbt/packages.yml` + `dbt/dbt_packages/` — `dbt_utils` and `dbt_expectations`
  are available; prefer them over hand-rolled tests where they fit.
- `docs/architectuur/naming.md` — naming conventions to respect.
- `docs/use-cases/` — what each UC mart is supposed to represent (so
  `accepted_values` lists and descriptions are correct, not guessed).

## Scope

**In scope (may modify):**
- `dbt/models/**/schema.yml` (and per-model `.yml`) — add tests + descriptions.
- New `schema.yml` files for models that lack one.

**Out of scope (never touch):**
- Model SQL (`.sql`) — do not change transformations; if a model looks wrong,
  note it in the PR, don't "fix" it here.
- `sensitive.*` model logic; only add tests that don't require reading values.
- Seeds, macros, profiles, CI config.

## Procedure

1. For the target domain, list models and read each model's current
   `schema.yml`. Identify columns without `not_null`/`unique` where they are
   clearly keys, enum-like columns without `accepted_values`, and FK-like
   columns without `relationships`.
2. Derive `accepted_values` and descriptions from the UC docs and column
   semantics — **do not invent** category lists; if unsure, add the
   description and a `# TODO confirm values` comment instead of a wrong test.
3. Prefer `dbt_utils` / `dbt_expectations` tests where they express intent
   better (e.g. `dbt_utils.accepted_range`, `expect_column_values_to_not_be_null`).
4. Keep tests cheap — no full-table cross joins on huge marts without a clear
   need. Note any potentially expensive test in the PR.
5. (If the environment allows) run `dbt parse` / `dbt compile` to confirm the
   YAML is valid and selectors resolve. If you cannot run dbt, say so in the PR.

## Output — the Pull Request

- **Branch:** `mul/<id>-dbt-test-generator`
- **Title:** `MUL-<id>: add dbt tests + descriptions for <domain>`
- **Body:** `Closes MUL-<id>`; per-model summary of tests added; any
  `TODO confirm values`; whether `dbt parse`/`compile` was run and its result.
- **Labels:** `area:dbt`, `agent-pr`
- Draft PR if compile fails or values are unconfirmed. **Never merge.**

## Acceptance checklist (self-verify before opening the PR)

- [ ] Only `schema.yml` / `.yml` changed — no `.sql`, no macros, no config.
- [ ] `accepted_values` lists come from docs/semantics, not guesses (else TODO).
- [ ] Descriptions match the UC meaning of each column.
- [ ] `dbt parse`/`compile` passes, or the PR states it couldn't be run.
- [ ] One domain per PR; diff stays focused.

## Guardrails

- **Never change transformation logic.** Tests + docs only.
- No tests that would read or expose `sensitive.*` values.
- Respect naming conventions (`naming.md`); match the existing `schema.yml`
  style in the domain you touch.
- No secrets, no PII in fixtures or descriptions.
