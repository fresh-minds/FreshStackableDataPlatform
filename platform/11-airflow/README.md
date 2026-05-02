# 11-airflow

Apache Airflow via Stackable's AirflowCluster CRD. Orchestratie voor dbt-runs,
lakehouse-maintenance, seed-loads en (fase 8) OpenMetadata-ingestie.

| Resource | Doel |
|---|---|
| `AirflowCluster uwv-airflow` | Webserver + scheduler + KubernetesExecutor (geen Celery), Postgres-backend, OIDC via Keycloak. |
| `ConfigMap airflow-dags` (gegenereerd) | Mount van `dags/*.py` op `/stackable/airflow/dags`. |

## DAGs

| DAG | Schedule | Wat |
|---|---|---|
| `dbt_run_per_domain` | @hourly | Eén KubernetesPodOperator per domein (8 stuks parallel) → dbt-trino image draait `dbt run --select tag:<domein>`. Vereist Airflow Variable `uwv_repo_url` (git-sync init-container clont de repo). Skipt als variabele leeg is. |
| `lakehouse_maintenance` | @daily | Per bronze-tabel `OPTIMIZE`/`VACUUM` (Delta) of `expire_snapshots`/`remove_orphan_files`/`optimize` (Iceberg). Format via Variable `uwv_table_format`. Gebruikt `TrinoOperator` met connection `trino_default`. |
| `synthetic_data_load` | manueel | Past dezelfde Kubernetes Job toe als `make seed`. Gebruikt `KubernetesJobOperator`. |

## Voorvereisten

- `platform/01-secrets/` — `airflow-postgres-credentials` Secret aanwezig.
- `platform/02-authentication/` — `AuthenticationClass keycloak-uwv`.
- `platform/05-hive-metastore/`, `platform/09-trino/`, `platform/10-opa/` — voor de DAGs die queries draaien.
- ConfigMap `data-generation-scripts` + `data-generation-generators` — door `scripts/seed.sh` aangemaakt; nodig voor `synthetic_data_load`-DAG.

## Apply

```bash
kubectl apply -k platform/11-airflow/
```

## DAGs naar het cluster (drie paden)

### 1. ConfigMap-mount (default — voor lokale dev)
ConfigMap `airflow-dags` wordt door kustomize gegenereerd uit `dags/*.py`.
Wijzig DAGs lokaal → `kubectl apply -k platform/11-airflow/` → ConfigMap update → scheduler ziet de wijziging na ±30s.

### 2. dagsGitSync (productie)
Voeg toe aan `airflowcluster.yaml`:
```yaml
clusterConfig:
  dagsGitSync:
    - name: uwv-platform
      repo: "https://github.com/<org>/uwv-data-platform.git"
      branch: main
      gitFolder: platform/11-airflow/dags
      wait: 30
      depth: 1
```
en verwijder de `podOverrides`-mounts. Stackable maakt een sidecar git-sync.

### 3. PVC met inline upload
Voor air-gapped: maak een PVC, upload DAGs via `kubectl cp`, mount via `podOverrides`.

## Trino-connection in Airflow

Pre-deploy: maak via Airflow UI Admin → Connections een `trino_default`:

```
Conn Type:   Trino
Host:        uwv-trino-coordinator.uwv-platform.svc.cluster.local
Port:        8443
Login:       smoketest
Password:    <waarde uit Secret trino-static-users.smoketest>
Schema:      bronze
Extra:       {"protocol": "https", "verify": false}
```

In productie via OIDC + jwt_token (Airflow Variable).

## Validatie

```bash
kubectl -n uwv-platform get airflowcluster
kubectl -n uwv-platform get pods -l app.kubernetes.io/name=airflow

# Trigger seed via UI of CLI:
kubectl -n uwv-platform exec deploy/uwv-airflow-webserver-default \
  -c airflow -- airflow dags trigger synthetic_data_load
```

UI: `kubectl port-forward svc/uwv-airflow-webserver 8080:8080` → http://localhost:8080.

## Productie

- `webservers.replicas: 2+` voor HA.
- `dagsGitSync` + branch-protection.
- Externe Postgres met daily backup.
- Secrets via External Secrets Operator + Vault.
- Auth: alleen OIDC (verwijder admin-flow).
- DAG-test: `dbt-checkpoint` of `airflow-dag-tester` in CI.
