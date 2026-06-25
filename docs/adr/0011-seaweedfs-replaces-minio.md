# ADR-0011: SeaweedFS vervangt MinIO in k3d-mode

| Status | **Geaccepteerd — k3d-mode only; aks/stackit follow-up** |
|---|---|
| Datum | 2026-05-30 |
| Beslissers | Platform Architect |
| Gerelateerd | ADR-0010 (platform-config single source) |

---

## Context

[MinIO is per 2025 gearchiveerd op GitHub](https://github.com/minio/minio)
en ontvangt geen feature-updates of beveiligings-patches meer als de
community-editie. Voor een **referentie**-platform dat 2027+ relevant moet
blijven, is doorgaan met archived software niet verdedigbaar — bij een CVE
zit je vast.

Selectie-criteria voor de vervanger:

1. **S3-API-compatibel** — Stackable Hive/Trino/Spark/etc. spreken alleen S3
   met SigV4-auth via een `S3Connection` CR. Vervanging mag dat contract niet
   breken.
2. **Actieve OSS-ontwikkeling** — geen `archived` repo, ≥1 release in de
   afgelopen 6 maanden, ≥10 commits/maand.
3. **In-cluster TLS** voor de S3-endpoint — Trino 469+ vereist `https://`
   S3 URLs en weigert `verification: none`.
4. **Helm-chart beschikbaar** met PVC + bucket-auto-create + cert-mount
   support.
5. **Footprint vergelijkbaar** met de huidige single-pod MinIO (geen
   verplichte multi-node distributed setup).

**SeaweedFS** scoort op alle vijf:
- Actief (3× releases in afgelopen 6 maanden, hoofdrepo +20k stars).
- S3-gateway via dedicated `s3:` block in `seaweedfs/seaweedfs` chart 4.29.0,
  met `tlsSecret`, `existingConfigSecret`, en `createBuckets` lijst.
- Pod-footprint: master + filer + volume + s3 (4× pods, single-replica) —
  iets meer dan MinIO's 1× pod, maar elk pod is klein (~50–500m CPU).

Twee alternatieven kort overwogen + verworpen:

- **Garage** (Deuxfleurs) — S3-compatible, lichtgewicht. Verworpen: chart-
  ecosysteem onvolwassen; bucket-create via CLI alleen; geen breed gebruik
  in K8s-deployments.
- **Cloud-native object storage** (Azure Blob via blob-csi-driver in k3d via
  Azurite emulator) — verworpen: voegt emulator-laag toe die zelf
  onderhouds-overhead is, en breekt de "lift en shift naar StackIT" route.

---

## Beslissing

**`infrastructure/helm/seaweedfs/`** is de nieuwe object-store chart voor
**k3d-mode**. AKS en StackIT blijven voor nu MinIO draaien — gemigreerd in
een follow-up PR (zie [Out of scope](#out-of-scope) hieronder).

### Topologie (k3d)

```
seaweedfs-master   (StatefulSet, 1×, 2Gi PVC)   — metadata + leader election
seaweedfs-filer    (StatefulSet, 1×, 5Gi PVC)   — POSIX-laag + leveldb meta
seaweedfs-volume   (StatefulSet, 1×, 30Gi PVC)  — chunk storage
seaweedfs-s3       (Deployment,  1×, no PVC)    — S3 API gateway (TLS)
```

In-cluster gRPC TLS tussen de vier pods komt uit de chart's eigen
`seaweedfs-ca-issuer` (cert-manager Issuer). De S3-endpoint TLS komt uit
**onze** `uwv-platform-issuer` ClusterIssuer — gemount als
`seaweedfs-s3-tls-internal` Secret. Stackable consumers (Trino/Hive/Spark)
verifiëren tegen de UWV-CA via `SecretClass minio-ca` (naam onveranderd
voor minimum-blast-radius — zie keuze hieronder).

### Mode-conditionele install

`scripts/bootstrap.sh` bevat één `if [[ "${IS_LOCAL}" == "yes" ]]` branch
rond de hele storage-install-flow (cert + TLS-Secret prep + helm install).
Cloud-modes raken niet de SeaweedFS-paths. Idempotent — bestaande clusters
ervaren geen wijziging tot deze branch landt + bootstrap opnieuw draait.

### S3Connection abstractie

De Stackable `S3Connection s3-minio` resource (in `platform/03-storage/`)
behoudt zijn naam — *geen* consumer-YAMLs gewijzigd. Alleen `host:` + `port:`
worden per mode anders gerenderd:

| Mode    | host                                                  | port |
|---------|-------------------------------------------------------|------|
| k3d     | `seaweedfs-s3.uwv-platform.svc.cluster.local`        | 8443 |
| aks     | `minio.uwv-platform.svc.cluster.local` (onveranderd) | 9000 |
| stackit | idem aks                                              | 9000 |

De k3d-versie komt uit `platform-overlays/k3d/03-storage/kustomization.yaml`
(strategic-merge patch op de base). `scripts/deploy-platform.sh` resolveert
de overlay automatisch via `kustomize_overlay()` in `scripts/lib/mode.sh`.

### Browse-UI vervanging

MinIO had een Keycloak-SSO web-console (`minio-console.${PLATFORM_DOMAIN}`).
SeaweedFS heeft géén equivalent — de ingebouwde Filer HTTP UI op port 8888
is basic en ongeauthenticeerd. We zetten **oauth2-proxy** ervoor
(`infrastructure/helm/oauth2-proxy/`) met een nieuwe Keycloak-client
`s3-browser`:

```
browser → s3-browser.uwv-platform.local:8443 (ingress + TLS)
       → oauth2-proxy (Keycloak OIDC challenge)
       → seaweedfs-filer:8888 (Filer HTTP UI, lijst files in /buckets/)
```

Trade-off geaccepteerd: de Filer UI is *basic* (alleen browse + download,
geen S3-ops zoals upload/delete via UI). Voor S3-write gebruikt de gebruiker
`aws s3` CLI of de portal CSV-upload flow.

---

## Mitigaties

| Risico                                       | Mitigatie                                                                                              |
|----------------------------------------------|--------------------------------------------------------------------------------------------------------|
| Stackable Trino's S3-client weigert SeaweedFS' SigV4-implementatie | TLS aan + `accessStyle: Path` (al gezet in s3connection-minio.yaml). Smoke-test in CI dekt regressie. |
| Data-migratie van bestaande MinIO PVCs                            | k3d wipe-en-reingest; cloud-modes blijven op MinIO tot follow-up PR met `mc mirror` Job.             |
| SeaweedFS bucket-policy parity met MinIO IAM-policies            | We gebruiken één root-credential (geen policy-per-user) — geen verlies.                              |
| OpenMetadata's S3-storage-profiler werkt niet tegen SeaweedFS    | Te valideren in Phase 6 smoke; fallback = OM storage-service uitschakelen voor k3d.                  |

---

## Out of scope (follow-up PRs)

1. **Migreer AKS naar SeaweedFS** — `infrastructure/helm/seaweedfs/values-aks.yaml`
   uitwerken; bootstrap.sh `IS_LOCAL` check verwijderen; `mc mirror`-Job voor
   bucket-data-transfer.
2. **Migreer StackIT naar SeaweedFS** — idem voor `values-stackit.yaml`.
3. **Rename `s3-credentials-minio` / `s3-minio` / `minio-ca`** naar backend-
   neutrale namen zodra alle modes op SeaweedFS draaien.
4. **Verwijder MinIO Helm-repo, chart-files, `MINIO_VERSION` uit bootstrap.sh.**
5. **Distributed SeaweedFS** (3× volume + replication `010`) voor cloud-modes
   ipv single-replica.

---

## Verificatie

Run `make clean && make cluster && make bootstrap deploy-platform MODE=k3d`
en verifieer:

1. `kubectl -n uwv-platform get pods | grep seaweedfs` toont 4 Running pods.
2. `kubectl -n uwv-platform exec deploy/seaweedfs-s3 -- /usr/bin/weed shell <<< 's3.bucket.list'`
   toont alle 8 UWV-buckets.
3. Trino query op `bronze.fdg_wia` werkt (data via SeaweedFS).
4. `https://s3-browser.uwv-platform.local:8443` → Keycloak login → browse
   van `/buckets/uwv-bronze/...`.
5. Spark History Server pod is Ready (spark-events-prefix-init Job heeft
   `s3a://uwv-checkpoints/spark-events/.keep` aangemaakt).
