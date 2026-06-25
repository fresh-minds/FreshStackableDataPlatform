# Runbook

Operationele handleiding voor het draaien, monitoren, herstellen en uitbreiden
van het UWV Reference Data Platform. Dekt cluster-lifecycle, component-
healthchecks, 6 incident-scenario's, backup & restore (Postgres + MinIO +
Keycloak), upgrade-procedures (operators, Helm-charts, dbt-packages,
Kubernetes), synthetische data-reseed, OPA-policy-deploy, observability +
alert-tuning en compliance-evidence-collectie.

---

## 1. Snelstart

Zie [`README.md`](../README.md) voor de happy-path commands.

---

## 2. Cluster lifecycle

### 2.1 Cluster opzetten

```bash
# Lokaal (k3d):
make cluster MODE=k3d       # k3d cluster create + kubeconfig
make bootstrap MODE=k3d     # cert-manager, SeaweedFS (k3d) / MinIO (cloud), Postgres, Keycloak, Stackable operators
make deploy-platform MODE=k3d

# Azure (aks):
make aks-all                 # = aks-up + aks-context + aks-bootstrap + aks-deploy + aks-smoke

# StackIT (SKE):
make stackit-all             # = stackit-up + stackit-bootstrap + stackit-deploy + portal + smoke
```

`make cluster` zelf is k3d-only (zie `Makefile` § cluster); voor cloud
gebruik je de `<mode>-up`-targets die Terraform draaien.

### 2.2 Cluster pauzeren / hervatten

| Mode | Hoe |
|---|---|
| `k3d` | `k3d cluster stop uwv-platform` / `… start`; `scripts/cluster.sh` regelt de kubelet-TLS-swap automatisch op stopped→start. |
| `aks` | Stop-deallocate van VMSS via Azure CLI; goedkoper is een nightly `terraform destroy` + ochtend `make aks-up`. |
| `stackit` | `make stackit-hibernate` zet workers naar 0 (control plane slaapt; PVCs + Floating IP blijven); `make stackit-wake` brengt 'm in ~3-5 min terug. `make stackit-status` toont `HIBERNATED`/`HEALTHY`/`RECONCILING`. |

### 2.3 Cluster volledig opruimen
```bash
make clean          # k3d cluster delete uwv-platform
```

---

## 3. Component-status checken

| Component | Health-check command |
|---|---|
| k3d nodes | `kubectl get nodes` |
| Stackable operators | `kubectl get pods -n stackable-operators` |
| Trino | `kubectl get trinocluster -A` |
| Hive Metastore | `kubectl get hivecluster -A` |
| OPA | `kubectl get opacluster -A` |
| Airflow | `kubectl get airflowcluster -A` |
| Superset | `kubectl get supersetcluster -A` |
| OpenMetadata | `kubectl get pods -n uwv-meta` |
| Keycloak | `kubectl get pods -n uwv-auth` |

TODO (fase 2+): vul per component de specifieke "is-het-gezond?" probes in.

---

## 4. Veelvoorkomende incidenten

### 4.1 Trino weigert query met "Access Denied"
- Eerst: log inspecteren — `kubectl logs -n uwv-platform <trino-coordinator-pod> -c trino`.
- OPA-decision-log bekijken in OpenSearch.
- Verifieer rol-toekenning in Keycloak voor de gebruiker.
- TODO (fase 9): voorbeeldqueries per rol.

### 4.2 dbt-run faalt met "table not found"
- Check Hive Metastore: `kubectl exec -it -n uwv-platform <hive-pod> -- ...` (TODO: precieze syntax).
- Verifieer dat eerdere fase-runs (bronze/silver) geslaagd zijn.

### 4.3 Streaming-job blijft hangen
- Spark UI port-forwarden: `kubectl port-forward -n uwv-platform svc/spark-streaming-ui 4040:4040`.
- Checkpoint-bucket inspecteren: `mc alias set local http://minio.uwv-platform.local:80 ...`; `mc ls local/uwv-checkpoints/`.

