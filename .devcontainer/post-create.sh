#!/usr/bin/env bash
# Post-create stap voor de UDP devcontainer / GitHub Codespace.
# Doel: alle CLI's die in de Academy-modules genoemd worden meteen werken.

set -euo pipefail

echo "─── installing python deps ───"
python -m pip install --upgrade pip
python -m pip install \
  'dbt-trino>=1.8' \
  'pre-commit>=3.7' \
  'pytest>=8' \
  'requests>=2.32' \
  'jupyter>=1.0' \
  'pandas>=2.2'

echo "─── installing stackablectl ───"
# https://github.com/stackabletech/stackable-cockpit/releases
# Version is PINNED (no 'latest') so the downloaded artefact is reproducible.
# TODO(security follow-up): upstream does not currently publish a per-asset
# .sha256 and the release assets aren't checksummed here yet. Until a trusted
# checksum is committed, you can supply the expected hash out-of-band via
# STACKABLE_SHA256=<sha256> and this script will verify it (sha256sum -c).
STACKABLE_VERSION="${STACKABLE_VERSION:-25.7.0}"
STACKABLE_SHA256="${STACKABLE_SHA256:-}"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  PLATFORM="x86_64-unknown-linux-gnu" ;;
  aarch64) PLATFORM="aarch64-unknown-linux-gnu" ;;
  *) echo "warn: stackablectl niet voor $ARCH"; exit 0 ;;
esac
URL="https://github.com/stackabletech/stackable-cockpit/releases/download/stackablectl-${STACKABLE_VERSION}/stackablectl-${PLATFORM}"
TMP_SC="$(mktemp)"
curl -fL --retry 3 -o "$TMP_SC" "$URL"
if [ -n "$STACKABLE_SHA256" ]; then
  echo "${STACKABLE_SHA256}  ${TMP_SC}" | sha256sum -c - \
    || { echo "ERROR: stackablectl checksum mismatch — refusing to install"; rm -f "$TMP_SC"; exit 1; }
  echo "stackablectl checksum verified"
else
  echo "warn: STACKABLE_SHA256 not set — installing without checksum verification (see TODO above)"
fi
sudo install -m 0755 "$TMP_SC" /usr/local/bin/stackablectl
rm -f "$TMP_SC"

echo "─── pre-commit hooks ───"
if [ -f .pre-commit-config.yaml ]; then
  pre-commit install --install-hooks || true
fi

echo "─── portal node deps ───"
if [ -d portal ]; then
  (cd portal && npm install --no-fund --no-audit)
fi

echo "─── done ───"
echo
echo "Probeer:"
echo "  cd portal && npm run dev   # Academy lokaal op :4321"
echo "  make help                  # alle make-targets"
