# UWV dbt-trino image — bakt het hele dbt-project + dbt_packages in.
#
# Cosmos's ExecutionMode.KUBERNETES draait elke dbt-task in een verse pod.
# Mounten via ConfigMap is geen optie omdat dbt_packages > 1 MiB. Daarom
# bouwen we het project één keer in een image; rebuild bij dbt-wijzigingen.
#
# Build (vanuit repo-root):
#   docker build -t uwv/dbt-trino:1.9.0-uwv -f infrastructure/airflow/dbt/Dockerfile dbt
#   k3d image import uwv/dbt-trino:1.9.0-uwv -c uwv-platform
#
# of via de Makefile:  make dbt-image
#
# SYNTHETIC DATA — UWV REFERENCE PLATFORM — NOT FOR REAL USE.
#
# Base-image: lokaal gebakken `uwv/dbt-trino:1.9.0` (al aanwezig na bootstrap;
# upstream `ghcr.io/dbt-labs/dbt-trino:1.9.0` vereist auth bij anonymous pull).
FROM uwv/dbt-trino:1.9.0

# dbt-fabricspark voor de UC-11 multi-platform demo (gold-marts op Fabric
# Lakehouse via Livy). 1.12 hangt op dbt-core>=1.8 wat compatibel is met de
# 1.9-base. Layer vóór de project-COPY zodat hercopiëren niet hoeft te
# reïnstalleren.
RUN pip install --no-cache-dir 'dbt-fabricspark==1.12.*'

# Project komt op /opt/uwv/dbt/ — zelfde pad als waarvoor silver_factory en
# gold_factory's ProjectConfig zijn geconfigureerd (UWV_DBT_PROJECT_PATH).
WORKDIR /opt/uwv/dbt

# Kopieer de dbt-project bron (incl. dbt_packages/ en profiles.yml.template).
# .dockerignore zorgt dat target/ en logs/ niet meegaan.
COPY . /opt/uwv/dbt/

# profiles.yml is omgevings-specifiek — Cosmos genereert deze on-the-fly via
# TrinoCertificateProfileMapping. Verwijderen om verwarring te voorkomen.
RUN rm -f /opt/uwv/dbt/profiles.yml || true

# Cosmos LoadMode.DBT_MANIFEST verwacht een vooraf gerenderd manifest.json.
# Dit is omgevings-specifiek (env_vars resolven), dus niet bakken in image.
# Het manifest blijft uit ConfigMap `dbt-manifest` komen via init container.

# Cosmos 1.6 KubernetesExecutionMode injecteert geen profiles.yml in de
# task-pod. Bakken we 'm zelf in: pre-rendered profile met env-var defaults
# voor host/user/port. cert=false omdat de cert-manager CA niet in dit image
# zit — in-cluster dev only.
COPY profiles.yml /root/.dbt/profiles.yml
