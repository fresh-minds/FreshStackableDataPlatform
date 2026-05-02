package trino

# Column masks (R-AVG-07 + R-BIO-11).
#
# Per (rol × kolom) een SQL-mask die Trino in de SELECT-projection toepast.
# Trino verwacht: data.trino.columnMask → { "expression": "..." }
#
# Default: geen mask (cleartext).
#
# Mask-categorieën:
#   - BSN:          show last 4 (`'XXXXX' || substr(bsn, 6, 4)`)  voor crm_medewerker
#   - IBAN/bankrekening:  fully masked  (`'NLxx XXXX XXXX XXXX'`) voor wie geen `can_see_bankrekening`
#   - diagnose/icd10: NULL  voor wie geen `can_see_medical`
#   - geboortedatum: bucket-per-jaar  (`date_trunc('year', geboortedatum)`) voor data_steward
#   - default voor andere PII bij rollen zonder `can_see_pii`: NULL

import rego.v1

# --- BSN: maskeer voor crm_medewerker ---------------------------------
columnMask := {"expression": expr} if {
	column_lower == "bsn"
	"crm_medewerker" in user_roles
	expr := "concat('XXXXX', substr(bsn, 6, 4))"
}

# --- BSN: hard-mask voor rollen zonder can_see_pii --------------------
columnMask := {"expression": "concat('XXXXXX', substr(bsn, 7, 3))"} if {
	column_lower == "bsn"
	not "crm_medewerker" in user_roles # die heeft eigen mask
	not any_role_has_capability("can_see_pii")
}

# --- IBAN / bankrekening: deny voor wie niet can_see_bankrekening -----
columnMask := {"expression": "'NLxx XXXX XXXX XXXX'"} if {
	column_lower in {"iban", "bankrekening"}
	not any_role_has_capability("can_see_bankrekening")
	not any_role_has_capability("break_glass")
}

# --- diagnose / icd10: NULL voor wie niet can_see_medical -------------
columnMask := {"expression": "NULL"} if {
	column_lower in {"diagnose", "icd10"}
	not any_role_has_capability("can_see_medical")
	not any_role_has_capability("break_glass")
}

# --- geboortedatum: bucket-per-jaar voor data_steward -----------------
columnMask := {"expression": "date_trunc('year', geboortedatum)"} if {
	column_lower == "geboortedatum"
	"data_steward" in user_roles
	count(user_roles) == 1 # alleen als data_steward de enige rol is
}

# --- helpers ----------------------------------------------------------
column_lower := lower(input.action.resource.column.columnName)
