# 09-trino

Trino — distributed SQL engine met OPA-authorisatie en OIDC-authenticatie.

| Resource | Doel |
|---|---|
| `AuthenticationClass trino-static-uwv` + `Secret trino-static-users` | Static-user voor smoke-tests + break-glass (dev-only). |
| `TrinoCluster uwv-trino` | 1 coordinator + 1 worker (scaled-down). |
| `TrinoCatalog bronze/silver/gold/sensitive` | Vier catalogs, gerenderd uit templates op basis van `platform-config.yaml::table_format`. |

## Voorvereisten

- `platform/02-authentication/` — `AuthenticationClass keycloak-uwv` + `SecretClass tls-internal`.
- `platform/03-storage/` — `S3Connection s3-minio`.
- `platform/05-hive-metastore/` — `HiveCluster uwv-hive` (Ready).
- `platform/10-opa/` — `OpaCluster uwv-opa` + base bundle ConfigMap.

## Apply

```bash
make render-catalogs       # rendert templates → catalogs/rendered/
kubectl apply -k platform/09-trino/
```

`make deploy-platform` doet beide stappen automatisch.

## Validatie

```bash
kubectl -n uwv-platform get trinocluster
kubectl -n uwv-platform get trinocatalog
kubectl -n uwv-platform get pods -l app.kubernetes.io/name=trino

# In-cluster query (static auth)
kubectl -n uwv-platform exec -it statefulset/uwv-trino-coordinator-default \
  -c trino -- \
  trino --server https://uwv-trino-coordinator:8443 \
        --user smoketest --password \
        --insecure \
        --execute "SHOW CATALOGS"
```

## Switching Delta ↔ Iceberg

Zie [`catalogs/README.md`](catalogs/README.md). Wijziging in
`platform-config.yaml` + `make render-catalogs` + apply is genoeg —
geen wijziging in `trinocluster.yaml` of policies nodig.

## Productie

- ≥ 2 coordinators (HA via Stackable's coordinator role).
- Multiple workers + fault-tolerant execution (`exchange-manager`).
- TLS verplicht; static-auth uit; OIDC verplicht.
- OPA-policies stapsgewijs vervangen via fase 9 bundle.
