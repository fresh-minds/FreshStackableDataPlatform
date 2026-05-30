# Multica coding-agent briefings

This directory is the **version-controlled source of truth for the Multica
coding agents** that work on this repository. Multica itself is configured
in its web UI (Settings → Agents / Autopilots), but the *instructions* an
agent loads when it picks up a task — its **skill briefing** — live here as
markdown so they are reviewable, diffable, and travel with the repo.

> One coding agent ≈ one `*.md` briefing here + one Multica autopilot (see
> [`autopilots.yaml`](autopilots.yaml)) + the labels/workspace seeded in
> [`workspace-seed.md`](workspace-seed.md).

These agents are the **build** half of the platform's agent story. The
**observe** half lives in `platform/19-nanitics-observatory` (the watcher +
the data-plane observers) and the **ask** half is `platform/21-nao` (NL→SQL
analytics). Observers *file tasks*; these coding agents *fulfil tasks by
opening PRs*. See [`docs/agents/index.md`](../../../docs/agents/index.md)
for the whole picture.

---

## The two approval gates (this is the whole point)

Every change to this repository made by an agent passes **two human gates**,
exactly as you asked:

```
            ┌─ gate 1 (you, on the Multica board) ─┐        ┌─ gate 2 (you, on GitHub) ─┐
            ▼                                       ▼        ▼                            ▼
  task on   ──approve+assign──►  coding agent   ──opens──►  PR (draft if CI red)  ──review──►  merge
  backlog                        runs on a                  on fresh-minds/                    to main
  (filed by  ◄── filed by ──     developer                  FreshStackableData
  observer   nanitics observers  laptop /                   Platform
  or human)  or created by you   Multica daemon
```

1. **Gate 1 — approve the task.** A task lands on the Multica board (filed by
   a nanitics observer, by an autopilot, or by you). Nothing runs until a
   human adds the **`approved`** label and assigns it to a coding-agent user.
   This mirrors the watcher's existing contract — the Multica daemon filters
   on `approved`, so an unapproved task is inert.
2. **Gate 2 — merge the PR.** The agent opens a PR (never merges it).
   Branch protection + `CODEOWNERS` require **your** review before it can
   reach `main`. You read the diff and merge — or request changes.

No agent can bypass either gate. There is no auto-merge anywhere.

---

## Connecting Multica to GitHub (`fresh-minds/FreshStackableDataPlatform`)

Do this once, in the Multica UI + GitHub settings:

1. **Link the repo.** Multica → Workspace settings → Integrations → GitHub →
   add `fresh-minds/FreshStackableDataPlatform`.
