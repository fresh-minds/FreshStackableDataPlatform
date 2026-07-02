package trino

import rego.v1

# rowFilters is nu een partial set — tests checken membership/count i.p.v.
# array-index.

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
	{"expression": "regio_code = 'AMS'"} in filters
}

# Andere rol op silver.wia → geen regio-filter (en geen fail-closed, want
# data_steward heeft geen regio_filter-rol).
test_no_regio_filter_for_data_steward if {
	count(rowFilters) == 0 with input as {
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
	{"expression": "opt_out = false"} in filters
}

# FAIL-CLOSED: wia_beoordelaar met ongeldige regio → deny-all filter (`1 = 0`),
# NIET langer een lege set (die zou nationale toegang betekenen).
test_invalid_regio_fails_closed if {
	filters := rowFilters with input as {
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
	count(filters) == 1
	{"expression": "1 = 0"} in filters
}

# FAIL-CLOSED: wia_beoordelaar zonder regio-credential → deny-all filter.
test_missing_regio_fails_closed if {
	filters := rowFilters with input as {
		"context": {"identity": {
			"user": "wia.beoordelaar",
			"groups": ["wia_beoordelaar"],
		}},
		"action": {
			"operation": "SelectFromColumns",
			"resource": {"table": {
				"catalogName": "gold",
				"schemaName": "uc01_wia_funnel",
				"tableName": "mart_uc01_wia_funnel",
			}},
		},
	}
	count(filters) == 1
	{"expression": "1 = 0"} in filters
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
	{"expression": "regio_code = 'AMS' OR regio_code IS NULL"} in filters
}

# UC-11 — wia_beoordelaar zonder geldige regio → alleen non-regionale events.
test_uc11_missing_regio_fails_closed if {
	filters := rowFilters with input as {
		"context": {"identity": {
			"user": "wia.beoordelaar",
			"groups": ["wia_beoordelaar"],
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
	{"expression": "regio_code IS NULL"} in filters
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
	{"expression": "NOT (domein = 'wia' AND event_status IN ('TOEGEKEND_WGA', 'TOEGEKEND_IVA'))"} in filters
}

# STACKING: user met wia_beoordelaar (geldige regio) + ww_handhaver op
# uc11_klantreis krijgt BEIDE filters (voorheen: complete-rule conflict/error).
test_uc11_multi_role_filters_stack if {
	filters := rowFilters with input as {
		"context": {"identity": {
			"user": "multi.user",
			"groups": ["wia_beoordelaar", "ww_handhaver"],
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
	count(filters) == 2
	{"expression": "regio_code = 'AMS' OR regio_code IS NULL"} in filters
	{"expression": "NOT (domein = 'wia' AND event_status IN ('TOEGEKEND_WGA', 'TOEGEKEND_IVA'))"} in filters
}
