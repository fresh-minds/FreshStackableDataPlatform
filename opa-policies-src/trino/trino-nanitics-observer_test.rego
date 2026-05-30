package trino

import rego.v1

# Tests for the read-only Nanitics observer service identity.
#
# Binding lives in trino-base.rego (static user `nanitics-observer` → role
# `nanitics_observer`); the role lives in data/uwv_role_mappings.json
# (catalogs silver+gold, can_see_pii/medical=false). These tests mock the
# role data inline with `with data.configmap` so they are hermetic and do
# not depend on how `opa test` mounts the data file.

_observer_configmap := {"opa-trino-bundle": {"uwv-platform": {"uwv_role_mappings": {
	"roles": {"nanitics_observer": {
		"catalogs": ["silver", "gold"],
		"schemas": null,
		"purposes": ["sturingsinfo", "kwaliteitscontrole", "beleid"],
		"can_see_pii": false,
		"can_see_medical": false,
		"can_see_bankrekening": false,
		"regio_filter": false,
		"break_glass": false,
	}},
	"resource_purposes": {},
	"sensitive_columns": {},
}}}}

_observer_input(catalog, schema, table, op) := {
	"context": {"identity": {"user": "nanitics-observer"}},
	"action": {"operation": op, "resource": {"table": {
		"catalogName": catalog,
		"schemaName": schema,
		"tableName": table,
	}}},
}

test_observer_reads_gold if {
	role_allows_resource with input as _observer_input("gold", "uc01_wia_funnel", "mart_uc01_wia_funnel", "SelectFromColumns")
		with data.configmap as _observer_configmap
}

test_observer_reads_silver if {
	role_allows_resource with input as _observer_input("silver", "polisadm", "ikv", "SelectFromColumns")
		with data.configmap as _observer_configmap
}

test_observer_denied_sensitive if {
	not role_allows_resource with input as _observer_input("sensitive", "wajong", "diagnose", "SelectFromColumns")
		with data.configmap as _observer_configmap
}

test_observer_has_no_pii_capability if {
	not role_has_capability("nanitics_observer", "can_see_pii") with data.configmap as _observer_configmap
}

test_observer_cannot_write if {
	not allow with input as _observer_input("gold", "uc01_wia_funnel", "x", "InsertIntoTable")
		with data.configmap as _observer_configmap
}
