package trino

import rego.v1

# WIA-beoordelaar in regio AMS → filter `regio_code = 'AMS'`.
test_wia_beoordelaar_regio_filter if {
	filters := rowFilters with input as {
		"context": {"identity": {
			"user": "wia.beoordelaar",
			"groups": ["wia_beoordelaar"],
			"extraCredentials": {"regio": "ams"},
		}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"table": {
				"catalogName": "silver",
				"schemaName": "wia",
				"tableName": "aanvraag",
			}},
		},
	}
	count(filters) == 1
	filters[0].expression == "regio_code = 'AMS'"
}

# Andere rol op silver.wia → geen regio-filter.
test_no_regio_filter_for_data_steward if {
	rowFilters == [] with input as {
		"context": {"identity": {
			"user": "data.steward",
			"groups": ["data_steward"],
		}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"table": {
				"catalogName": "silver",
				"schemaName": "wia",
				"tableName": "aanvraag",
			}},
		},
	}
}

# UC-04 opt-out filter altijd actief.
test_uc04_opt_out_filter if {
	filters := rowFilters with input as {
		"context": {"identity": {
			"user": "proactief.dienstverlener",
			"groups": ["proactief_dienstverlener"],
		}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"table": {
				"catalogName": "gold",
				"schemaName": "uc04_tw_eligibility",
				"tableName": "mart_uc04_tw_eligibility",
			}},
		},
	}
	count(filters) == 1
	filters[0].expression == "opt_out = false"
}

# Regex-validatie: ongeldige regio (te lang) → geen filter (defensief).
test_invalid_regio_no_filter if {
	rowFilters == [] with input as {
		"context": {"identity": {
			"user": "wia.beoordelaar",
			"groups": ["wia_beoordelaar"],
			"extraCredentials": {"regio": "DROPTABLE"},
		}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"table": {
				"catalogName": "silver",
				"schemaName": "wia",
				"tableName": "aanvraag",
			}},
		},
	}
}
