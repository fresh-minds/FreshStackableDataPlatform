package trino

import rego.v1

# DoD-check: OPA maskeert BSN voor crm_medewerker.
test_bsn_masked_for_crm_medewerker if {
	mask := columnMask with input as {
		"context": {"identity": {
			"user": "crm.medewerker",
			"groups": ["crm_medewerker"],
		}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"column": {
				"catalogName": "gold",
				"schemaName": "uc05_client_360",
				"tableName": "mart_uc05_client_360",
				"columnName": "bsn",
			}},
		},
	}
	mask.expression == "concat('XXXXX', substr(bsn, 6, 4))"
}

# Wia_beoordelaar mag PII zien — geen mask op BSN.
test_bsn_unmasked_for_wia_beoordelaar if {
	columnMask == {} with input as {
		"context": {"identity": {
			"user": "wia.beoordelaar",
			"groups": ["wia_beoordelaar"],
		}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"column": {
				"catalogName": "silver",
				"schemaName": "wia",
				"tableName": "stg_wia_aanvraag",
				"columnName": "bsn",
			}},
		},
	}
}

# Diagnose: NULL voor crm_medewerker (geen can_see_medical).
test_diagnose_nulled_for_crm_medewerker if {
	mask := columnMask with input as {
		"context": {"identity": {
			"user": "crm.medewerker",
			"groups": ["crm_medewerker"],
		}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"column": {
				"catalogName": "sensitive",
				"schemaName": "wajong",
				"tableName": "dossier",
				"columnName": "diagnose",
			}},
		},
	}
	mask.expression == "NULL"
}

# Diagnose: cleartext voor wajong_arbeidsdeskundige.
test_diagnose_visible_for_wajong_arbeidsdeskundige if {
	columnMask == {} with input as {
		"context": {"identity": {
			"user": "wajong.arbeidsdeskundige",
			"groups": ["wajong_arbeidsdeskundige"],
		}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"column": {
				"catalogName": "sensitive",
				"schemaName": "wajong",
				"tableName": "dossier",
				"columnName": "diagnose",
			}},
		},
	}
}

# IBAN: gemaskeerd voor crm_medewerker (geen can_see_bankrekening).
test_iban_masked_for_crm_medewerker if {
	mask := columnMask with input as {
		"context": {"identity": {
			"user": "crm.medewerker",
			"groups": ["crm_medewerker"],
		}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"column": {
				"catalogName": "gold",
				"schemaName": "uc05_client_360",
				"tableName": "mart_uc05_client_360",
				"columnName": "iban",
			}},
		},
	}
	mask.expression == "'NLxx XXXX XXXX XXXX'"
}

# IBAN: cleartext voor ww_handhaver (heeft can_see_bankrekening).
test_iban_visible_for_ww_handhaver if {
	columnMask == {} with input as {
		"context": {"identity": {
			"user": "ww.handhaver",
			"groups": ["ww_handhaver"],
		}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"column": {
				"catalogName": "silver",
				"schemaName": "ww",
				"tableName": "aanvraag",
				"columnName": "iban",
			}},
		},
	}
}
