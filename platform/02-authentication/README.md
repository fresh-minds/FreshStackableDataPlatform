# 02-authentication

Stackable AuthenticationClass voor de UWV Keycloak-realm + interne TLS-CA-secretclass.

| Resource | Doel |
|---|---|
| `AuthenticationClass keycloak-uwv` | OIDC-config voor Trino/Superset/Airflow/NiFi/OpenMetadata. Issuer: `https://keycloak.uwv-platform.local:8443/realms/uwv`. |
| `SecretClass tls-internal` | Locatie voor het CA-cert dat de Keycloak-OIDC-endpoint heeft getekend. |

## CA distribution (TODO fase-1+)

Het CA-cert (`uwv-platform-ca` Secret in `cert-manager`-namespace) moet
worden gekopieerd naar een Secret in `uwv-platform`-namespace met label
`secrets.stackable.tech/class: tls-internal`. Twee opties:

1. **trust-manager** (`cert-manager.io/trust-manager`) Bundle-resource — propere oplossing; commit volgt in fase 3 zodra Trino het echt nodig heeft.
2. Tijdelijk: handmatige Secret-kopie in bootstrap.sh:

   ```bash
   kubectl get secret -n cert-manager uwv-platform-ca -o jsonpath='{.data.ca\.crt}' \
     | base64 -d > /tmp/ca.crt
   kubectl -n uwv-platform create secret generic uwv-platform-ca-trust \
     --from-file=ca.crt=/tmp/ca.crt \
     --dry-run=client -o yaml \
     | kubectl label --local -f - secrets.stackable.tech/class=tls-internal -o yaml \
     | kubectl apply -f -
   ```

Wordt in fase 3 (Trino-deploy) volledig automatisch via trust-manager.

## Apply

```bash
kubectl apply -k platform/02-authentication/
```