### 4.4 Hive Metastore Postgres-corruption of readiness-fail

> Triggered by alert `HiveMetastoreDown` ([prometheusrule-uwv.yaml](../platform/14-monitoring/prometheusrule-uwv.yaml)).

Symptomen: Trino-queries falen met "Could not get metastore client",
Spark-jobs gooien `MetaException`, dbt parseert wel maar `run` blijft hangen.

```bash
# 1. Is HMS-pod ready?
kubectl -n uwv-platform get pods -l app.kubernetes.io/name=hive

# 2. Heeft HMS verbinding naar Postgres?
kubectl -n uwv-platform exec sts/uwv-hive-metastore-default -- \
  bash -c 'pg_isready -h postgres-postgresql.uwv-data.svc -U hive'

# 3. Hive schema-bootstrap-status (één-malig na restore):
kubectl -n uwv-platform exec sts/uwv-hive-metastore-default -- \
  bash -c 'schematool -dbType postgres -info'
```

**Recovery**:
- Connection-pool-uitputting → herstart HMS-pod: `kubectl -n uwv-platform rollout restart sts/uwv-hive-metastore-default`.
- Postgres-corruption → restore vanuit backup (zie §5.1) en daarna
  `schematool -dbType postgres -upgradeSchema` indien nodig.

### 4.5 Airflow scheduler stuck

> Triggered by alert `AirflowSchedulerHeartbeatLost`.

```bash
# 1. Scheduler-pod loggen
kubectl -n uwv-platform logs sts/uwv-airflow-scheduler-default --tail=200

# 2. Heartbeat-tijdstamp in metadata-DB
kubectl -n uwv-platform exec sts/uwv-airflow-scheduler-default -- \
  airflow db check

# 3. Heartbeat-table inspecteren
kubectl -n uwv-data exec sts/postgres-postgresql -- psql -U postgres -d airflow \
  -c "SELECT hostname, latest_heartbeat FROM job WHERE state='running' ORDER BY id DESC LIMIT 5;"
```

**Recovery**:
- DAG-parsetijden te lang → check `dagbag_import_timeout` + DAGs splitsen.
- Postgres-locked → kill long-running query: `pg_terminate_backend(pid)`.
- Cosmos-init stuck → restart pod: scheduler komt vanzelf terug.

### 4.6 TLS-cert rollover failed

> Triggered by alert `CertManagerCertExpiringSoon` / `CertManagerCertExpired`.

```bash
# 1. Welke certs zijn near-expiry?
kubectl get certificate -A -o json \
  | jq -r '.items[] | select(.status.notAfter)
           | "\(.metadata.namespace)/\(.metadata.name) → expires \(.status.notAfter)"'

# 2. CertificateRequest-events: waarom faalt renewal?
kubectl -n <ns> describe certificaterequest <cert-name>-<rev>

# 3. Issuer status
kubectl get clusterissuer uwv-platform-issuer -o yaml \
  | yq '.status.conditions'
```

**Recovery**:
- ACME challenge faalt → check ingress + DNS naar Let's Encrypt callback.
- Self-signed CA expired (over 10 jaar) → bump validity in `cluster-issuer.yaml`.
- Force renewal: `kubectl delete certificaterequest <name>-<rev>` →
  cert-manager maakt onmiddellijk een nieuwe aan.

---

## 5. Backup & restore

### 5.1 Postgres (alle 6 databases)

De shared Postgres-pod in `uwv-data` host `platform`, `hivemetastore`,
`airflow`, `superset`, `openmetadata`, `keycloak`. Een dagelijkse CronJob
draait om 03:17 UTC ([`postgres-backup-cronjob.yaml`](../platform/14-monitoring/postgres-backup-cronjob.yaml)):

- `pg_dumpall --clean --if-exists --no-role-passwords | gzip` → één bestand
- upload naar `s3://uwv-meta/backups/postgres/YYYY-MM-DD/dump-HHMMSS.sql.gz`
- retentie 30 dagen (oudere dumps worden weggegooid bij de volgende run)

