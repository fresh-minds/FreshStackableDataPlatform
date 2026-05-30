package trino

# Tests for the nao analytics-agent read-only service identity.
#
# Binding lives in trino-base.rego (service-account user `nao-agent` → role
# `nao_agent`); the role lives in data/uwv_role_mappings.json (catalogs
# silver+gold, can_see_pii/medical/bankrekening=false). These tests mock the
# role data inline with `with data.configmap` so they are hermetic and do
# not depend on how `opa test` mounts the data file.
#
# Mirrors trino-nanitics-observer_test.rego — nao_agent has the same
# read-only aggregate scope but a distinct principal for audit attribution.

_nao_configmap := {"opa-trino-bundle": {"uwv-platform": {"uwv_role_mappings": {
	"roles": {"nao_agent": {
		"catalogs": ["silver", "gold"],
		"schemas": null,
		# Wildcard purpose: standing analytical mandate so the agent can read
		# all use-case marts without per-query purpose declaration. Hard limits
		# (read-only, no PII/medical, silver+gold only) still apply.
		"purposes": ["*"],
		"can_see_pii": false,
		"can_see_medical": false,
		"can_see_bankrekening": false,
		"regio_filter": false,
		"break_glass": false,
	}},
	# A purpose-gated mart: only readable by a role whose mandated purpose
	# includes "sturingsinfo". nao_agent passes via the wildcard purpose.
	"resource_purposes": {"gold.uc01_wia_funnel.*": ["sturingsinfo"]},
	"sensitive_columns": {},
}}}}

_nao_input(catalog, schema, table, op) := {
	"context": {"identity": {"user": "nao-agent"}},
	"action": {"operation": op, "resource": {"table": {
		"catalogName": catalog,
		"schemaName": schema,
		"tableName": table,
	}}},
}

test_nao_reads_gold if {
	role_allows_resource with input as _nao_input("gold", "uc01_wia_funnel", "mart_uc01_wia_funnel", "SelectFromColumns")
		with data.configmap as _nao_configmap
}

test_nao_reads_silver if {
	role_allows_resource with input as _nao_input("silver", "polisadm", "ikv", "SelectFromColumns")
		with data.configmap as _nao_configmap
}

test_nao_denied_sensitive if {
	not role_allows_resource with input as _nao_input("sensitive", "wajong", "diagnose", "SelectFromColumns")
		with data.configmap as _nao_configmap
}

test_nao_denied_bronze if {
	not role_allows_resource with input as _nao_input("bronze", "uwv", "raw", "SelectFromColumns")
		with data.configmap as _nao_configmap
}

test_nao_no_pii if {
	not role_has_capability("nao_agent", "can_see_pii") with data.configmap as _nao_configmap
}

test_nao_cannot_write if {
	not allow with input as _nao_input("gold", "uc01_wia_funnel", "x", "InsertIntoTable")
		with data.configmap as _nao_configmap
}

# Full allow-chain: wildcard purpose lets nao read a purpose-gated mart
# (role + doelbinding both satisfied) without declaring a purpose header.
test_nao_allow_reads_gated_mart if {
	allow with input as _nao_input("gold", "uc01_wia_funnel", "mart_uc01_wia_funnel", "SelectFromColumns")
		with data.configmap as _nao_configmap
}

# Sanity: the same mart is denied for an unrelated read-only role without
# the matching purpose (proves the gate is real, not globally open).
test_gated_mart_denied_without_purpose if {
	not allow with input as {
		"context": {"identity": {"user": "x", "groups": ["fez_analist"]}},
		"action": {"operation": "SelectFromColumns", "resource": {"table": {"catalogName": "gold", "schemaName": "uc01_wia_funnel", "tableName": "mart_uc01_wia_funnel"}}},
	}
		with data.configmap as {"opa-trino-bundle": {"uwv-platform": {"uwv_role_mappings": {
			"roles": {"fez_analist": {
				"catalogs": ["gold"], "schemas": null, "purposes": ["actuarie", "beleid"],
				"can_see_pii": false, "can_see_medical": false, "can_see_bankrekening": false,
				"regio_filter": false, "break_glass": false,
			}},
			"resource_purposes": {"gold.uc01_wia_funnel.*": ["sturingsinfo"]},
			"sensitive_columns": {},
		}}}}
}
