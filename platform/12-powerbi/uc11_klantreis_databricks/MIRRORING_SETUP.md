# Fabric Mirroring voor Databricks UC → DirectLake Power BI

## Status

- ✅ REST API endpoint geverifieerd (`POST /workspaces/{id}/mirroredAzureDatabricksCatalogs`)
- ✅ Schema en payload begrepen
- ⚠️  Storage Connection vereist Azure role-assignment die door Conditional Access
   geblokkeerd wordt vanuit niet-interactieve auth → handmatige UI-stap nodig

## UI-stappen (5 minuten, eenmalig)

1. Open Fabric workspace `dbt_testing`:
   https://app.fabric.microsoft.com/groups/878307a8-e99a-4b9d-91c4-7b8fc457183b

2. **+ New item** → zoek "Mirrored Azure Databricks Catalog" → **Create**

3. **Connect to Azure Databricks**:
   - Workspace URL: `https://adb-7405615784988736.16.azuredatabricks.net`
   - Authenticatie: **OAuth 2.0** (gebruikt je freshminds account; Fabric vraagt consent)

4. **Select catalog**: kies `uwv_databricks` → Mirroring Mode: **Full**

5. **Storage**: Fabric vraagt om OneLake-toegang voor de mirror-target.
   Klik door — wordt automatisch ingericht.

6. **Sync**: Initial sync start direct (1-3 minuten voor onze ~16 KB data).

## Verifieer (na sync)

```bash
set -a; source secrets/local/uc11-multiplatform.env; set +a
PYTHONPATH=platform/11-airflow/include python3 -c "
from fabric_helpers import get_token, request, FABRIC_ENDPOINT, FABRIC_WORKSPACE_ID
token = get_token()
status, _, body = request('GET',
  f'{FABRIC_ENDPOINT}/workspaces/{FABRIC_WORKSPACE_ID}/mirroredAzureDatabricksCatalogs',
  token)
for m in body.get('value', []):
    print(f'  {m[\"displayName\"]} → {m[\"properties\"][\"mirrorStatus\"]}')
"
```

Verwacht: `uwv_databricks_mirror → Mirrored`.

## Volgende stap: Power BI rebind naar DirectLake

Zodra de mirror live is, hoeft de bestaande `uc11_klantreis_databricks` semantic
model alleen de M-expression aangepast — van DirectQuery via `Databricks.Catalogs`
naar DirectLake via `AzureStorage.DataLake` op de OneLake-mirror.

In [SemanticModel/model.bim](SemanticModel/model.bim), vervang de `DatabaseQuery`
expression:

```jinja
"expression": [
    "let",
    "    Source = AzureStorage.DataLake(\"https://onelake.dfs.fabric.microsoft.com/<WORKSPACE_ID>/<MIRROR_ITEM_ID>/Tables\")",
    "in",
    "    Source"
]
```

En per tabel-partition: `"mode": "directLake"` (i.p.v. `"directQuery"`).

Re-upload met:
```bash
python3 scripts/fabric-upload-powerbi.py --project uc11_klantreis_databricks --semanticmodel-only
```

Daarna `dataset/refreshes` triggeren → DirectLake framing klaar in <100ms (zoals
de oorspronkelijke Fabric semantic model). Geen credentials-prompt meer; geen
hangende exports.
