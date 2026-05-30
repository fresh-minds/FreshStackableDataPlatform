# Image for the Nanitics Observatory wired to Azure AI Foundry, deployed
# as part of the UWV reference data platform.
#
# Build context: this `app/` directory itself. The `observatory-ui/`
# directory must be populated *before* build — the helper script
# `../build-and-load.sh` copies it from the nanitics SDK repo.
#
# Build manually:
#
#   ./build-and-load.sh   # from platform/19-nanitics-observatory/
#
# Or:
#
#   cp -R <nanitics-repo>/observatory/dist-embed app/observatory-ui
#   docker build -t uwv-platform/nanitics-observatory:dev app/

FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /srv

# Install Nanitics + FastAPI from PyPI. Pin a known-good version; the
# layer README explains how to bump.
#
# httpx is the watcher's HTTP client for Prometheus + Multica. nanitics
# already depends on it transitively (via the OpenAI SDK), but the
# watcher pins it explicitly so it doesn't disappear under us if nanitics
# swaps client libraries.
# `trino` is the read-only data-plane client used by the observer agents
# (platform_tools.query_trino). It is a thin DBAPI wrapper over Trino's
# HTTP protocol — no native deps, safe to add to the slim image.
RUN pip install \
        "nanitics[api]==0.1.0" \
        "uvicorn[standard]>=0.30" \
        "httpx>=0.27" \
        "kubernetes_asyncio>=29" \
        "trino>=0.328" \
        "psycopg[binary]>=3.1"

# Embedded Observatory UI bundle. Populated from the nanitics repo at
# build-time by the helper script. If absent, the API still works but
# the UI root returns a fallback page (per the SDK's contract for
# static_dir=None — handled in app.py).
COPY observatory-ui /srv/observatory-ui

# Application glue + chat UI static assets.
COPY app.py /srv/app.py
COPY watcher.py /srv/watcher.py
COPY platform_tools.py /srv/platform_tools.py
COPY observers.py /srv/observers.py
COPY docs_tools.py /srv/docs_tools.py
COPY docs_index.py /srv/docs_index.py
COPY static /srv/static

# Docs corpus for the doc-rag agent (lexical RAG). Staged into the build
# context by build-and-load.sh from the repo's docs/ tree; gitignored here.
COPY docs-bundle /srv/docs-bundle

# Drop privileges.
RUN useradd --system --uid 1000 --create-home --shell /usr/sbin/nologin app \
    && chown -R app:app /srv
USER 1000:1000

EXPOSE 8001
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8001"]
