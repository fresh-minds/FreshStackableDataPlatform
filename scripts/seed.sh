#!/usr/bin/env bash
# Seed — genereer en laad synthetische data (10k cliënten).
#
# STUB voor fase 1. Wordt in fase 4 ingevuld zodra data-generation/ generators
# bestaan en NiFi/Kafka draaien.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLIENT_COUNT="${CLIENT_COUNT:-10000}"
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

if [[ ! -f "$ROOT/data-generation/pyproject.toml" ]]; then
  log "data-generation/ is nog niet ingericht (fase 4)."
  log "Skip seed."
  exit 0
fi

log "TODO fase 4: data-generation pipeline starten met CLIENT_COUNT=${CLIENT_COUNT}"
echo "  cd data-generation && uv run python -m generators.persona --count ${CLIENT_COUNT}"
echo "  ..."
