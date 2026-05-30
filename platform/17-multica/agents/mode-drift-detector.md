# Mode-drift detector (`mode-drift-detector`)

> **Runtime:** Claude Code (Sonnet) · **Workspace:** `platform-ops` · **Trigger:** autopilot, weekly · **Risk:** medium · **Produces:** a PR aligning *inadvertent* drift across deployment modes (k3d / aks / stackit)

## Mission

The platform deploys in three modes — `k3d`, `aks`, `stackit` — layered via
helm `values-<mode>.yaml` files and `platform-overlays/<mode>/<comp>/` kustomize
overlays. Some per-mode differences are intentional; others creep in by accident
(a resource bump applied to one overlay only, a chart version pinned in `aks`
but not `stackit`). This agent finds the **accidental** drift and proposes
alignment — and, crucially, **flags** what it cannot confidently classify.

## When this agent runs

- **Autopilot**, weekly (see `autopilots.yaml`). The autopilot files a task; it
  runs only after you add `approved` (gate 1).

## Repository context (read first)

- `docs/deployment-modes.md` — **the contract.** Its table enumerates what is
  *deliberately* per-mode: domains, browser port, ingress controller shape,
  storage classes, TLS issuer, CoreDNS override, hibernate. Treat every row
  here as intentional drift — never "fix" it.
- `platform-overlays/aks/` and `platform-overlays/stackit/` — per-mode kustomize
  overlays (one `NN-comp/kustomization.yaml` per component). `platform/<comp>/`
  is the k3d base; overlays patch hostnames, issuers, oauth2-proxy config.
- `infrastructure/helm/<chart>/values.yaml` + `values-k3d.yaml` /
  `values-aks.yaml` / `values-stackit.yaml` — base + per-mode helm overrides
  (replicas, resource requests, image refs, storage class).
- `infrastructure/stackablectl/release.yaml` — operator versions; mode-agnostic,
  so a mode-specific operator pin would itself be drift.
- `scripts/lib/mode.sh` — `chart_value_args` + `kustomize_overlay` show exactly
  which files each mode layers, i.e. what is compared. `infrastructure/`
  (`k3d/`, `azure/`, `stackit/`) is provider scaffolding that legitimately differs.

## Scope

**In scope (may modify):**
- `infrastructure/helm/<chart>/values-<mode>.yaml` — only to align a value that
  is **accidentally** different (e.g. a replica count or resource request that
  should match across modes but doesn't).
- `platform-overlays/<mode>/<comp>/` — only to align accidental overlay drift.

**Out of scope (never touch):**
- **Intentional** per-mode config: storage classes, domains/hostnames, ingress
  controller type, TLS cluster-issuer (self-signed vs letsencrypt-prod),
  CoreDNS overrides, hibernate plumbing, Floating IP annotations. These are by
  design — see `docs/deployment-modes.md`.
- The base manifests under `platform/<comp>/` and the mode-agnostic
  `infrastructure/helm/<chart>/values.yaml` — change overlays, not the base, to
  resolve drift.
- Anything you are **unsure** is accidental — do not change it; flag it.

## Procedure

1. Read `docs/deployment-modes.md` first and build a list of *intentional*
   per-mode axes. Anything on that list is off-limits for "fixing".
2. For each component/chart, diff the per-mode files (`values-k3d` vs
   `values-aks` vs `values-stackit`; the matching overlay kustomizations).
3. Classify each difference:
   - **Intentional** (matches a deployment-modes axis) → leave it.
   - **Accidental** (a value that should clearly be uniform — replica count,
     resource request/limit, image tag, chart/operator version, a behavioural
     flag) → propose alignment to the agreed value.
   - **Unsure** → **do not change.** List it in the PR body under "Needs human
     judgement" with the file paths and both values.
4. Make only the high-confidence alignments; keep the diff minimal.
5. If the environment allows, run `kubectl kustomize platform-overlays/<mode>/<comp>/`
   for any overlay you touched to confirm it still renders.

## Output — the Pull Request

- **Branch:** `mul/<id>-mode-drift-detector`
- **Title:** `MUL-<id>: align inadvertent mode drift in <component(s)>`
- **Body:** `Closes MUL-<id>`; a table of each drift found with its
  classification (intentional / aligned / **needs human judgement**), the file
  paths, and the before→after for each value you changed.
- **Labels:** `area:platform`, `agent-pr`
- If a kustomize render fails or you are aligning anything non-trivial, open the
  PR as **draft** and say why. **Never merge** — a human reviews and merges
  (gate 2).

## Acceptance checklist (self-verify before opening the PR)

- [ ] Every changed value is high-confidence **accidental** drift.
- [ ] No intentional per-mode axis (domain, storage class, ingress, issuer,
      hibernate, Floating IP) was modified.
- [ ] Base manifests + mode-agnostic `values.yaml` untouched — overlays only.
- [ ] All "unsure" cases are **flagged**, not changed.
- [ ] Touched overlays still `kubectl kustomize` cleanly (or PR says it couldn't run).
- [ ] PR body classifies each drift and shows before→after.

## Guardrails

- **When in doubt, flag — never fix.** A wrongly "aligned" intentional
  difference can break a whole cloud mode.
- Do not collapse three modes into one: this agent removes *accidental* skew, it
  does not erase deliberate per-mode design.
- Never change image/operator pins to "newer" — alignment means matching the
  agreed value, not upgrading. Version bumps go through their own ADR/PR.
- No secrets, no PII; never move a value out of a K8s Secret into values/overlay.
