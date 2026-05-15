# In-cluster Multica daemon, bundled with the OpenAI Codex CLI and the
# opencode CLI — both wired to the UWV Azure AI Foundry endpoint.
#
# Two CLIs are installed so Multica's daemon can offer both runtimes
# (multica's daemon auto-detects any of [claude, codex, copilot, opencode,
# openclaw, ...] on PATH). Codex was the original target; opencode added
# because codex app-server's /v1/responses streaming fails mid-stream
# against Foundry — see codex-config.toml for the upstream issue note.
#
# Build context: this `platform/20-multica-daemon/` directory.
# Build manually:
#
#   ./build-and-load.sh        # from platform/20-multica-daemon/
#
# Or:
#
#   docker build -t uwv-platform/multica-daemon:dev .

# Stage 1 — grab the multica CLI binary from the upstream backend image.
# We don't reuse that image as the runtime base because we need Node.js
# for codex, and the upstream image is a slim distroless-ish layout.
FROM ghcr.io/multica-ai/multica-backend:latest AS multica-src

# Stage 2 — runtime. Node 20 + Debian slim gives us npm, apt for git,
# and a real shell for the entrypoint script.
FROM node:20-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# - git: clone repos the coding agent will edit
# - ca-certificates: for HTTPS calls to GitHub, Foundry, Multica
# - jq: handy for the entrypoint script to parse Multica config output
# - openssh-client: future-proof for git+ssh, costs almost nothing
# - tini: PID-1 to reap zombies; the daemon spawns codex sub-shells per task
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         git ca-certificates jq openssh-client tini \
    && rm -rf /var/lib/apt/lists/*

# Multica CLI — the binary that exposes `multica daemon start`.
COPY --from=multica-src /app/multica /usr/local/bin/multica
RUN chmod +x /usr/local/bin/multica

# OpenAI Codex CLI. Pinned to a known-good major to avoid surprise
# breakage on rebuild; bump deliberately when you re-test.
RUN npm install -g @openai/codex@0.130.0 \
    && npm cache clean --force

# opencode CLI (sst/opencode) — alternate coding-agent runtime that also
# speaks OpenAI-compatible APIs. Configured against the same Foundry
# endpoint via opencode.json / auth.json (entrypoint seeds auth.json).
RUN npm install -g opencode-ai@1.15.0 \
    && npm cache clean --force

# Non-root user. The Debian base ships a `daemon` user, and node:20 ships
# a `node` user at uid 1000, so use `multica` at uid 1001. The daemon
# writes to ~/.multica and codex to ~/.codex — both go on the workspace
# volume mounted at /home/multica.
RUN useradd --system --uid 1001 --create-home --shell /bin/bash --home-dir /home/multica multica

# Codex config template. The entrypoint copies it into ~/.codex/config.toml
# at runtime so the workspace volume holds the live copy (codex writes
# per-task scratch there too, and ~/.codex must be writable).
COPY codex-config.toml /etc/codex/config.toml.template
RUN chown -R multica:multica /etc/codex

# opencode config template — defines an `azure-foundry` provider via the
# @ai-sdk/openai-compatible npm package. The entrypoint copies this to
# ~/.config/opencode/opencode.json and writes ~/.local/share/opencode/auth.json
# from the AZURE_OPENAI_API_KEY env at startup.
COPY opencode.json /etc/opencode/opencode.json.template
RUN chown -R multica:multica /etc/opencode

# Entrypoint: configure server URL, log in with the bootstrap PAT,
# then exec `multica daemon start` in the foreground.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER multica
WORKDIR /home/multica

# tini → entrypoint → multica daemon start
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
