# Helm values pruner (`helm-values-pruner`)

> **Runtime:** Claude Code (Sonnet) · **Workspace:** `platform-ops` · **Trigger:** autopilot, monthly · **Risk:** medium · **Produces:** a PR removing dead/obsolete Helm values keys

## Mission

Audit the values files under `infrastructure/helm/` for keys that the **upstream
chart or operator CRD schema no longer recognizes** (pinned via
`infrastructure/stackablectl/release.yaml`), and propose removing them — each
with a justification. A leftover value silently does nothing; a *wrongly*
removed value silently changes behaviour, so the bias here is caution.

## When this agent runs

- **Autopilot**, monthly (see `autopilots.yaml`). The autopilot files a task; it
  runs only after you add `approved` (gate 1).
- Or manually, after an operator/chart version bump when stale keys are likely.

## Repository context (read first)

- `infrastructure/helm/` — the per-chart values files this agent audits
  (`cert-manager`, `ingress-nginx`, `keycloak`, `minio`, `openmetadata`,
  `opensearch`, `opensearch-dashboards`, `postgresql`, `prometheus-stack`,
  `vector`). The input.
- `infrastructure/stackablectl/release.yaml` — the **pinned operator versions**;
  obsolescence is judged against these exact versions, never "latest".
- `infrastructure/stackablectl/stack.yaml` — how the stack/charts are assembled.
- `platform/` — the `NN-*` dirs that consume these values; cross-check that a
  key isn't referenced by a manifest before calling it dead.
- `scripts/deploy-platform.sh` — how values are wired in per `--mode`; a key may
  be templated/overridden here rather than unused.

## Scope

**In scope (may modify):**
- Values files under `infrastructure/helm/**` — removing keys you have
  **verified** are unrecognized by the pinned chart version, or adding a
  `# FLAG:` comment where you're unsure.

**Out of scope (never touch):**
- Changing values that are **still in use** — removal only, never re-tuning.
- Bumping any chart/operator version (that's a deliberate, separate change).
- Mode-specific override files outside `infrastructure/helm/` unless the task
  names them.

## Procedure

1. For each values file, resolve the **exact** chart/operator version from
   `release.yaml` (and `stack.yaml`).
2. Compare each top-level and nested key against that version's documented
   values schema / CRD. Classify each candidate key as: **(a) verified obsolete**
   (renamed/removed/no-op in this version), or **(b) uncertain**.
3. **Only delete (a).** For every uncertain key (b), do **not** delete — add an
   inline `# FLAG: not found in chart <version> — verify` comment so the human
   can decide. When unsure, flag, never remove.
4. Confirm no `platform/` manifest or `deploy-platform.sh` references a key
   before removing it (a value can be consumed indirectly).
5. If a templating tool is available, render the chart before/after to show the
   removal produces no rendered-output change for verified keys.

## Output — the Pull Request

- **Branch:** `mul/<id>-helm-values-pruner`
- **Title:** `MUL-<id>: prune obsolete Helm values`
- **Body:** `Closes MUL-<id>`; a table of every key, the chart+version it was
  checked against, and the verdict (removed / flagged) with the evidence. List
  flagged-not-removed keys separately so the reviewer can act on them.
- **Labels:** `area:helm`, `agent-pr`
- Open a **draft** PR if you couldn't render/verify against the pinned version,
  or if most findings are flags. **Never merge** — a human reviews and merges
  (gate 2).

## Acceptance checklist (self-verify before opening the PR)

- [ ] Every **removed** key is verified obsolete against the pinned chart
      version (evidence cited) — no guesses deleted.
- [ ] Every **uncertain** key is flagged with a comment, not removed.
- [ ] No removed key is referenced by a `platform/` manifest or
      `deploy-platform.sh`.
- [ ] No still-in-use value was changed, and no version was bumped.
- [ ] Rendered output is unchanged for the removed keys (or the PR says it
      couldn't be rendered).

## Guardrails

- **Verify-or-flag is absolute.** A wrongly-deleted value can silently change
  behaviour — when in doubt, comment, don't delete.
- **Pinned versions only.** Judge obsolescence against the version in
  `release.yaml`, never against upstream `latest`.
- This is a **cleanup** agent: removal and comments only, no re-tuning, no
  version bumps.
- No secrets in values or PR text — credentials stay in out-of-band K8s Secrets,
  the repo's established pattern; never inline a secret while editing nearby.
