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

# UC-11 — wia_beoordelaar in regio AMS op gold.uc11_klantreis → regio-filter
# met fallback "OR regio_code IS NULL" zodat non-WIA events zichtbaar blijven.
test_uc11_wia_beoordelaar_regio_filter if {
	filters := rowFilters with input as {
		"context": {"identity": {
			"user": "wia.beoordelaar",
			"groups": ["wia_beoordelaar"],
			"extraCredentials": {"regio": "ams"},
		}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"table": {
				"catalogName": "gold",
				"schemaName": "uc11_klantreis",
				"tableName": "mart_uc11_klantreis_events",
			}},
		},
	}
	count(filters) == 1
	filters[0].expression == "regio_code = 'AMS' OR regio_code IS NULL"
}

# UC-11 — ww_handhaver mag medische uitkomst-events niet zien.
test_uc11_ww_handhaver_medical_filter if {
	filters := rowFilters with input as {
		"context": {"identity": {
			"user": "ww.handhaver",
			"groups": ["ww_handhaver"],
		}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"table": {
				"catalogName": "gold",
				"schemaName": "uc11_klantreis",
				"tableName": "mart_uc11_klantreis_events",
			}},
		},
	}
	count(filters) == 1
	filters[0].expression == "NOT (domein = 'wia' AND event_status IN ('TOEGEKEND_WGA', 'TOEGEKEND_IVA'))"
}
