# Doc–code drift watcher (`doc-code-drift-watcher`)

> **Runtime:** Claude Code (Sonnet) · **Workspace:** `platform-ops` · **Trigger:** autopilot, weekly · **Risk:** low · **Produces:** a PR reconciling the architecture docs with the actual platform content

## Mission

Keep the architecture docs honest about what is actually deployed. Detect where
`docs/architectuur/componenten.md` (and the related architecture docs) have
**drifted** from the real `platform/` directory and the pinned operators in
`infrastructure/stackablectl/release.yaml` — components missing or renamed,
stale paths, dead URLs, wrong Prometheus job names or ports — and fix the docs
so they match reality.

## When this agent runs

- **Autopilot**, weekly (see `autopilots.yaml`). The autopilot files a task; it
  runs only after you add `approved` (gate 1).
- Or manually, after you know a `platform/NN-*` component was added, renamed, or
  removed.

## Repository context (read first)

- `docs/architectuur/componenten.md` — per-component overview (URL, Prometheus
  job, using roles). **Auto-generated** by `scripts/docs_gen.py` from
  `portal/src/data/components.ts` — see the next bullet before editing.
- `portal/src/data/components.ts` — the **single source** the generated docs
  derive from. Component drift is fixed here, not in the `.md`.
- `scripts/docs_gen.py` — the generator; run it to regenerate the `docs/` output
  after editing the TS source.
- `platform/` — the actual deployed components (each `NN-*` dir). The source of
  truth for "what exists".
- `infrastructure/stackablectl/release.yaml` — which operators are pinned
  (some, e.g. kafka/nifi/zookeeper, are commented out — the docs must agree).
- `docs/architectuur/` — the rest: `index.md`, `datazones.md`, `auth.md`,
  `tabel-formaat.md` (also generated from the TS source in places).

## Scope

**In scope (may modify):**
- `portal/src/data/components.ts` when the drift is a component fact (name, URL,
  Prometheus job, using roles, presence/absence), then regenerate the docs.
- Hand-written prose in `docs/architectuur/*.md` that is *not* in a
  generated block (stale paths/ports/links in narrative text).

**Out of scope (never touch):**
- Any `platform/` manifest, Helm value, or code — this agent **documents**, it
  does not change behaviour.
- Editing the auto-generated body of a generated `.md` directly (it reverts on
  the next CI build — fix the TS source instead).
- Rewriting the document structure wholesale — reconcile facts, don't redesign.

## Procedure

1. Build a current inventory of components from `platform/` (the `NN-*` dirs)
   and from the enabled products in `release.yaml`.
2. Diff that inventory against `components.ts` and the architecture docs:
   components present in `platform/` but missing from the docs, components in the
   docs that no longer exist or were renamed, and disabled operators still
   described as live.
3. Spot-check the concrete facts: file paths referenced in prose, URLs/ports,
   and Prometheus job names — flag the ones that no longer resolve.
4. Fix component facts in `components.ts`, then run `scripts/docs_gen.py` so the
   generated docs regenerate from source. Fix stale prose directly in the `.md`.
5. Re-run the generator and confirm the docs are clean (no further diff).

## Output — the Pull Request

- **Branch:** `mul/<id>-doc-code-drift-watcher`
- **Title:** `MUL-<id>: reconcile architecture docs with platform/`
- **Body:** `Closes MUL-<id>`; a bullet list of each drift found and how it was
  fixed (component added/renamed/removed, path/port/URL corrected); note that
  generated docs were regenerated via `scripts/docs_gen.py`.
- **Labels:** `area:docs`, `agent-pr`
- If `docs_gen.py` or a docs CI check fails, open the PR as **draft** and say
  why. **Never merge** — a human reviews and merges (gate 2).

## Acceptance checklist (self-verify before opening the PR)

- [ ] Every documented component maps to a real `platform/` dir / enabled
      operator; every real component is documented.
- [ ] Component facts were fixed in `components.ts`, not in the generated `.md`.
- [ ] `scripts/docs_gen.py` was re-run; the generated docs match source.
- [ ] Corrected paths, URLs, ports and Prometheus job names resolve.
- [ ] Document structure, anchors and Dutch/English conventions are intact.

## Guardrails

- This is a **documentation** agent: zero behaviour change, zero `platform/`
  edits.
- **Don't fight the generator.** Editing a generated `.md` body is wasted work —
  always fix `portal/src/data/components.ts` and regenerate.
- **Under-claim, never over-claim.** If you can't confirm a component is live,
  describe it as such rather than asserting it.
- No secrets, no PII, no sensitive-vault references beyond what the docs already
  contain.
