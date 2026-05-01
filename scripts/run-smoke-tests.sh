#!/usr/bin/env bash
# Run alle smoke tests onder tests/smoke/. Exit non-zero bij eerste failure.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
pass() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; }

shopt -s nullglob
tests=(tests/smoke/*.sh)
shopt -u nullglob

if [[ ${#tests[@]} -eq 0 ]]; then
  log "Geen smoke tests gevonden in tests/smoke/."
  exit 0
fi

failed=0
for t in "${tests[@]}"; do
  log "Run $t"
  if bash "$t"; then
    pass "$t"
  else
    fail "$t"
    failed=$((failed+1))
  fi
done

if [[ $failed -gt 0 ]]; then
  fail "$failed test(s) failed."
  exit 1
fi
echo
pass "Alle smoke tests groen."