Backup-status check:

```bash
kubectl -n uwv-data get cronjob postgres-backup
kubectl -n uwv-data get jobs --selector=job-name=postgres-backup-... \
  --sort-by=.metadata.creationTimestamp | tail -5
```

Ad-hoc backup forceren:

```bash
kubectl -n uwv-data create job --from=cronjob/postgres-backup \
  postgres-backup-manual-$(date +%s)
kubectl -n uwv-data logs -f job/postgres-backup-manual-...
```

**Restore** (drop + reload alle 6 databases):

```bash
# 1. Download de meest recente dump
kubectl -n uwv-data exec -it postgres-postgresql-0 -- bash
mc alias set local http://minio.uwv-platform.svc:9000 $S3_KEY $S3_SECRET
mc cp local/uwv-meta/backups/postgres/2026-05-21/dump-031701.sql.gz /tmp/

# 2. Stop alle clients (anders blokkeren ze de DROP DATABASE)
kubectl -n uwv-platform scale --replicas=0 \
  statefulset.apps/uwv-airflow-scheduler-default \
  statefulset.apps/uwv-airflow-webserver-default \
  statefulset.apps/uwv-superset-node-default \
  hivecluster.hive.stackable.tech/uwv-hive   # via operator-CR scale
kubectl -n uwv-meta scale deploy openmetadata --replicas=0
kubectl -n uwv-auth scale statefulset keycloak --replicas=0

# 3. Restore
gunzip -c /tmp/dump-031701.sql.gz | psql -U postgres

# 4. Bring everything back
kubectl -n uwv-platform scale --replicas=1 statefulset.apps/uwv-airflow-scheduler-default ...
```

> **RTO**: ~10 min voor één database, ~25 min volledige restore.
> **RPO**: max 24 uur (daily backup). Voor lagere RPO ofwel naar 4-hourly
> CronJob ofwel naar PostgreSQL streaming-replication (CNPG-operator).

### 5.2 Keycloak realm-export

Naast de Postgres-backup kun je een Keycloak-realm-export trekken (handig
om alleen een specifieke realm te restoren zonder full Postgres-restore):

```bash
kubectl -n uwv-auth exec -it sts/keycloak -- /opt/keycloak/bin/kc.sh \
  export --realm uwv --file /tmp/uwv-realm.json --users realm_file
kubectl -n uwv-auth cp keycloak-0:/tmp/uwv-realm.json ./uwv-realm-$(date -u +%Y%m%d).json
```

Restore: drop de bestaande realm in UI, dan import met de UI-file-uploader of:

```bash
kubectl -n uwv-auth cp ./uwv-realm-20260520.json keycloak-0:/tmp/
kubectl -n uwv-auth exec sts/keycloak -- /opt/keycloak/bin/kc.sh \
  import --file /tmp/uwv-realm-20260520.json
```

### 5.3 Object store (lakehouse objects)

De object-store houdt de echte data (Delta-tables, raw JSONL, dbt-artefacts).
**Per mode anders** (zie [ADR-0011](adr/0011-seaweedfs-replaces-minio.md)):
- **k3d**    → SeaweedFS (single-replica master+filer+volume+s3)
- **aks/stackit** → MinIO (single-node — follow-up: migreer naar SeaweedFS)

Voor single-node deployments is er **geen ingebouwde snapshot** — dump
strategieën:

- **`aws s3 sync` of `rclone`** naar een externe S3-bucket (cron/CronJob).
  Werkt tegen beide backends:
  ```bash
  # Beide nemen ENDPOINT + access/secret. SeaweedFS:
  aws --endpoint-url https://s3.uwv-platform.local:8443 s3 sync \
      s3://uwv-bronze /backup/uwv-bronze
  # MinIO (cloud-modes): zelfde commando, andere endpoint.
  ```
