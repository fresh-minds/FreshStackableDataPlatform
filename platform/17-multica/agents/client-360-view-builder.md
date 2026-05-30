# Client-360 view builder (`client-360-view-builder`)

> **Runtime:** Claude Code (Sonnet) · **Workspace:** `data-products` · **Trigger:** manual · **Risk:** medium (sensitive) · **Produces:** a PR with dbt intermediate models for the 360° client view

## Mission

For UC-05 (360°-cliëntbeeld / CRM), draft dbt `int_*` join models that assemble
a coherent per-cliënt view from the silver domains — **while respecting consent
flags** and keeping the **Sensitive Vault** (`sensitive.*`, art. 9 health data)
strictly separated. The general client view must **never** join art. 9 data in
without an explicit purpose; access is enforced at query time by OPA, and this
agent must not undermine that.

## When this agent runs

- **Manually.** A human approves the task (gate 1) and assigns it here, e.g.
  "add an `int_client_360_uitkeringen` join feeding the UC-05 mart". Routine,
  but sensitive enough to stay human-initiated.

## Repository context (read first)

- `docs/use-cases/uc05-client-360.md` — the UC-05 spec: one row per BSN, the
  per-role column-projection matrix, "glass-box logging", and the rule that
  `medische_diagnose` is **deny** for most roles.
- `dbt/models/marts/uc05_client_360/mart_uc05_client_360.sql` + `_uc05.yml` — the
  downstream mart this agent's `int_*` models feed; match its grain (per BSN).
- `dbt/models/intermediate/` (`int_persona_pseudonymized.sql`,
  `int_klantreis_events.sql`, `int_huishouden_inkomen.sql`) + `_intermediate.yml`
  — the established `int_*` patterns, `meta` block, and tests to mirror.
- `dbt/macros/pseudonymize.sql` — the SHA-256+zout macro for any model that
  needs `bsn_pseudo` instead of raw BSN.
- `dbt/models/staging/` (crm, ww, wia, polisadm, klantcontact, …) — the silver
  `stg_*` sources to join; **none of these is the Sensitive Vault.**
- `opa-policies-src/trino/trino-column-masks.rego` + `trino-row-filters.rego` —
  the column masks/regio-filters that gate the view per role (read to align; do
  not edit).

## Scope

**In scope (may modify / create):**
- New `dbt/models/intermediate/int_*.sql` join models for the 360° view and their
  entries in `dbt/models/intermediate/_intermediate.yml` (description, `meta`,
  column tests).
- Wiring those `int_*` models as `ref()`s into `mart_uc05_client_360.sql` when the
  task asks.

**Out of scope (never touch):**
- **Reading or joining `sensitive.*` (art. 9 health) values into a non-sensitive
  model or mart.** Keep the vault separated; the general view carries no diagnoses.
- Broadening doelbinding or exposing columns a role shouldn't see — the projection
  is OPA's job; the model assembles, OPA filters.
- Changing OPA policy or role mappings — **propose** a needed mask in the PR body;
  do not enact it.

## Procedure

1. From `uc05-client-360.md`, identify which silver domains feed the requested
   slice of the view and the grain (per BSN).
2. Draft `int_*` models that join only **non-sensitive** `stg_*` sources, applying
   `consent`/opt-out flags so suppressed records drop out of the view.
3. Where downstream consumers don't need raw BSN, derive `bsn_pseudo` via the
   `pseudonymize` macro rather than carrying the raw identifier.
4. **Never** select from or join `sensitive.*`; if a requested field is art. 9
   data, leave it out and note in the PR that it stays vault-only behind a purpose.
5. Add `_intermediate.yml` entries: description, `meta` (domain, eigenaar,
   `doelbinding`, `pii_kolommen`), and column tests (`not_null`, `unique`,
   `bsn_valid` on the key) matching the existing pattern.
6. Keep models cross-engine portable (use `dbt.type_*()` / dispatch macros as the
   existing `int_*` models do). Run `dbt build --select int_*` if the env allows.

## Output — the Pull Request

- **Branch:** `mul/<id>-client-360-view-builder`
- **Title:** `MUL-<id>: dbt int_* models for UC-05 360° client view`
- **Body:** include `Closes MUL-<id>`; list each `int_*` model + what it joins; an
  explicit statement that **no `sensitive.*` / art. 9 data is joined**; how consent
  flags are applied; any OPA mask the reviewer should add (proposal only); and a
  note on **doelbinding** for the assembled view.
- **Labels:** `area:dbt`, `uc:05`, `area:governance`, `agent-pr`
- If `dbt build` can't run or a source is ambiguous, open the PR as **draft** and
  say why. **Never merge — a human reviews and merges (gate 2).**

## Acceptance checklist (self-verify before opening the PR)

- [ ] No model selects from or joins `sensitive.*` / art. 9 health data.
- [ ] Consent / opt-out flags are honoured (suppressed records drop out).
- [ ] Raw BSN only where required; otherwise `bsn_pseudo` via the macro.
- [ ] `_intermediate.yml` updated with description, `meta`, and key tests.
- [ ] Models compile cross-engine; `dbt build --select int_*` passes or PR says why.
- [ ] No OPA policy changed — any needed mask is proposed in the PR body only.

## Guardrails

- **Sensitive Vault stays separated.** `sensitive.*` art. 9 data never enters the
  general view; if asked, leave it out and explain — purpose-bound vault access is
  a separate, human-gated decision.
- **Doelbinding by design:** the assembled view serves `klantcontact` /
  `behandeling`; call out the purpose, never widen it.
- **Model assembles, OPA filters.** Don't pre-mask in SQL nor expose columns a role
  shouldn't see — propose policy, don't enact it.
- No secrets, no raw BSNs in fixtures or PR text; synthetic data only.
- AVG art. 9 + consent are first-class: a missing consent flag means exclude, not
  include.
