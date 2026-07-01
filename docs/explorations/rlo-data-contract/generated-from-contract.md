# Generated from the contract

> One contract in (`example-polisadm-ikv.odcs.yaml`), every governance
> artifact out. This file shows the **generated** outputs so the "single source
> of truth" thesis is concrete, not hand-wavy. A `datacontract`/codegen step
> (see [README](README.md), "Wat te bouwen") emits each block below; CI then runs
> *generate-and-diff* so a hand-edited downstream file fails the build.

Today these six surfaces are **hand-authored and drift** (see the README's
"versplinterd"/gaps section). After the redesign they are **projections** of the one
contract. The interesting one is the last: the same `classification: pii` +
`maskingStrategy` that produces the OpenMetadata discovery tag *also* produces
the OPA enforcement mask — closing the gap where today OPA hardcodes
`column_lower == "bsn"` with no link to the contract.

---

## 1 → Airflow SourceSpec  (`platform/11-airflow/sources/polisadm.yml`)

Generated from `servers`, `slaProperties`, `customProperties`, and the PII
properties of the schema:

```yaml
# GENERATED from urn:uwv:datacontract:polisadm:ikv v1.0.0 — do not edit by hand.
schema_version: 1
name: polisadm
domain: polisadm
stream:
  name: uwv.polisadm.ikv
  key: ikv_id
bronze:  { catalog: bronze, schema: uwv, table: polisadm_ikv, partition_by: event_date }
silver:  { catalog: silver, schema: polisadm, staging_model: stg_polisadm_ikv, dbt_tag: polisadm }
governance:
  legal_basis: Wet_SUWI+Wfsv
  doelbinding: [primair_proces, kwaliteitscontrole]
  bio_classificatie: vertrouwelijk
  bewaartermijn_jaren: 30
  eigenaar: data_steward_polisadm
  pii_kolommen: [bsn, lh_nummer]          # <- derived from classification:pii props
  risk_tier: laag
sla:
  mode: streaming
  max_acceptable_lag_seconds: 120
  alert_threshold_seconds: 300
```

`pii_kolommen` is no longer a hand-kept list that can disagree with reality — it
is *computed* from the properties tagged `classification: pii`.

---

## 2 → Spark bronze validation schema

The ingest job (`spark-jobs/streaming_files_to_lakehouse.py`) reads the contract
to validate the landed envelope and register the Delta table. For CSV sources
(`jobs/csv_to_bronze.py`) the same schema block enforces "columns may not be
missing; types are cast" — today written by hand in each source YAML's
`ingest.schema`, now generated:

```python
# GENERATED expected schema for bronze validation
EXPECTED = [
    ("ikv_id",                "string",    True),
    ("bsn",                   "string",    True),   # pii
    ("lh_nummer",             "string",    True),   # pii
    ("werkgever_naam",        "string",    False),
    ("aanvang_dienstverband", "date",      True),
    ("einde_dienstverband",   "date",      False),
    ("loon_bruto_jaar",       "integer",   True),   # range 0..500000
    ("event_date",            "date",      True),
]
```

---

## 3 → dbt: `_sources.yml` + `_stg_polisadm.yml` + model contract

`datacontract export --format dbt` produces the sources entry, the staging
`schema.yml` (with the governance `meta:` block the CI meta-check requires), and
turns on dbt's **model contract** so the *shape* is enforced at build time:

```yaml
# GENERATED dbt/models/staging/polisadm/_stg_polisadm.yml
version: 2
models:
  - name: stg_polisadm_ikv
    description: "IKV's per persoon — kerneenheid polisadministratie."
    config:
      contract: { enforced: true }        # dbt preflight: columns + types must match
      tags: ["staging", "polisadm"]
    meta:                                  # <- generated, satisfies check-dbt-meta.py
      domain: polisadm
      legal_basis: Wet_SUWI+Wfsv
      doelbinding: ["primair_proces", "kwaliteitscontrole"]
      bio_classificatie: vertrouwelijk
      bewaartermijn_jaren: 30
      eigenaar: data_steward_polisadm
      pii_kolommen: [bsn, lh_nummer]
      risk_tier: laag
    columns:
      - name: ikv_id
        data_type: varchar
        constraints: [{ type: not_null }]  # NB: on Trino dbt enforces not_null only
        tests: [unique]                    # PK/unique -> tests, not constraints (see README, "Risico's & besluiten")
      - name: bsn
        data_type: varchar
        constraints: [{ type: not_null }]
        tests: [bsn_valid, { relationships: { to: ref('stg_persona'), field: bsn } }]
      - name: loon_bruto_jaar
        data_type: integer
        tests: [{ dbt_utils.accepted_range: { min_value: 0, max_value: 500000 } }]
      # ... remaining columns ...
```

