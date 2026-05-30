## Linked Multica task

Closes MUL-____ <!-- agents fill this in; required for task ↔ PR linking -->

## What changed

<!-- one short paragraph: what and why -->

## How to verify

<!-- the commands/steps a reviewer runs; paste CI or local test output -->

## Two-gate confirmation

- [x] **Gate 1** — the task was approved (`approved` label) and assigned on the Multica board
- [ ] **Gate 2** — reviewed and approved here by the code owner before merge

## Compliance & safety

- [ ] No secrets, tokens, or PII in the diff or in this PR's text
- [ ] No `sensitive.*` (art.9 health) values read, sampled, logged, or exposed
- [ ] Doelbinding respected — no unintended broadening of data access or purpose
- [ ] AI Act — not a high-risk decisioning change, **or** the linked task carries
      `ai-act:high-risk` and this PR only adds artifacts/controls for human sign-off
- [ ] Diff stays within the scope of the linked task (no drive-by changes)

---

🤖 If this PR was opened by a Multica coding agent it must **not** be
auto-merged. The code owner reviews and merges (gate 2).
