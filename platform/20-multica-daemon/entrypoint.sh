#!/usr/bin/env bash
# Entrypoint for the in-cluster Multica daemon.
#
# Boot order:
#   1. Materialise ~/.codex/config.toml from the image template (the
#      workspace volume hides anything under ~ on the image layer).
#   2. Point the multica CLI at the in-cluster server.
#   3. Log in with the bootstrap Personal Access Token (PAT) — first
#      boot only; subsequent boots reuse ~/.multica/auth.json on the PVC.
#   4. exec `multica daemon start` in the foreground.

set -euo pipefail

# --- 1. Sanity-check the credentials both CLIs inherit from this process. ---
if [[ -z "${AZURE_OPENAI_API_KEY:-}" ]]; then
  echo "FATAL: AZURE_OPENAI_API_KEY is unset. Neither codex nor opencode can call Foundry." >&2
  exit 1
fi

# --- 1a. Codex config on the writable volume ------------------------------
mkdir -p "$HOME/.codex"
if [[ ! -f "$HOME/.codex/config.toml" ]]; then
  cp /etc/codex/config.toml.template "$HOME/.codex/config.toml"
fi

# --- 1b. opencode config + credentials on the writable volume -------------
# opencode keeps its provider config at ~/.config/opencode/opencode.json
# and its credentials at ~/.local/share/opencode/auth.json. The
# credentials file isn't templatable in the image (we want the live env
# value, not a placeholder), so it gets written every boot.
mkdir -p "$HOME/.config/opencode" "$HOME/.local/share/opencode"
if [[ ! -f "$HOME/.config/opencode/opencode.json" ]]; then
  cp /etc/opencode/opencode.json.template "$HOME/.config/opencode/opencode.json"
fi
# jq writes the auth.json atomically and properly escapes the key value.
jq -n --arg key "$AZURE_OPENAI_API_KEY" \
  '{"azure-foundry": {"type": "api", "key": $key}}' \
  > "$HOME/.local/share/opencode/auth.json"
chmod 600 "$HOME/.local/share/opencode/auth.json"

# --- 2. Point CLI at the Multica server ------------------------------------
: "${MULTICA_SERVER_URL:?MULTICA_SERVER_URL must be set (e.g. http://multica-backend.uwv-platform:80)}"
: "${MULTICA_APP_URL:?MULTICA_APP_URL must be set (used in OAuth callbacks)}"

multica config set server_url "$MULTICA_SERVER_URL"
multica config set app_url    "$MULTICA_APP_URL"

# --- 3. Authenticate, if we haven't already --------------------------------
# The CLI stores its token under ~/.multica/. We only run `login` the
# first time — subsequent restarts reuse the stored token, even if the
# Secret is rotated.
if multica auth status 2>/dev/null | grep -q 'Logged in'; then
  echo "multica: already authenticated, skipping login"
elif [[ -n "${MULTICA_API_TOKEN:-}" ]]; then
  echo "multica: authenticating with bootstrap PAT"
  multica login --token "$MULTICA_API_TOKEN"
else
  echo "FATAL: not authenticated and MULTICA_API_TOKEN is empty." >&2
  echo "       Create a PAT in Multica's UI (Settings → Personal Access Tokens)" >&2
  echo "       and provision Secret 'multica-daemon-auth' with key MULTICA_API_TOKEN." >&2
  exit 2
fi

# --- 4. Daemon -------------------------------------------------------------
# `multica daemon start` daemonizes (forks + returns) by default — that
# would kill PID 1 and crash-loop the container. `--foreground` keeps
# it attached so tini can supervise it and container stdout captures
# every poll / claim / codex spawn.
echo "multica daemon starting (foreground mode)"
echo "  server:           $MULTICA_SERVER_URL"
echo "  codex model:      ${MULTICA_CODEX_MODEL:-<default in config.toml>}"
echo "  opencode model:   ${MULTICA_OPENCODE_MODEL:-<default in opencode.json>}"
echo "  workspace:        $HOME"
exec multica daemon start --foreground