The **staging SQL** stays hand-written business logic (the `json_extract_scalar`
+ cast projection in `stg_polisadm_ikv.sql`) — codegen owns the *contract*
(`schema.yml`, types, tests, meta), not the transform. The `canonical-schema-drafter`
agent can draft the first version of the SQL (README, "Agentic").

---

## 4 → OpenMetadata classifications, glossary links, DQ

The existing loop (`enrich_from_dbt_meta.py`) already reads dbt `meta:` →
manifest → OM tags. Because §3's `meta:` and per-column classification are now
generated, OM receives:

| Property | Contract field | OpenMetadata tag |
|---|---|---|
| `bsn` | `classification: pii`, `piiCategory: direct_identifier` | `PII.Sensitive` |
| `lh_nummer` | `piiCategory: indirect_identifier` | `PII.NonSensitive` |
| dataset | `legal_basis: Wet_SUWI+Wfsv` | `LegalBasis.Wet_SUWI` |
| dataset | `doelbinding: [primair_proces, …]` | `Doelbinding.Primair_proces` |
| dataset | `bio_classificatie: vertrouwelijk` | `BIO.Vertrouwelijk` |
| `bsn`,`lh_nummer` | `cgm_entiteiten` | glossary `CGM.Inkomstenverhouding` |

DQ expectations (`quality:` rules) export to OM Data Quality / test suites.

---

## 5 → OPA column-masks + `sensitive_columns`  (**the gap that closes**)

Today `opa-policies-src/trino/trino-column-masks.rego` hardcodes column names:

```rego
# BEFORE — hand-written, no link to any contract:
columnMask := {"expression": "concat('XXXXXX', substr(bsn, 7, 3))"} if {
    column_lower == "bsn"
    not any_role_has_capability("can_see_pii")
}
```

If a new source lands a `burgerservicenummer` or `sofinummer` column, this rule
silently does **not** fire — PII leaks. After the redesign, the masks are a
**data table generated from every contract's `maskingStrategy`**, and the rego
becomes generic (match on data, not on a literal):

```rego
# AFTER — generic rule over generated data:
columnMask := {"expression": mask.expression} if {
    some mask in data.uwv.column_masks[resource_schema][column_lower]
    not any_role_has_capability(mask.capability)
}
```

```json
// GENERATED opa data: uwv.column_masks (union of all contracts)
{
  "polisadm": {
    "bsn":       [{ "capability": "can_see_pii", "expression": "concat('XXXXXX', substr(bsn,7,3))" }],
    "lh_nummer": [{ "capability": "can_see_pii", "expression": "NULL" }]
  }
}
```

```json
// GENERATED uwv_role_mappings.sensitive_columns  (from customProperties.sensitiveColumn)
{ "polisadm.stg_polisadm_ikv": ["bsn", "lh_nummer"] }
```

```json
// GENERATED resource_purposes  (from customProperties.doelbinding — same value the
// om_to_opa_sync.py CronJob syncs, but now sourced at the contract, not reverse-engineered)
{ "silver.polisadm.*": ["primair_proces", "kwaliteitscontrole"] }
```

Now **one edit** — adding a `classification: pii` property with a
`maskingStrategy` — produces *both* the OpenMetadata discovery tag (§4) *and*
the OPA enforcement mask. Discovery and enforcement can no longer disagree.

---

## 6 → Retention / RTBF policy  (`bewaartermijn_jaren: 30`)

```yaml
# GENERATED retention rule
- table: silver.polisadm.stg_polisadm_ikv
  retention_years: 30                     # customProperties.bewaartermijn_jaren
  subject_key: bsn                        # dataSubject=werknemer, direct_identifier
  rtbf: pseudonymize_then_expire          # anonymizationStrategy: sha256_salted_pseudonym
```

Feeds a scheduled Delta/Iceberg maintenance job: RTBF = `DELETE WHERE bsn = ?`
→ `OPTIMIZE`/rewrite → `VACUUM`/expire-snapshots (the 3-step erasure pattern),
and a retention sweep after 30 years.

---

## The point

Six surfaces, one edit. The contract is the RLO; everything else is a build
artifact. `git diff` on a PR shows a governance change (a new PII field, a
changed doelbinding) as a **one-line contract change with a reviewable blast
radius**, instead of six hand-edits that drift apart.
