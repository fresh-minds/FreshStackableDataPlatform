# Compliance Mapping

Tabel met elke requirement uit
[`requirements-compliant-data-analyseplatform.md`](../requirements-compliant-data-analyseplatform.md)
gemapt op concrete maatregelen, fase waarin geleverd, en evidence (bestand of
setting). Status-kolom geeft fase 0-skeleton — `TBD` betekent "fase X levert
het bestand of de setting".

**Legend Fase**:
0 = repo & docs · 1 = cluster bootstrap · 2 = foundation services ·
3 = storage & query · 4 = ingestion · 5 = dbt & analytics · 6 = orchestratie ·
7 = BI · 8 = OpenMetadata · 9 = OPA-policies · 10 = compliance-evidence + e2e.

---

## NORA — Architectuur- en ontwerpprincipes

| R-* | Korte titel | Geleverd in | Evidence (path / setting) |
|---|---|---|---|
| R-NORA-01 | Eenmalig vastleggen, meervoudig gebruiken | 8 | OpenMetadata catalog (`platform/13-openmetadata-config/`); CGM glossary |
| R-NORA-02 | Open API's met versionering | 6, 10 | Trino REST API; OpenAPI spec voor toekomstige UC-10-gateway (`TBD`) |
| R-NORA-03 | Modulair en loosely coupled | 0, 1 | Stackable operators per component; ADR-0001 |
| R-NORA-04 | Open standaarden (Iceberg/Delta, Parquet, OpenAPI, OAuth2/OIDC) | 0, 1, 3 | `platform-config.yaml`, ADR-0002, Keycloak OIDC |
| R-NORA-05 | Vendor lock-in voorkomen | 0 | ADR-0001, ADR-0002 (table-format-abstractie) |
| R-NORA-06 | FAIR via data catalog | 8 | OpenMetadata services + glossary CGM |
| R-NORA-07 | Transparant, proactief, herleidbaar | 8, 9 | Lineage in OM; OPA decision logs |
| R-NORA-08 | Federatieve identiteit | 1 | Keycloak realm met OIDC; `infrastructure/helm/keycloak/` |
| R-NORA-09 | Semantische interoperabiliteit | 8 | OM Glossary "CGM" (`platform/13-openmetadata-config/glossary-cgm.yaml`) |

## AVG — Privacy & gegevensbescherming

| R-* | Korte titel | Geleverd in | Evidence |
|---|---|---|---|
| R-AVG-01 | Rechtsgrond per verwerking (art. 6/9) | 5, 9 | dbt `meta.legal_basis`; OPA-policy `trino-doelbinding.rego` |
| R-AVG-02 | Verwerkingsregister (art. 30) | 8, 10 | OM Custom Properties op data products; export naar CSV |
| R-AVG-03 | DPIA voor hoog risico | 0, 5 | `docs/use-cases/uc02-wajong-ai.md` placeholder; UC-04, UC-09 |
| R-AVG-04 | Verwerkersovereenkomsten | n/a | Buiten platform-scope (organisatorisch) |
| R-AVG-05 | Dataminimalisatie (selectie als config) | 5, 9 | dbt-models projecteren expliciet; OPA column masks |
| R-AVG-06 | Doelbinding per dataset | 5, 8, 9 | dbt `meta.doelbinding`; OM tag `Doelbinding.*`; OPA Rego |
| R-AVG-07 | Pseudonimisering & anonimisering | 5 | Macro `dbt/macros/pseudonymize.sql` (hash + zout) |
| R-AVG-08 | Bewaartermijnen | 5, 6 | dbt `meta.bewaartermijn_jaren`; Airflow retentie-DAG (`TBD` fase 6) |
| R-AVG-09 | Privacy by default (least privilege) | 9 | OPA default-deny voor `sensitive` catalog |
| R-AVG-10 | Inzage/rectificatie/verwijdering | 5, 6 | `gdpr_request` DAG; dbt-models met `bsn` als unique key |
| R-AVG-11 | SAR over alle datalagen | 8 | OM lineage tabel-/kolom-niveau |
| R-AVG-12 | Geautomatiseerde besluitvorming (art. 22) | 0, 5 | `docs/use-cases/uc02-*` mens-in-de-lus design; UC-03 |
| R-AVG-13 | Doorgifte buiten EER | 0 | n.v.t. — alle storage in cluster, regio `eu-nl-1` (`platform-config.yaml`) |
| R-AVG-14 | Datalocatie configureerbaar | 0 | `platform-config.yaml` `region`-tag |
| R-AVG-15 | Datalek-detectie 72u | 1, 9 | Vector → OpenSearch + Prometheus alerts; runbook (`TBD` fase 10) |

