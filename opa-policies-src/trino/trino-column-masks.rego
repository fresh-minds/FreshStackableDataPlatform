package trino

# Column masks (R-AVG-07 + R-BIO-11).
#
# Per (rol × kolom) een SQL-mask die Trino in de SELECT-projection toepast.
#
# Trino 477+ vraagt de BATCHED variant op: `data.trino.batchColumnMasks`
# → [ { "index": <i>, "viewExpression": { "expression": "..." } }, ... ]
# waarbij <i> verwijst naar de positie in input.action.filterResources.
# De oudere singular API (`data.trino.columnMask` → {"expression": "..."})
# blijft ondersteund voor backward-compat. Beide leiden af van dezelfde
# helper-functie `_mask_expr` zodat de logica niet uiteen kan lopen.
#
# Default (geen match): geen mask (cleartext) — zie trino-base.rego.
#
# Mask-categorieën:
#   - BSN:              show last 4 voor crm_medewerker; anders hard-mask
#   - IBAN/bankrekening: fully masked  tenzij can_see_bankrekening/break_glass
#   - diagnose/icd10:   NULL           tenzij can_see_medical/break_glass
#   - geboortedatum:    bucket-per-jaar voor data_steward (enige rol)
#   - overige PII (naam/adres/geboortedatum): NULL voor rollen zonder
#     can_see_pii (was voorheen NIET gemaskeerd → cleartext leak, R-AVG-07)

import rego.v1

# --- mask-expressie per kolom (gedeeld door singular + batched) ---------
# `col` en `schema` zijn lowercased. Meerdere definities gedragen zich als
# een complete rule: precies één body mag matchen per (col, schema, rollen),
# anders geeft OPA een conflict. De condities hieronder zijn wederzijds
# uitsluitend.

# BSN — crm_medewerker ziet laatste 4.
_mask_expr(col, _schema) := "concat('XXXXX', substr(bsn, 6, 4))" if {
	col == "bsn"
	"crm_medewerker" in user_roles
}

# BSN — hard-mask voor rollen zonder can_see_pii (en niet crm).
_mask_expr(col, _schema) := "concat('XXXXXX', substr(bsn, 7, 3))" if {
	col == "bsn"
	not "crm_medewerker" in user_roles
	not any_role_has_capability("can_see_pii")
}

# IBAN / bankrekening.
_mask_expr(col, _schema) := "'NLxx XXXX XXXX XXXX'" if {
	col in {"iban", "bankrekening"}
	not any_role_has_capability("can_see_bankrekening")
	not any_role_has_capability("break_glass")
}

# diagnose / icd10.
_mask_expr(col, _schema) := "NULL" if {
	col in {"diagnose", "icd10"}
	not any_role_has_capability("can_see_medical")
	not any_role_has_capability("break_glass")
}

# geboortedatum — bucket-per-jaar voor data_steward (alleen als enige rol).
_mask_expr(col, _schema) := "date_trunc('year', geboortedatum)" if {
	col == "geboortedatum"
	"data_steward" in user_roles
	count(user_roles) == 1
}

# Overige PII (naam/adres) — NULL voor rollen zonder can_see_pii.
_mask_expr(col, _schema) := "NULL" if {
	col in {"voornaam", "achternaam", "straat", "huisnummer"}
	not any_role_has_capability("can_see_pii")
	not any_role_has_capability("break_glass")
}

# geboortedatum — NULL voor rollen zonder can_see_pii (data_steward heeft
# hierboven z'n eigen bucket-mask; die rol heeft can_see_pii=true dus deze
# body vuurt daar niet, geen conflict).
_mask_expr(col, _schema) := "NULL" if {
	col == "geboortedatum"
	not any_role_has_capability("can_see_pii")
	not any_role_has_capability("break_glass")
}

# UC-11 — event_label sanitization voor non-medische rollen.
_mask_expr(col, schema) := "concat(domein, '.', event_type)" if {
	col == "event_label"
	schema == "uc11_klantreis"
	not any_role_has_capability("can_see_medical")
	not any_role_has_capability("break_glass")
}

# UC-11 — source_ref_id gemaskeerd voor non-supervisor.
_mask_expr(col, schema) := "'***'" if {
	col == "source_ref_id"
	schema == "uc11_klantreis"
	not any_role_has_capability("can_see_pii")
	not "crm_medewerker" in user_roles
}

# --- singular API (backward-compat) ------------------------------------
columnMask := {"expression": expr} if {
	expr := _mask_expr(column_lower, resource_schema_lower)
}

# --- batched API (Trino 477+) ------------------------------------------
# Bouw een array met één entry per gemaskeerde kolom in filterResources.
# Kolommen zonder mask leveren geen entry (body faalt en wordt overgeslagen).
# Lege input → lege array, identiek aan het oude gedrag (geen regressie).
batchColumnMasks := [entry |
	some i, r in input.action.filterResources
	col := lower(_bc_colname(r))
	schema := lower(_bc_schema(r))
	expr := _mask_expr(col, schema)
	entry := {"index": i, "viewExpression": {"expression": expr}}
]

# --- helpers -----------------------------------------------------------
column_lower := lower(input.action.resource.column.columnName)

resource_schema_lower := lower(input.action.resource.column.schemaName)

# Robuust t.o.v. beide mogelijke batch-resource-vormen: genest onder
# `.column` (zoals de singular resource) of plat op de resource zelf.
_bc_colname(r) := r.column.columnName

_bc_colname(r) := r.columnName if {
	not r.column
}

_bc_schema(r) := r.column.schemaName

_bc_schema(r) := r.schemaName if {
	not r.column
}