2. **Install the Multica GitHub App** on the `fresh-minds` org, scoped to
   that one repo, with permissions: **Contents: read/write**, **Pull
   requests: read/write**, **Issues: read/write**, **Metadata: read**.
   (See <https://multica.ai/docs/github-integration>.)
3. **Protect `main`** (GitHub → Settings → Branches → add rule for `main`):
   - ✅ Require a pull request before merging
   - ✅ Require approvals: **1**
   - ✅ Require review from **Code Owners**
   - ✅ Dismiss stale approvals on new commits
   - ✅ Require status checks to pass (select the CI workflows in
     `.github/workflows/`)
   - ✅ Do not allow bypassing the above (so the agent App can't self-merge)
4. **Code owner = you.** [`.github/CODEOWNERS`](../../../.github/CODEOWNERS)
   assigns every path to `@karelgo` (confirmed). Run
   [`scripts/setup-agent-github.sh`](../../../scripts/setup-agent-github.sh)
   to apply the branch protection that makes this gate binding (PR + 1 review
   + code-owner review + no bypass).
5. **PR template.**
   [`.github/pull_request_template.md`](../../../.github/pull_request_template.md)
   makes every agent PR declare its Multica task and re-state the two-gate
   checklist.

### Task ↔ PR linking

Multica links a PR to its task when the task identifier (e.g. `MUL-123`)
appears in the **branch name**, **PR title**, or **PR body** (case-insensitive,
workspace-scoped). Every briefing here instructs the agent to:

- branch as `mul/<id>-<slug>` (e.g. `mul/123-dbt-test-generator`)
- title as `MUL-<id>: <summary>`
- put `Closes MUL-<id>` in the body

When you merge, Multica auto-moves the linked task to **Done**.

---

## How a briefing becomes a live agent

1. **Pick a runtime** in Multica → Settings → Agents: create an agent
   (e.g. `claude-code`) with a provider/model. Sonnet-class for routine
   transforms; Opus-class for the reviewer/compliance/AI-Act agents.
2. **Attach the briefing** as the agent's skill/instruction (paste or
   reference the matching `*.md` from this directory). Keep the file here
   as the canonical copy; the UI copy is a deployment artifact.
3. **(Optional) Add an autopilot** from [`autopilots.yaml`](autopilots.yaml)
   so the agent's task is created on a schedule. Autopilot-created tasks
   still require gate 1 (`approved`) before the agent runs — keep
   "auto-approve" **off**.
4. **Seed labels/workspaces** once per workspace — see
   [`workspace-seed.md`](workspace-seed.md).

---

## The roster

Grouped by how the task originates. **Risk** drives the recommended model and
how carefully you should review the PR.

### Tier 1 — start here (low blast radius, exercises the full loop)

| Briefing | Slug | Trigger | Risk |
|---|---|---|---|
| [Compliance mapping auditor](compliance-mapping-auditor.md) | `compliance-mapping-auditor` | autopilot weekly | low |
| [dbt test generator](dbt-test-generator.md) | `dbt-test-generator` | autopilot weekly / manual | low |
| [OPA policy author](opa-policy-author.md) | `opa-policy-author` | manual (NL rule in task) | medium |
| [OpenMetadata description filler](openmetadata-description-filler.md) | `openmetadata-description-filler` | autopilot nightly | low |

### Tier 2 — use-case agents (UC-aligned)

| Briefing | Slug | UC | Risk |
|---|---|---|---|
| [DPIA / IAMA drafter](dpia-iama-drafter.md) | `dpia-iama-drafter` | UC-02 | **high (AI Act Annex III)** |
| [Bias & fairness reviewer](bias-fairness-reviewer.md) | `bias-fairness-reviewer` | UC-03 | high |
| [Client-360 view builder](client-360-view-builder.md) | `client-360-view-builder` | UC-05 | medium (sensitive) |
| [Intervention effectiveness analyst](intervention-effectiveness-analyst.md) | `intervention-effectiveness-analyst` | UC-09 | low |
| [Canonical schema drafter](canonical-schema-drafter.md) | `canonical-schema-drafter` | UC-10 | medium |

### Tier 3 — platform care (developer productivity)

| Briefing | Slug | Trigger | Risk |
|---|---|---|---|
| [ADR drafter](adr-drafter.md) | `adr-drafter` | on config change | low |
| [Mode-drift detector](mode-drift-detector.md) | `mode-drift-detector` | autopilot weekly | medium |
| [Smoke-test maintainer](smoke-test-maintainer.md) | `smoke-test-maintainer` | on new `platform/NN-*` | low |
| [Doc–code drift watcher](doc-code-drift-watcher.md) | `doc-code-drift-watcher` | autopilot weekly | low |
| [Helm values pruner](helm-values-pruner.md) | `helm-values-pruner` | autopilot monthly | medium |
| [Retention (bewaartermijn) enforcer](retention-bewaartermijn-enforcer.md) | `retention-bewaartermijn-enforcer` | autopilot weekly | medium |
| [Pseudonymization PR bot](pseudonymization-pr-bot.md) | `pseudonymization-pr-bot` | on new sensitive dataset | high (sensitive) |
| [Use-case scaffolder](use-case-scaffolder.md) | `use-case-scaffolder` | manual (`scaffold UC-NN`) | medium |

> **Already built, not in this directory:** the **NL→SQL analytics agent**
> is `platform/21-nao` (nao), and the **failure-triage / platform watcher**
> is the nanitics `watcher` agent. The data-plane observers
> (`funnel-anomaly`, `dq-sentinel`, `cost-anomaly`, `journey-miner`,
> `damage-forecaster`, `access-triage`) live in
> `platform/19-nanitics-observatory/app/observers.py` — they feed this
> backlog.

---

## Briefing template

Every `*.md` in this directory follows the same shape so agents behave
consistently and you always know where to look:

```
# <Name> (`<slug>`)
> Runtime · Workspace · Trigger · Risk · Produces

## Mission                         — one or two sentences
## When this agent runs            — autopilot / approved-label / manual
## Repository context (read first) — exact paths + why
## Scope                           — In scope (may modify) / Out of scope (never)
## Procedure                       — numbered steps
## Output — the Pull Request       — branch, title, body, labels, draft-if-CI-red
## Acceptance checklist            — agent self-verifies before opening the PR
## Guardrails                      — AVG / doelbinding / AI Act / sensitive vault
```

---

## Guardrails that apply to **every** agent here

These are repeated in each briefing, but they are absolute:

- **Never touch the sensitive vault** (`sensitive.*` catalogs, art.9 health
  data) unless the briefing is explicitly about it (only the
  pseudonymization bot is, and only to *mask*, never to read values).
- **Never commit secrets.** No tokens, keys, passwords, BSNs, names, or any
  PII in code, fixtures, or PR text. Secrets stay in out-of-band K8s Secrets
  (the repo's established pattern).
- **Never merge, never force-push to `main`, never disable a check.** Open a
  **draft** PR if CI is red and explain why.
- **Stay in scope.** One task → one focused PR. If you discover unrelated
  work, note it in the PR body or file a follow-up task — don't expand the diff.
- **Respect doelbinding.** Changes that broaden data access or purpose must
  call it out explicitly for the reviewer.
- **AI Act.** Anything touching UC-02 (Wajong) or other high-risk decisioning
  is **Annex III high-risk** — produce documentation/artifacts for human
  sign-off; do **not** ship an autonomous decision model.
