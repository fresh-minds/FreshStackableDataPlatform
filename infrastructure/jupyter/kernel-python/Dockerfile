# UWV Lab — single-user JupyterLab kernel image.
#
# Base: `quay.io/jupyter/scipy-notebook` brings pandas / numpy / matplotlib /
# scikit-learn / sympy. We layer the lakehouse-specific libraries:
#
#   - trino       — SQL access to bronze/silver/gold/sensitive (honors OPA).
#   - deltalake   — read/write Delta tables directly on MinIO via delta-rs.
#   - duckdb      — local analytics engine for ad-hoc joins on Trino results.
#   - polars      — fast in-process dataframe.
#   - s3fs        — browse and read raw objects in the MinIO buckets.
#   - kafka-python — peek at Kafka topics for streaming demos.
#   - openmetadata-ingestion — query the catalog API from notebooks.
#   - jupyterlab-git — commit / push / pull from inside the lab UI.
#   - ipywidgets   — interactive controls in notebooks.
#
# A small `uwv_lab` helper package is baked in alongside the libraries so a
# user can do `from uwv_lab import trino, s3, hms` and get pre-configured
# clients that respect the env injected by the JupyterHub spawner.
#
# Build (vanuit repo-root):
#   docker build -t uwv-platform/jupyter-kernel:dev -f infrastructure/jupyter/kernel-python/Dockerfile .
#   k3d image import uwv-platform/jupyter-kernel:dev -c uwv-platform
#
# Of:  make jupyter-image
#
# SYNTHETIC DATA — UWV REFERENCE PLATFORM — NOT FOR REAL USE.
FROM quay.io/jupyter/scipy-notebook:2024-10-21

USER root

# OS-level tooling: git for jupyterlab-git, openssh-client for git@ remotes,
# ca-certificates so we can swap in the UWV CA bundle later, less for `git log`.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git \
      openssh-client \
      ca-certificates \
      less \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# Build-time pip cache cleanup keeps the image lean for k3d import.
ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

USER ${NB_UID}

# Pinned versions: bump deliberately. trino 0.330+ removes deprecated transport
# code; deltalake 0.21+ supports MinIO endpoint via storage_options.
RUN pip install --no-cache-dir \
      "trino[sqlalchemy]==0.330.0" \
      "deltalake==0.21.0" \
      "duckdb==1.1.3" \
      "polars==1.13.1" \
      "pyarrow==17.0.0" \
      "s3fs==2024.10.0" \
      "boto3==1.35.50" \
      "kafka-python==2.0.2" \
      "ipywidgets==8.1.5" \
      "jupyterlab-git==0.50.2" \
      "openmetadata-ingestion[trino]==1.5.5" \
 && jupyter labextension list 2>/dev/null | grep -q jupyterlab-git \
 || true

# Bake the uwv_lab helper into site-packages. The base image ships exactly
# one /opt/conda/lib/python3.*/site-packages directory; we resolve it at
# build-time instead of relying on shell glob expansion (which would error
# if cp interprets multiple expansions as "copy into existing directory").
COPY infrastructure/jupyter/kernel-python/uwv_lab /tmp/uwv_lab_src
USER root
RUN PYSP="$(ls -d /opt/conda/lib/python3.*/site-packages | head -1)" \
 && cp -r /tmp/uwv_lab_src "$PYSP/uwv_lab" \
 && rm -rf /tmp/uwv_lab_src \
 && chown -R ${NB_UID}:${NB_GID} "$PYSP/uwv_lab"
USER ${NB_UID}

# Default working directory for notebooks. Mounted to a PVC at runtime so user
# work persists across pod restarts.
WORKDIR /home/${NB_USER}/work

# JupyterLab settings: enable the git extension surface by default.
COPY --chown=${NB_UID}:${NB_GID} infrastructure/jupyter/kernel-python/overrides.json \
     /opt/conda/share/jupyter/lab/settings/overrides.json

# Smoke check at build time — import everything once, fail the build if not.
RUN python -c "import trino, deltalake, duckdb, polars, s3fs, kafka, uwv_lab; print('uwv_lab kernel imports OK')"