## BIO/BIO2 — Informatiebeveiliging

| R-* | Korte titel | Geleverd in | Evidence |
|---|---|---|---|
| R-BIO-01 | ISMS conform ISO 27001 | n/a | Buiten platform-scope (organisatorisch) |
| R-BIO-02 | Risicoanalyse met BIV-classificatie | 8 | OM Classification `BIO.BIV.*` per dataset |
| R-BIO-03 | Verklaring van Toepasselijkheid | n/a | Buiten platform-scope |
| R-BIO-04 | Periodieke audits | 10 | `docs/runbook.md` audit-procedure (`TBD`) |
| R-BIO-05 | Centraal IAM + MFA | 1 | Keycloak realm export, MFA-flow (`TBD` fase 1) |
| R-BIO-06 | RBAC/ABAC + recertificering | 9 | OPA Rego policies per rol; recertificering buiten scope |
| R-BIO-07 | Privileged Access Management | n/a | Buiten platform-scope (sessie-recording etc.) |
| R-BIO-08 | Service-accounts via secrets manager | 1, 2 | Stackable secret-operator + cert-manager |
| R-BIO-09 | Encryption at rest + TLS 1.2+ | 1, 2 | MinIO server-side encryption; Stackable AuthenticationClass TLS |
| R-BIO-10 | Sleutelbeheer (HSM/KMS, BYOK) | n/a | Buiten scope dev-cluster (productie: KMS) |
| R-BIO-11 | Column-/row-level security + masking | 9 | `opa-policies-src/trino/trino-row-filters.rego`, `trino-column-masks.rego` |
| R-BIO-12 | Verplichte dataclassificatie | 4, 8 | NiFi UpdateAttribute PII-tagging; OM Classifications |
| R-BIO-13 | Netwerksegmentatie + zero-trust | 1, 2 | NetworkPolicies per namespace (`TBD` fase 2) |
| R-BIO-14 | Hardening + IaC + policy-as-code | 0, 1 | Helm/Kustomize manifests; OPA voor data-laag |
| R-BIO-15 | Vulnerability management | 10 | CI scan met Trivy (`ci/github-actions/`) |
| R-BIO-16 | Endpoint protection | n/a | Buiten platform-scope |
| R-BIO-17 | Secure SDLC (SAST/DAST/SCA) | 10 | GitHub Actions met `ruff`, `opa test`, `dbt parse`, container-scans |
| R-BIO-18 | DTAP-scheiding + synthetische testdata | 0, 4 | `data-generation/` synthetische generators; aparte clusters per omgeving (`TBD`) |
| R-BIO-19 | Change management + GitOps | 10 | GitHub Actions; ADR-flow in `docs/adr/` |
| R-BIO-20 | Centrale logging onveranderbaar (≥6 mnd) | 1 | Vector → OpenSearch retention-config (`TBD` fase 1) |
| R-BIO-21 | SIEM/SOC-integratie | n/a | Out-of-cluster connector (placeholder) |
| R-BIO-22 | Incident response plan | 10 | `docs/runbook.md` |
| R-BIO-23 | Backup 3-2-1 + immutable | 10 | MinIO Object-Lock + Postgres dumps (`TBD` fase 10) |
| R-BIO-24 | RTO/RPO + DR-tests | 10 | `docs/runbook.md` (`TBD`) |

## NIS2 — Cyberweerbaarheid

