# 13-openmetadata-config

UWV-specifieke configuratie voor OpenMetadata: classifications (PII / Health /
Confidentiality / BIO / LegalBasis / Doelbinding / AI), CGM-glossary, en
service-connection definities voor Trino / dbt / Superset / Airflow / Kafka.

## Bestanden

| Bestand | Doel |
|---|---|
| [classifications-uwv.yaml](classifications-uwv.yaml) | 7 classifications met ~50 tags totaal — PII, Health.Article9, BIO.BIV, LegalBasis, Doelbinding, AI.Risk-\*. |
| [glossary-cgm.yaml](glossary-cgm.yaml) | CGM-glossary met ~22 termen uit referentiearchitectuur Bijlage B. |
| [services/trino-service.yaml](services/trino-service.yaml) | Trino DatabaseService config — schema-filter dekt alle UWV-catalogs. |
| [services/trino-lineage.yaml](services/trino-lineage.yaml) | Lineage-workflow uit Trino query-history. |
| [services/trino-profiler.yaml](services/trino-profiler.yaml) | Profiler op silver.\* (kolom-statistieken voor UC-07). |
| [services/dbt-workflow.yaml](services/dbt-workflow.yaml) | dbt-manifest workflow (leest s3://uwv-meta/dbt/latest/). |
| [services/superset-service.yaml](services/superset-service.yaml) | Dashboard-ingestion. |
| [services/airflow-service.yaml](services/airflow-service.yaml) | Pipeline-ingestion. |
| [init-job.yaml](init-job.yaml) | ConfigMap + Job die classifications + glossary toepast via OM REST API. |
| [kustomization.yaml](kustomization.yaml) | Bundelt alles + bouwt ConfigMap `openmetadata-uwv-config`. |

## Pre-requisites

- OpenMetadata Helm-installed in `uwv-meta` (zie `infrastructure/helm/openmetadata/`).
- OpenSearch single-node draait (gedeeld met Vector logs).
- Postgres `openmetadata` database init (via fase 1 init-script).
- JWT-token voor admin: `metadata generate-token` na bootstrap; resultaat in Secret `openmetadata-admin.jwtToken`.

## SSO via Keycloak

OpenMetadata is gekoppeld aan Keycloak met de `openmetadata` confidential
client (zie [`infrastructure/helm/keycloak/realm-uwv.json`](../../infrastructure/helm/keycloak/realm-uwv.json) regel ~458).
Configuratie zit in [`infrastructure/helm/openmetadata/values.yaml`](../../infrastructure/helm/openmetadata/values.yaml) onder `openmetadata.config.authentication`:

| Veld | Waarde |
|---|---|
| `clientType` | `confidential` |
| `provider` | `custom-oidc` |
| `authority` | `https://keycloak.uwv-platform.local:8443/realms/uwv` |
| `callbackUrl` | `https://openmetadata.uwv-platform.local:8443/callback` |
| `clientId` | `openmetadata` |
| `oidcConfiguration.secret` | refereert naar Secret `openmetadata-oidc-client` |

Het client-secret zit in K8s Secret `openmetadata-oidc-client` (NS `uwv-meta`,
zie [`platform/01-secrets/dev-secrets.yaml`](../01-secrets/dev-secrets.yaml)) en moet identiek zijn
aan de `secret`-waarde in `realm-uwv.json` voor de `openmetadata` client.

Initial admins (aangemaakt bij eerste login via Keycloak): `data.steward`,
`platform.admin`. Andere users krijgen viewer-rechten — promoten via OM UI.

### Java truststore (k3d only)

De OM-pod doet server-side een token-exchange tegen het ingress-nginx
TLS-endpoint (zelf-signed CA via cert-manager). Een initContainer mountt
[`uwv-ca-bundle`](../../scripts/bootstrap.sh) (kopie uit `uwv-platform` NS) en
importeert `ca.crt` in een fresh JKS truststore op `/shared-truststore/cacerts`,
die de OM-container via `JAVA_TOOL_OPTIONS` activeert. Op AKS is dit niet nodig
(zie [`infrastructure/azure/helm-overrides/openmetadata-values-aks.yaml`](../../infrastructure/azure/helm-overrides/openmetadata-values-aks.yaml) — de CA is van een echte CA).

### Chart-quirks die we werken om

Drie issues in de upstream `open-metadata/openmetadata` 1.5.0 chart die
[`scripts/bootstrap.sh`](../../scripts/bootstrap.sh) na de install moet
opvangen:

1. **`mysql-secrets` hardcoded.** Chart verwacht een Secret met key
   `openmetadata-mysql-password`, ook als de database `postgres` is. Wordt
   vóór de helm-install aangemaakt.
2. **`openmetadata.config.openmetadata.host` default = `openmetadata`.** Dat
   DNS-resolveert naar de Service ClusterIP en de pod kan daar niet aan
   binden → `BindException: Address not available`. Override in
   [`values.yaml`](../../infrastructure/helm/openmetadata/values.yaml) naar `0.0.0.0`.
3. **`OIDC_CUSTOM_PARAMS` quote-bug.** Chart rendert via `{{ .customParams |
   quote | b64enc }}`, waardoor `{}` als de string `"{}"` in de env-var
   belandt en Jackson faalt op cast naar `LinkedHashMap`. Bootstrap patcht
   het Secret na de install zodat de env-var letterlijk `{}` is en herstart
   de pod.

## Apply

```bash
kubectl apply -k platform/13-openmetadata-config/
kubectl -n uwv-meta wait --for=condition=complete job/openmetadata-init --timeout=10m
```

## Wat doet de init-Job

1. Wacht tot OM `/api/v1/system/version` 200 retourneert.
2. POST per classification (en bijbehorende tags).
3. POST glossary CGM + alle terms.

**Niet** gedaan door deze Job: ingestion-runs voor Trino/dbt/Superset/Airflow/Kafka.
Die zijn in de `services/*.yaml` configs gedefinieerd en worden door Airflow-DAGs
[`platform/11-airflow/dags/om_ingest_*.py`](../11-airflow/dags/) gescheduled.

## Verificatie

```bash
# Lijst classifications
TOKEN=$(kubectl -n uwv-meta get secret openmetadata-admin -o jsonpath='{.data.jwtToken}' | base64 -d)
kubectl -n uwv-meta port-forward svc/openmetadata 8585:8585 &
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8585/api/v1/classifications" | jq '.data[].name'

# Lijst glossary terms
curl -s -H "Authorization: Bearer $TOKEN" \
  "http://localhost:8585/api/v1/glossaryTerms?glossary=CGM" | jq '.data[].name'
```

## Productie

- JWT-tokens roteren via External Secrets + Vault (geen statische tokens in Secrets).
- Auto-classification AAN — laat OM zelf BSN-patronen detecteren naast de declaratieve tags.
- Reverse Metadata aan zetten zodat OM-tags terug naar Trino propageren → voedsel voor OPA-policies (fase 9).
- DLM (Data Lifecycle Manager) configureren met `bewaartermijn_jaren`-meta uit dbt-models.
