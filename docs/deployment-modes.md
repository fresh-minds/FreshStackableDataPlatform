# Deployment modes

The UWV reference platform runs in two modes, selected via `--mode` /
`DEPLOYMENT_MODE` / `make … MODE=…`. The mode is a single switch that drives
hostnames, storage classes, ingress controller shape, and kustomize overlays
end-to-end.

| Aspect | `k3d` (default) | `aks` |
|---|---|---|
| Cluster type | k3d serverlb | AKS managed |
| Browser port | `:8443` (serverlb→443) | `:443` (no port) |
| Domain | `*.uwv-platform.local` | `*.eu-sovereigndataplatform.com` |
| Ingress controller | DaemonSet + hostNetwork | Deployment + LoadBalancer |
| Storage class | `local-path` | `managed-csi` (`managed-csi-premium` for MinIO) |
| TLS | cert-manager + self-signed CA | cert-manager + Let's Encrypt |
| CoreDNS override | none needed | `coredns-custom` ConfigMap |
| Public DNS | `/etc/hosts` | Azure DNS zone (CNAMEs upserted by aks-deploy.sh) |

## Layers

```
┌────────────────────────────────────────────────────────────────────┐
│ User                                                               │
│   make deploy MODE=aks  /  make deploy MODE=k3d                    │
└─────────────┬──────────────────────────────────────────────────────┘
              │
              ▼
┌────────────────────────────────────────────────────────────────────┐
│ scripts/lib/mode.sh                                                │
│   parse_mode_args         — DEPLOYMENT_MODE, PLATFORM_DOMAIN,      │
│                              PLATFORM_PORT, IS_LOCAL, IS_CLOUD     │
│   require_context         — kubectl context vs mode mismatch       │
│   require_storage_class   — warn if expected SC absent             │
│   chart_value_args <chart> — picks values.yaml + values-<mode>.yaml│
│   kustomize_overlay <comp>— picks platform-overlays/<mode>/<comp>/ │
│                              or platform/<comp>/                   │
└─────────────┬──────────────────────────────────────────────────────┘
              │
   ┌──────────┴──────────────┐
   ▼                         ▼
┌──────────────────────┐   ┌─────────────────────────────────────────┐
│ Helm overlays        │   │ Kustomize overlays                      │
│ infrastructure/helm/ │   │ platform/<comp>/         (base)         │
│   <chart>/           │   │ platform-overlays/<mode>/<comp>/        │
│     values.yaml      │   │   kustomization.yaml                    │
│     values-k3d.yaml  │   │     resources: ../../../platform/<comp> │
│     values-aks.yaml  │   │     patches: [hostname patches, …]      │
└──────────────────────┘   └─────────────────────────────────────────┘
```

## Per-chart helm overlays

Each chart under `infrastructure/helm/<chart>/` has:
- `values.yaml` — mode-agnostic base (credentials, replicas, OIDC config,
  resource requests, image refs)
- `values-k3d.yaml` — k3d-specific overrides (storage class `local-path`,
  hostNetwork ingress controller, KC_HOSTNAME with :8443)
- `values-aks.yaml` — AKS overrides (Azure LoadBalancer, `managed-csi`
  storage, public hostname without :8443, no self-signed CA truststore)

`bootstrap.sh` layers them via `helm upgrade … $(chart_value_args <chart>)`.

## Per-component kustomize overlays

The platform manifests under `platform/<NN>-<comp>/` use a flat layout —
that **is** the k3d base. Mode-specific patches live in a sibling
tree at `platform-overlays/<mode>/<comp>/` (a sibling tree avoids kustomize's
"cycle detected" error that would arise if overlays lived inside their own
base's directory).

Currently `platform-overlays/aks/` patches 11 components for the AKS domain
and port. Adding a new mode (e.g. EKS or GKE) means copying this tree and
adjusting the host strings.

## Adding a new component

1. Drop your manifests in `platform/NN-comp/` with k3d-shaped defaults
   (`.uwv-platform.local:8443` hostnames if applicable).
2. If the component needs to change shape per mode, create
   `platform-overlays/aks/NN-comp/kustomization.yaml`:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - ../../../platform/NN-comp
   patches:
     - target: { kind: Ingress, name: <name> }
       patch: |-
         - op: replace
           path: /spec/rules/0/host
           value: <name>.eu-sovereigndataplatform.com
         - op: replace
           path: /spec/tls/0/hosts/0
           value: <name>.eu-sovereigndataplatform.com
   ```
3. Verify with `kubectl kustomize platform-overlays/aks/NN-comp/`.
4. Add the layer to `LAYERS=` in `scripts/deploy-platform.sh` (it's
   automatically picked up by mode-aware deploy via `kustomize_overlay`).

## Adding a new mode

1. Add `MODE` to the case statements in `scripts/lib/mode.sh`
   (`parse_mode_args` + `require_context` + `require_storage_class`).
2. For every chart that has `values-aks.yaml`, create a matching
   `values-<newmode>.yaml`.
3. For every directory that has `platform-overlays/aks/<comp>/`, create
   `platform-overlays/<newmode>/<comp>/` and adjust the host strings.
4. Update `make cluster` in `Makefile` to know how to bring up the cluster.
