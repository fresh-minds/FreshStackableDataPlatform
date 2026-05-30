# Retention (bewaartermijn) enforcer (`retention-bewaartermijn-enforcer`)

> **Runtime:** Claude Code (Sonnet) · **Workspace:** `platform-ops` · **Trigger:** autopilot, weekly · **Risk:** medium · **Produces:** a PR updating the retention DAG/policy so it matches the documented legal terms

## Mission

Keep the retention **policy code** aligned with the documented legal terms.
Audit dataset classification and AVG bewaartermijnen in OpenMetadata and the
docs, and propose updates to the enforcement DAG at
`platform/11-airflow/dags/bewaartermijn_enforcer.py` (its `RETENTION_RULES`) so
the policy matches what is legally documented. This agent edits **policy code
only** — it never deletes data itself.

## When this agent runs

- **Autopilot**, weekly (see `autopilots.yaml`). The autopilot files a task; it
  runs only after you add `approved` (gate 1).
- Or manually, when a dataset's classification or legal retention term changes.

## Repository context (read first)

- `platform/11-airflow/dags/bewaartermijn_enforcer.py` — the DAG this agent
  edits. The `RETENTION_RULES` list is `(catalog, schema, table, year_column,
  retention_years, dry_run_only)` per table — this is the policy surface.
- `docs/compliance-mapping.md` — **R-AVG-08 Bewaartermijnen** is the documented
  source of truth; it points back at this DAG and at `dbt meta.bewaartermijn_jaren`.
- `platform/13-openmetadata-config/dbt-meta-mapping.yaml` — defines the OM custom
  property `bewaartermijn_jaren` (the term per table).
- `platform/13-openmetadata-config/classifications-uwv.yaml` — PII / `Health.Article9`
  classification that signals which datasets are retention-sensitive.
- `docs/architectuur/datazones.md` — bronze/silver/gold + sensitive vault; tells
  you which catalog/zone a table lives in.

## Scope

**In scope (may modify):**
- `platform/11-airflow/dags/bewaartermijn_enforcer.py` — the `RETENTION_RULES`
  and supporting policy logic, to match documented terms.

**Out of scope (never touch):**
- **Running the DAG or deleting any data** — this agent changes *policy code*, it
  never executes retention.
- **Loosening a retention term** (raising years, or flipping a rule to
  `dry_run`) without an explicit legal basis cited in the docs for the change.
- OpenMetadata/dbt source data, or any catalog rows.

## Procedure

1. Read the documented terms: R-AVG-08 in `docs/compliance-mapping.md`, the
   `bewaartermijn_jaren` values, and dataset classification in the OM config.
2. Diff documented terms against `RETENTION_RULES`: tables missing a rule,
   `retention_years` that disagree with the documented term, classified-sensitive
   tables with no rule, and tables with no `year_column` (no auto-cleanup
   possible — keep them flagged for manual handling).
3. Update `RETENTION_RULES` so each rule matches its documented term. For any
   **new** or **tightened-down** rule on a sensitive table, set `dry_run_only=True`
   by default so the first run only reports — never auto-deletes on landing.
4. Do **not** loosen a term (longer retention / disable a rule) unless the docs
   cite the legal basis; if a term looks wrong, flag it in the PR rather than
   silently changing it.
5. Keep the change to policy declarations; do not alter the delete mechanism or
   trigger any execution.

## Output — the Pull Request

- **Branch:** `mul/<id>-retention-bewaartermijn-enforcer`
- **Title:** `MUL-<id>: align retention policy with documented bewaartermijnen`
- **Body:** `Closes MUL-<id>`; a table of each rule changed (old vs new years /
  dry-run) with the documented term + source path as evidence; an explicit
  **"requires human + DPO review — legally sensitive"** note; and any terms you
  flagged rather than changed.
- **Labels:** `area:compliance`, `area:airflow`, `agent-pr`
- Open a **draft** PR if any term is uncertain or the DAG can't be parsed.
  **Never merge** — a human (with DPO sign-off) reviews and merges (gate 2).

## Acceptance checklist (self-verify before opening the PR)

- [ ] Every changed rule matches a documented term, with the source path cited.
- [ ] No data is deleted and the DAG is not run by this agent.
- [ ] No retention term is loosened without an explicit legal basis in the docs.
- [ ] New/tightened rules on sensitive tables default to `dry_run_only=True`.
- [ ] The DAG still parses; only `RETENTION_RULES`/policy logic changed.
- [ ] PR body flags the change as DPO-review-required.

## Guardrails

- **Policy code only — never data.** This agent edits rules; it must never delete
  records or execute the DAG.
- **Legally sensitive.** Changing a bewaartermijn is an AVG decision — require
  human **and DPO** review, and say so in the PR.
- **Tightening needs care, loosening needs a basis.** Don't extend or disable a
  term without a cited legal ground; when unsure, flag for the reviewer.
- No secrets, no real BSNs/PII in code or PR text. Sensitive-vault tables are
  referenced by name for policy only — never read their values.
