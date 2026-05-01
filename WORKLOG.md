# WORKLOG

Per sessie: wat gedaan, wat openstaand, welke beslissingen.

---

## 2026-04-30 — Sessie 1: Fase 0 (bootstrap + docs)

### Gedaan
- Vier achtergronddocumenten gelezen + samengevat (`docs/context-summary.md`).
- Antwoorden gebruiker verwerkt:
  - Tabelformaat **Delta Lake** (afwijking van ADR-0002 default Iceberg) → ADR-0006.
  - Doel-cluster: lokaal **k3d**.
  - Image registry: publiek pullen.
  - DNS: `*.uwv-platform.local` via /etc/hosts.
  - TLS: cert-manager self-signed.
  - Resource-budget: scaled-down profiel.
  - CI/CD: GitHub Actions (placeholder voor later).
  - Datavolume: 10k synthetische cliënten.
  - UC-02 Wajong: placeholder met TODO.
  - OpenSearch: één gedeeld single-node cluster.
  - Air-gapped: nee, pullen mag.
- Repo-structuur (alle directories per master prompt §4) aangemaakt.
- Toplevel files: `platform-config.yaml`, `.gitignore`, `LICENSE` (Apache 2.0), `README.md`, `Makefile`, `.editorconfig`.
- `infrastructure/k3d/k3d-cluster.yaml` (scaled-down, Traefik uit).
- 6 ADRs (`0001`..`0006`).
- 10 use-case specs (`uc01`..`uc10`).
- `docs/architecture.md`, `docs/compliance-mapping.md` (skeleton met R-* ↔ fase-mapping), `docs/runbook.md` (skeleton).

### Open / volgende sessie
- Fase 2 — foundation services: namespaces, secrets, S3Connection, ZooKeeper, HiveCluster, KafkaCluster.

### Beslissingen
- **Delta** geadopteerd ondanks lagere ADR-0002 score: gebruiker-voorkeur. Mitigatie: NiFi schrijft naar Kafka (niet rechtstreeks naar Delta), Spark Structured Streaming doet de Delta-write. Zie ADR-0006.
- **OpenSearch single-node** volstaat voor scaled-down. Vector logs én OpenMetadata-search delen het cluster (één index-prefix per consument).
- **Trino-catalogs heten format-onafhankelijk**: `bronze`, `silver`, `gold`, `sensitive` (niet `delta_bronze`). Switching naar Iceberg vraagt alleen template-render + redeploy.
- **GitHub Actions** komt later; voor nu alleen `ci/github-actions/.gitkeep` en `ci/yamllint.yaml`.

---

## 2026-05-01 — Sessie 2: Fase 1 (cluster bootstrap)

### Gedaan
- **Helm values per chart** (`infrastructure/helm/`):
  - `cert-manager/values.yaml` + `cluster-issuer.yaml` (self-signed CA `uwv-platform-issuer` voor `*.uwv-platform.local`).
  - `ingress-nginx/values.yaml` (k3d LB → :8080/:8443).
  - `minio/values.yaml` (single-node, 7 buckets aangemaakt via chart-job, ingress voor API + Console).
  - `postgresql/values.yaml` (single-instance, init-script maakt `hivemetastore`/`airflow`/`superset`/`openmetadata`/`keycloak` databases aan).
  - `keycloak/values.yaml` (externe Postgres, realm-import via ConfigMap, ingress).
  - `prometheus-stack/values.yaml` (Prometheus + Grafana, Alertmanager uit, scaled-down).
  - `vector/values.yaml` (Agent-mode, OpenSearch sink — fase 8).
  - `openmetadata/values.yaml` (gedeelde Postgres + OpenSearch, OIDC via Keycloak — fase 8).
- **Keycloak UWV-realm** (`infrastructure/helm/keycloak/realm-uwv.json`): 11 realm-rollen (de 8 mock-rollen + `researcher`, `smz_planner`, `proactief_dienstverlener`), één mock-user per rol, 5 OIDC-clients (trino, superset, airflow, nifi, openmetadata) met dev-only secrets en redirect-URIs op `*.uwv-platform.local:8443`.
- **Stackable release pin** (`infrastructure/stackablectl/release.yaml` — SDP 26.3 alle 12 operators) + `stack.yaml` (verwijst naar `platform/00..13`).
- **Scripts** (`scripts/`): `cluster.sh`, `bootstrap.sh` (idempotente helm upgrade --install volgorde: cert-manager → ClusterIssuer → ingress-nginx → Postgres → MinIO → Keycloak → Prometheus → Stackable operators), `clean.sh`, `doctor.sh` (tooling + /etc/hosts check), `port-forward.sh`, `run-smoke-tests.sh`, `deploy-platform.sh` (stub voor fase 2+), `seed.sh` (stub voor fase 4+). Allemaal `chmod +x`.
- **Smoke test** `tests/smoke/01-stackable-up.sh`: cluster, namespaces, helm-releases, ClusterIssuer Ready, MinIO buckets, Stackable operator pods, Keycloak OIDC discovery.
- `ci/yamllint.yaml` + `ci/github-actions/.gitkeep`.

### Open / volgende sessie
- Fase 2 — foundation services: `platform/00-namespaces` (uwv-platform/data/meta/monitoring annotaties), `01-secrets` (s3-credentials SecretClass), `02-authentication` (AuthenticationClass voor Keycloak OIDC), `03-storage` (S3Connection naar MinIO), `04-zookeeper` (ZookeeperCluster), `05-hive-metastore` (HiveCluster met Postgres-backed metadata DB), `06-kafka` (KafkaCluster). Daarna smoke `02-trino-query.sh` (fase 3 trigger).

### Beslissingen
- **Scaled-down Postgres single-instance** met meerdere databases (HMS, Airflow, Superset, OM, Keycloak). Productie: aparte instances per consumer.
- **Self-signed CA** (`uwv-platform-issuer`) als ClusterIssuer voor alle `*.uwv-platform.local` certificates. CA-cert blijft in `cert-manager` namespace; in browsers moet de CA expliciet vertrouwd worden voor lokaal gebruik.
- **Bitnami charts** voor PostgreSQL en Keycloak ondanks recente licentie-vragen — voor referentie volstaat de Apache 2.0 chart; voor productie cnpg-operator of Keycloak-operator overwegen.
- **Dev-only credentials** zijn hardcoded in `values.yaml` met expliciete `uwv-dev-only-CHANGE-ME-*` prefix. Bootstrap.sh logt een warning. ADR voor secret-handling in productie wordt later geschreven.
- **MinIO bucket-creation** via chart's eigen post-install hook (`buckets:`-array in values). Voorkomt extra mc-job manifest.
- **ingress-nginx** is THE ingress-controller; Stackable's listener-operator (fase 2) blijft voor Stackable-services voor in-cluster service-discovery, ingress-nginx voor externe routes.
