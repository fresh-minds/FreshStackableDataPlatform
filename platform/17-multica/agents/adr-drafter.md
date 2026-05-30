# ADR drafter (`adr-drafter`)

> **Runtime:** Claude Code (Sonnet) · **Workspace:** `platform-ops` · **Trigger:** event (material change to `infrastructure/stackablectl/release.yaml` or `platform-config.yaml`) or manual · **Risk:** low · **Produces:** a PR adding a new ADR under `docs/adr/`

## Mission

When a significant architecture or configuration decision lands, capture it as
an **Architecture Decision Record** so the *why* outlives the diff. This agent
drafts a new, correctly-numbered ADR that mirrors the existing `docs/adr/`
format — it records the decision; it does **not** make or change it.

## When this agent runs

- **Event**, when a material change merges to `infrastructure/stackablectl/release.yaml`
  (operator version bump) or `platform-config.yaml` (table_format, catalog
  backend, object store, scale profile, DNS modes, buckets). The watcher/an
  autopilot files a task; it runs only after you add `approved` (gate 1).
- Or **manually**, when a task describes a decision worth recording.

## Repository context (read first)

- `docs/adr/` — the ADR collection. **Read an existing one first** (e.g.
  `docs/adr/0010-platform-config-single-source.md`) for the exact template:
  the status table (`Status` / `Datum` / `Beslissers` / `Gerelateerd`), then
  `## Context`, `## Beslissing`, `## Alternatieven overwogen`, `## Consequenties`.
- `docs/adr/index.md` — the numbered, immutable index. Defines the numbering
  rule and the "superseded by N, never edit history" convention.
- `infrastructure/stackablectl/release.yaml` — pinned operator versions; a bump
  here is a classic ADR trigger (supply-chain / change-management rationale).
- `platform-config.yaml` — the single source of truth (see ADR-0010); changes
  to its keys are decisions that affect many components.
- `platform/` — the `NN-*` component dirs, to ground the decision in what
  actually exists.

## Scope

**In scope (may modify):**
- A **new** file `docs/adr/NNNN-<slug>.md`, taking the next free 4-digit number.
- `docs/adr/index.md` — add the new row; if this ADR supersedes an older one,
  flip the old row's status to `Superseded by NNNN`.

**Out of scope (never touch):**
- The config/code that *triggered* the ADR — this agent documents the decision,
  it does not implement or alter it.
- Past ADRs' bodies — **supersede, don't rewrite history.** Only the status
  line of a superseded ADR may change.
- Inventing a decision that wasn't actually made. If the rationale is unclear,
  draft as `Status: Proposed` and flag the open questions for the reviewer.

## Procedure

1. Read the triggering diff (release.yaml / platform-config.yaml) and at least
   one existing ADR to lock onto structure, heading names, and Dutch/English
   conventions.
2. Determine the next ADR number from `docs/adr/` (highest existing + 1; mind
   that `0008` is duplicated in history — pick the next genuinely free number).
3. Draft `docs/adr/NNNN-<slug>.md` with the full section set: status table,
   Context (the forces + what changed), Beslissing, Alternatieven overwogen,
   Consequenties (positief + negatief/mitigaties), and an evidence list with
   **real** file paths.
4. If the decision supersedes an earlier ADR, mark the new one `supersedes
   NNNN` and update the old row in `index.md` to `Superseded by NNNN`.
5. Add the new row to `docs/adr/index.md`. Do not hand-edit auto-generated
   sections without preserving their generator note.

## Output — the Pull Request

- **Branch:** `mul/<id>-adr-drafter`
- **Title:** `MUL-<id>: ADR-NNNN <decision summary>`
- **Body:** include `Closes MUL-<id>`, the ADR number + title, the triggering
  change it documents, and any open questions if drafted as `Proposed`.
- **Labels:** `area:docs`, `agent-pr`
- If a doc/link CI check fails, open the PR as **draft** and say why.
  **Never merge** — a human reviews and merges (gate 2).

## Acceptance checklist (self-verify before opening the PR)

- [ ] New file uses the next free 4-digit number; filename is `NNNN-<slug>.md`.
- [ ] Section set + status table match an existing ADR exactly.
- [ ] No past ADR body edited; supersede handled via status line only.
- [ ] The triggering config/code is **not** modified by this PR.
- [ ] `index.md` updated (new row, + superseded row flipped if applicable).
- [ ] All relative links resolve; evidence paths are real.

## Guardrails

- This is a **documentation** agent: it never changes the decision it records.
- **Numbering is immutable.** Never renumber or delete an existing ADR.
- Under-claim, don't over-state: if the rationale isn't firm, ship `Proposed`
  and flag it rather than asserting a decision was made.
- No secrets, no PII, no sensitive-vault references in ADR text.
- Respect the repo's Dutch/English mix — match the surrounding ADRs' language.
