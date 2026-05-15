# OpenMetadata → Keycloak access-bridge.
#
# Build context: deze `app/` directory.
#
# Lokale build + import in k3d:
#
#   ./build-and-load.sh   # vanuit platform/17-om-access-bridge/

FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /srv

RUN pip install \
        "fastapi==0.115.0" \
        "httpx==0.27.2" \
        "uvicorn[standard]>=0.30"

COPY app.py /srv/app.py

RUN useradd --system --uid 1000 --create-home --shell /usr/sbin/nologin app \
    && chown -R app:app /srv
USER 1000:1000

EXPOSE 8002
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8002"]