| R-* | Korte titel | Geleverd in | Evidence |
|---|---|---|---|
| R-NIS2-01 | Bestuurlijke verantwoordelijkheid | n/a | Organisatorisch |
| R-NIS2-02 | All-hazards risicomanagement | n/a | Organisatorisch |
| R-NIS2-03 | Supply chain security (SBOM) | 10 | `cosign verify` + Stackable SBOM in CI |
| R-NIS2-04 | Meldplicht 24/72u/1mnd | 10 | `docs/runbook.md` incident-procedure |
| R-NIS2-05 | Vulnerability disclosure-beleid | 10 | `SECURITY.md` (`TBD`) |
| R-NIS2-06 | MFA voor kritieke systemen | 1 | Keycloak (TOTP) |
| R-NIS2-07 | Versleutelde communicatie | 1, 2 | TLS overal (cert-manager + secret-operator) |
| R-NIS2-08 | Awareness en training | n/a | Organisatorisch |
| R-NIS2-09 | Crisismanagement / BCM | 10 | `docs/runbook.md` |
| R-NIS2-10 | Effectiviteitsmeting (KPI's) | n/a | Organisatorisch |

## Data governance, kwaliteit, metadata

| R-* | Korte titel | Geleverd in | Evidence |
|---|---|---|---|
| R-GOV-01 | Eigenaarschap per data product | 5, 8 | dbt `meta.eigenaar`; OM owner per service |
| R-GOV-02 | Catalog incl. classificatie/lineage/SLA | 8 | OM service + glossary + classifications |
| R-GOV-03 | OpenLineage end-to-end | 8 | OM lineage workflow (Trino + dbt + Airflow + Superset) |
| R-GOV-04 | Datakwaliteits-SLO's + tests | 5, 8 | dbt-tests; OM Profiler; UC-07 |
| R-GOV-05 | Master data management | 5 | Marts UC-05 (cliënt 360°); polisadm seeds |
| R-GOV-06 | Policy-as-code | 9 | OPA Rego bundle |
| R-GOV-07 | Data contracts | 5 | dbt schema.yml + tests; expliciete `meta` |

## Functioneel

| R-* | Korte titel | Geleverd in | Evidence |
|---|---|---|---|
| R-FUN-01 | Batch + micro-batch + streaming ingestie | 4 | NiFi (batch) + Kafka + Spark Streaming |
| R-FUN-02 | Schema-validatie + quarantine | 4 | NiFi quarantine-flow; dbt-tests |
| R-FUN-03 | PII-detectie at ingest | 4 | NiFi UpdateAttribute + OM Auto-Classification |
| R-FUN-04 | Lakehouse-medallion + ACID | 3, 4 | Delta-tabellen op MinIO + Hive Metastore |
| R-FUN-05 | Compute/storage gescheiden | 0 | Stackable Trino + MinIO; ADR-0001 |
| R-FUN-06 | Time travel / versionering | 4, 6 | Delta `VERSION AS OF`; maintenance-DAG |
| R-FUN-07 | Self-service BI met semantische laag | 7 | Superset + dbt-marts |
| R-FUN-08 | MLOps (registry, feature store, monitoring) | 5 (placeholder) | UC-02 placeholder; volledig MLOps buiten scope |
| R-FUN-09 | Verklaarbaarheid + bias-toetsing | 5 (placeholder) | UC-02/UC-03 documentatie |
| R-FUN-10 | AI Act-aansluiting | 8 | OM Classification `AI.Risk.{laag,midden,hoog,verboden}` |
| R-FUN-11 | API-management | 10 | UC-10 spec; gateway-implementatie buiten fase 0–10 |
| R-FUN-12 | Event-gedreven + schema registry + DLQ | 4 | Kafka + dead-letter topic in Spark-job |

## Niet-functioneel

| R-* | Korte titel | Geleverd in | Evidence |
|---|---|---|---|
| R-NF-01 | SLO + multi-AZ | n/a | Buiten dev-scope |
| R-NF-02 | Schaalbaarheid | 0, 1 | Stackable replica-config; scaled-down voor k3d |
| R-NF-03 | Observability (metrics/logs/traces) | 1, 8 | Prometheus + Vector + OpenTelemetry |
| R-NF-04 | FinOps | n/a | Out-of-scope |
| R-NF-05 | Duurzaamheid | n/a | Out-of-scope (productie-keuze) |
| R-NF-06 | WCAG 2.2 AA | 7 | Superset config (`TBD` — afhankelijk van versie) |
| R-NF-07 | Documentatie + ADRs + runbook | 0–10 | `docs/adr/`, `docs/runbook.md`, READMEs per module |

## Compliance / audit

| R-* | Korte titel | Geleverd in | Evidence |
|---|---|---|---|
| R-COMP-01 | GRC-mapping actueel | 0–10 | Dit document |
| R-COMP-02 | Pentests / red-team | n/a | Organisatorisch |
| R-COMP-03 | Externe assurance (ISO/SOC2) | n/a | Organisatorisch |
| R-COMP-04 | DPIA/ISMS/risico onderhoud | 0 | UC-02/UC-04 placeholders verwijzen naar DPIA-flow |
| R-COMP-05 | Toezichthouder-readiness | 10 | Evidence-pakket via `make compliance-evidence` (`TBD`) |