- **Velero + restic** voor volledige cluster-volume backup (zie §5.4).
- **Productie**: switch naar distributed mode (`volume.replicas: 3` +
  `replication: "010"` voor SeaweedFS, of MinIO distributed `replicas: 4`
  met EC). Beide kunnen Object Lock toepassen voor immutable retention —
  dat lost backup ÉN audit-onveranderbaarheid op (R-AVG-15).

### 5.4 Cluster-state (kubernetes objects)

Voor disaster-recovery van K8s-resources zelf (CRDs, ConfigMaps, Secrets):

- Repo (GitOps) is de canonieke bron — `make deploy MODE=aks` herbouwt
  alles vanuit `platform/` + `platform-overlays/aks/`.
- Voor "tussentijdse" state (handmatige patches, Stackable status):
  installeer [Velero](https://velero.io/) en draai
  ```bash
  velero schedule create daily-backup --schedule="0 4 * * *" \
    --include-namespaces uwv-platform,uwv-data,uwv-meta,uwv-auth,uwv-monitoring \
    --ttl 720h
  ```
  → 30 dagen retentie.

### 5.5 Trino state

Statelos (geen PVC's, geen DB). Restore = `kubectl rollout restart`.

---

## 6. Upgrade-procedure

### 6.1 Stackable-operators (26.3 → 27.x)

Volg de [Stackable release notes](https://docs.stackable.tech/home/stable/release_notes/)
voor breaking changes per operator. Algemene flow:

```bash
# 1. Bump versie in infrastructure/stackablectl/release.yaml
sed -i 's/releaseVersion: "26\.3\.0"/releaseVersion: "27.0.0"/' \
  infrastructure/stackablectl/release.yaml
# en per operator-versie hetzelfde.

# 2. Test in een k3d-mode:
make clean && make deploy MODE=k3d

# 3. Test smoke + e2e:
make smoke
make e2e

# 4. Bump op cloud (eerst stackit, daarna aks):
make deploy-platform MODE=stackit
make smoke MODE=stackit

# 5. Repo commit + tag:
git commit -am "feat(stackable): upgrade to 27.0.0"
git tag v0.7.0
```

> **Belangrijk**: de Stackable-operator update produceert vaak rollende
> restarts van Trino/Airflow/Hive. Plan een onderhoudsvenster.

### 6.2 Helm-chart bumps (cert-manager, postgresql, openmetadata, …)

Versies zijn gepind in [`scripts/bootstrap.sh`](../scripts/bootstrap.sh)
(env-vars `CERT_MANAGER_VERSION`, `POSTGRES_VERSION`, etc.).

```bash
# 1. Update env-var in bootstrap.sh + run helm-diff
# (helm-diff plugin: helm plugin install https://github.com/databus23/helm-diff)
helm diff upgrade cert-manager jetstack/cert-manager \
  -n cert-manager --version v1.17.0 \
  -f infrastructure/helm/cert-manager/values.yaml

# 2. Apply
make bootstrap MODE=k3d
```

Dependabot stuurt PR's voor versie-bumps in `infrastructure/helm/*/Chart.yaml`
(zie [`.github/dependabot.yml`](../.github/dependabot.yml)) — review per chart.

### 6.3 dbt-packages

```bash
cd dbt
# Bump dbt/packages.yml versies, daarna:
dbt deps
dbt parse                          # validate
python ci/scripts/check-dbt-tests.py  # validate test-coverage niet daalt
git commit -am "chore(dbt): bump dbt-utils to 1.4.0"
```

### 6.4 Kubernetes-cluster-versie (AKS / StackIT)

AKS pakt patch-versies automatisch (`ignore_changes = [kubernetes_version]`
in [`main.tf`](../infrastructure/azure/terraform/main.tf)).
Minor-bumps via terraform:

```bash
cd infrastructure/azure/terraform
export TF_VAR_kubernetes_version="1.32.2"
terraform plan
terraform apply
```

Bij een minor-bump ALTIJD eerst in `dev-stackable-rg`, dan productie.

---

## 7. Synthetische data herladen

```bash
make seed
```

Dit:
1. Genereert 10k synthetische cliënten + bijbehorende entiteiten in `data-generation/output/`.
2. Pusht ze als JSONL naar `s3://uwv-raw/<domain>/<entity>/dt=YYYY-MM-DD/`.
3. Triggert dbt-run (in een Airflow-DAG) die silver + gold rebuilt.

### 7.1 Ingestion-debug-checklist

Wanneer een `make seed` niet doorkomt tot in de marts:

```bash
# 1. Staan de raw JSONL files in MinIO?
kubectl -n uwv-platform exec deploy/mc-pod -- mc ls local/uwv-raw/

# 2. Heeft Airflow de seed-DAG getriggerd?
kubectl -n uwv-platform exec sts/uwv-airflow-webserver-default -- \
  airflow dags list-runs -d synthetic_data_load --state success --limit 1

# 3. Zijn de bronze tabellen in Hive zichtbaar?
kubectl -n uwv-platform exec sts/uwv-trino-coordinator-default -- \
  trino --execute "SHOW TABLES IN bronze.uwv;"

# 4. Heeft dbt de marts gebouwd?
kubectl -n uwv-platform exec sts/uwv-trino-coordinator-default -- \
  trino --execute "SELECT count(*) FROM gold.uc01_wia_funnel.fct_funnel;"
```

### 7.2 Volledige data-wipe + reseed

Soms wil je terug naar nul (bv. na schema-changes in een staging-model):

```bash
# Wipe bronze/silver/gold buckets (BEHOUD raw + checkpoints!)
kubectl -n uwv-platform exec deploy/mc-pod -- bash -c '
  mc rm --recursive --force local/uwv-bronze/
  mc rm --recursive --force local/uwv-silver/
  mc rm --recursive --force local/uwv-gold/
'

# Drop alle Hive-tabellen
kubectl -n uwv-platform exec sts/uwv-trino-coordinator-default -- \
  trino --execute "DROP SCHEMA bronze.uwv CASCADE; ..."

# Reseed
make seed
make dbt-build-uc11
```

### 7.3 Spark streaming-bronze stuck

Als `streaming-bronze` SparkApplication blijft hangen (zie ook
[`platform/08-spark/apps/streaming-bronze.yaml`](../platform/08-spark/apps/streaming-bronze.yaml)
header — momenteel uitgeschakeld in `kustomization.yaml`):

```bash
# Driver + executor pods inspecteren
kubectl -n uwv-platform get pods -l spark-app-name=streaming-bronze
kubectl -n uwv-platform logs <driver-pod> --tail=200

# Force restart: delete CR + opnieuw applyen
kubectl -n uwv-platform delete sparkapplication streaming-bronze
kubectl apply -k platform/08-spark/
```

> **MEMORY note** (uit `MEMORY.md`): `deleteOnTermination: false` laat
> zombie pods achter — gebruik `kubectl get pods` om ze handmatig op te
> ruimen.

---

## 8. OPA-policy bijwerken

```bash
# Edit Rego onder opa-policies-src/trino/
opa fmt -w opa-policies-src/
opa test opa-policies-src/

# Bouw bundle naar ConfigMap
bash scripts/build-opa-bundle.sh

# OPA herlaadt automatisch als label opa.stackable.tech/bundle=true gezet is.
```

TODO (fase 9): troubleshooting "policy lijkt niet actief".

---

## 9. Observability dashboards

- Grafana: `https://grafana.uwv-platform.local:8443`
- OpenSearch Dashboards: `https://opensearch.uwv-platform.local:8443`
- OpenMetadata: `https://openmetadata.uwv-platform.local:8443`
- Prometheus: `https://prometheus.uwv-platform.local:8443`
- Alertmanager: in-cluster only — `kubectl -n uwv-monitoring port-forward svc/prometheus-kube-prometheus-alertmanager 9093:9093`
- MailHog (k3d-only, dev-SMTP-sink): `https://mailhog.uwv-platform.local:8443/`

TODO (fase 1/8): default-credentials uit secrets ophalen, voorbeeld-queries.

### 9.1 Alert-pipeline overzicht

```
metrics  → Prometheus → AlertmanagerConfig → email (SMTP) → MailHog (k3d) / UWV-relay (aks)
logs     → Vector log_to_metric → Prometheus → ↑                          └→ Slack #uwv-data-platform
```

Definities:
- Metric-rules: [`platform/14-monitoring/prometheusrule-uwv.yaml`](../platform/14-monitoring/prometheusrule-uwv.yaml)
- Log-rules:    [`platform/14-monitoring/vector-log-alerts.yaml`](../platform/14-monitoring/vector-log-alerts.yaml)
- Receivers:    [`platform/14-monitoring/alertmanager-config.yaml`](../platform/14-monitoring/alertmanager-config.yaml) (k3d) / `platform-overlays/aks/14-monitoring/` (aks)
- Vector-config: [`infrastructure/helm/vector/values.yaml`](../infrastructure/helm/vector/values.yaml) (transforms `detect_alert_events` + `log_to_metric`)

### 9.2 Alert komt niet aan (debug-checklist)

1. **Is Alertmanager actief?** `kubectl -n uwv-monitoring get pods -l app.kubernetes.io/name=alertmanager` — verwacht `Running`.
2. **Is de AlertmanagerConfig geladen?** `kubectl -n uwv-monitoring get alertmanagerconfig uwv-platform-receivers -o yaml` — geen `status.error`.
3. **Vuren de regels?** `kubectl -n uwv-monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090` → http://localhost:9090/alerts.
4. **Komt Alertmanager bij de SMTP-host?** Alertmanager-pod-logs: `kubectl -n uwv-monitoring logs -l app.kubernetes.io/name=alertmanager --tail=100 | grep -i smtp`.
5. **MailHog in k3d** — UI op `https://mailhog.uwv-platform.local:8443/`. Geen mails? Check `kubectl -n uwv-monitoring logs deploy/mailhog`.

### 9.3 End-to-end alert-test

```bash
# Stuur synthetische warning-alert
make alert-test

# Critical-severity (route gaat ook naar Slack)
make alert-test ACTION=critical

# Resolve
make alert-test-resolve
```

Verwacht resultaat:
- k3d : verschijnt binnen ~30s in MailHog UI
- aks : verschijnt binnen ~30s in `platform-alerts@uwv.nl`

### 9.4 Log-based alert: OpaDecisionDenySpike

- Vector detecteert `"result":false` in OPA-logs (zie `detect_alert_events` in helm-values).
- Tellt counter `vector_uwv_alert_event_total{event="opa_deny"}`.
- PrometheusRule `uwv-log-events` vuurt op `rate(...) > 0.2/s` over 5m.
- Onderzoek: query OpenSearch op `uwv-logs-audit-*` met `result: false` filter, of zoek in Trino coordinator-logs welke gebruiker / catalog gewerd.

### 9.5 Log-based alert: JvmOutOfMemory

- Vector matcht `java.lang.OutOfMemoryError` ongeacht container.
- Critical-severity (geen `for:`-window) — vuurt direct na 1e OOM-event in 10m.
- Onderzoek: `kubectl -n {{namespace}} describe pod {{container}}` voor restart-count, vraag heap-size verhogen in de Stackable-CR (`spec.coordinator.config.resources.memory.limit` etc.).

### 9.6 Log-based alert: KeycloakLoginErrorSpike

- Vector matcht event-type `LOGIN_ERROR` in Keycloak-logs.
- Verwacht: doorgaans < 5 fails per minuut.
- Onderzoek: Keycloak admin-console → Events → filter op `LOGIN_ERROR`. Bij brute-force: zet rate-limit aan op ingress-nginx (`nginx.ingress.kubernetes.io/limit-rpm: "60"`).

### 9.7 Alert-pipeline end-to-end test

Zie §9.3. Zelfreferentie zodat alert-template-links niet 404 geven.

---

## 10. Compliance-evidence verzamelen

Zie [`compliance-mapping.md`](compliance-mapping.md). Elk R-* code heeft daar
een verwijzing naar het YAML-bestand of de configuratie waar de maatregel
landt.

### 10.1 Standaard-evidence per audit (R-* codes)

| Requirement | Hoe te bewijzen | Bestand / commando |
|---|---|---|
| R-AVG-06 (doelbinding) | OPA-policy + tests draaien | `make opa-test` → 35 assertions GREEN |
| R-AVG-07 (pseudonimisering) | Macro toepast op alle persoon-attributen | `grep -rn 'pseudonymize()' dbt/models/` |
| R-AVG-15 (breach-detection) | Audit-logs ≥ 7 jaar in OpenSearch | `kubectl -n uwv-meta get opensearchilmpolicy uwv-audit-7y` |
| R-BIO-05 (strong auth) | Keycloak password policy | `realm-uwv.json::passwordPolicy` |
| R-BIO-08 (secrets manager) | Geen plaintext secrets in repo | `git ls-files \| xargs grep -l 'CHANGE-ME' \|\| true` (verwacht: niets na ExternalSecrets-migratie) |
| R-BIO-09 (least privilege) | Pod-security: runAsNonRoot, readOnlyRootFS | `kubectl get pods -A -o json \| jq '.items[].spec.securityContext'` |
| R-BIO-11 (col-level security) | OPA column-masks tests | `make opa-test` → trino-column-masks_test.rego GREEN |
| R-BIO-13 (network segmentation) | NetworkPolicies actief op alle UWV-namespaces | `kubectl get networkpolicy -A \| wc -l` (verwacht ≥ 19 in cloud-mode) |
| R-BIO-15 (vuln-mgmt) | Trivy SARIF upload + SBOM artifacts | GitHub Actions: `security-scan.yml` + `sbom.yml` runs |
| R-BIO-20 (audit-retention) | OpenSearch ILM 7-jaar | `opensearch-ilm-job.yaml` |
| R-BIO-23 (3-2-1 backup) | Postgres backup CronJob + off-cluster mirror | `kubectl -n uwv-data get cronjob postgres-backup` |
| R-NIS2-03 (supply chain) | SBOM per release | GitHub Actions: artifact `sbom-*.cdx.json` per build |
| R-NIS2-04 (incident detect) | Alert-pipeline + runbook §9 | `make alert-test` |
| AI Act art. 11 (DPIA) | Per UC met `risk_tier: hoog` | `docs/use-cases/uc02-wajong-ai.md` etc. — DPIA-link in frontmatter |

### 10.2 Evidence-pakket genereren

!!! todo "Audit-bundle-script nog niet aanwezig"
    Een wrapper-script `scripts/compliance-evidence.sh` dat alle commando's
    uit §10.1 draait en de output in een ge-timestampte tarball bundelt staat
    op de roadmap. Voor nu: draai de tabel-commands handmatig en bundel zelf,
    bijvoorbeeld:
    ```bash
    mkdir -p evidence-$(date -u +%Y-%m-%d) && cd $_
    # …per regel uit §10.1 één output-file…
    cd .. && tar czf evidence-$(date -u +%Y-%m-%d).tar.gz evidence-*
    ```

### 10.3 Per-release audit-trail

Bij elke release-tag (`v0.X.Y`):

1. SBOMs worden geattacheerd aan de GitHub Release (zie `sbom.yml`).
2. Trivy-scan rapport landt in GitHub Security tab via SARIF (CodeQL-upload).
3. ADRs vermelden welke compliance-eisen geraakt worden.
4. WORKLOG.md krijgt een release-entry met:
   - aanpassingen aan policies / secrets / dependencies
   - DPIA-status per AI-UC
   - lijst openstaande TODOs (uit deze runbook)
