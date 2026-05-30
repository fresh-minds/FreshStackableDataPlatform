#!/usr/bin/env bash
# One-time GitHub setup for the Multica coding-agent two-gate flow.
#
# Enforces approval **gate 2** on the repo: branch protection on `main`
# requiring a PR, one approving review, code-owner review (.github/CODEOWNERS),
# stale-review dismissal, and no admin bypass — so no agent (and no human)
# can self-merge. Gate 1 is approving + assigning the task on the Multica
# board; see platform/17-multica/agents/README.md.
#
# Requires the `gh` CLI authenticated with admin on the repo:
#   gh auth login
#
# Re-runnable. The GitHub App install + Multica UI config are manual (links
# printed at the end), as are the in-cluster secrets (kubectl commands below).

set -euo pipefail

REPO="${REPO:-fresh-minds/FreshStackableDataPlatform}"
BRANCH="${BRANCH:-main}"

echo "==> Repo:   ${REPO}"
echo "==> Branch: ${BRANCH}"

command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI not found." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: run 'gh auth login' first." >&2; exit 1; }

# CODEOWNERS sanity check (gate 2 needs it).
if ! gh api "repos/${REPO}/contents/.github/CODEOWNERS" >/dev/null 2>&1; then
  echo "WARN: .github/CODEOWNERS not found on ${BRANCH} yet — commit it before"
  echo "      'require code-owner reviews' will have any effect."
fi

echo "==> Applying branch protection on '${BRANCH}'"
gh api -X PUT "repos/${REPO}/branches/${BRANCH}/protection" \
  -H "Accept: application/vnd.github+json" --input - >/dev/null <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "require_code_owner_reviews": true,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
echo "    ok — PR + 1 review + code-owner review required; no bypass."
echo "    (Add CI checks later via 'required_status_checks' once workflows are green.)"

cat <<EOF

==> Manual steps that need cloud / UI access (not scriptable here):

  1. Install the Multica GitHub App on the 'fresh-minds' org, scoped to this
     repo, perms: Contents RW, Pull requests RW, Issues RW, Metadata R.
     -> https://multica.ai/docs/github-integration

  2. In Multica: create the coding-agent user(s), seed workspaces + labels
     (platform/17-multica/agents/workspace-seed.md), attach the briefings,
     and create autopilots (platform/17-multica/agents/autopilots.yaml).

==> In-cluster secrets for the agents (need kubectl, not GitHub):

  # Trino read-only user for the Nanitics observers (see platform/09-trino/
  # trino-static-auth.yaml — add 'nanitics-observer: <password>' there too):
  kubectl -n uwv-platform create secret generic nanitics-trino \\
    --from-literal=TRINO_PASSWORD='<password-matching-trino-static-users>' \\
    --dry-run=client -o yaml | kubectl apply -f -

  # Multica bearer token for the watcher + observers to file tasks:
  kubectl -n uwv-platform create secret generic nanitics-multica-token \\
    --from-literal=MULTICA_API_TOKEN='<paste-token>' \\
    --dry-run=client -o yaml | kubectl apply -f -

Done. Gate 2 is now enforced on '${BRANCH}'.
EOF
