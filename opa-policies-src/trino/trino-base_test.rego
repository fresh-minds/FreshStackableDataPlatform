package trino

import rego.v1

# Helper: bouw een minimaal input-record voor tests.
mock_input(user, roles, op, catalog, schema, table) := {
	"context": {"identity": {
		"user": user,
		"groups": roles,
	}},
	"action": {
		"operation": op,
		"resource": {"table": {
			"catalogName": catalog,
			"schemaName": schema,
			"tableName": table,
		}},
	},
}

mock_input_with_purpose(user, roles, purpose, op, catalog, schema, table) := r if {
	r := {
		"context": {"identity": {
			"user": user,
			"groups": roles,
			"extraCredentials": {"purpose": purpose},
		}},
		"action": {
			"operation": op,
			"resource": {"table": {
				"catalogName": catalog,
				"schemaName": schema,
				"tableName": table,
			}},
		},
	}
}

# --- baseline tests ----------------------------------------------------

test_anonymous_denied if {
	not allow with input as {
		"context": {"identity": {"user": "", "groups": []}},
		"action": {"operation": "ExecuteQuery"},
	}
}

test_authenticated_meta_query_allowed if {
	allow with input as {
		"context": {"identity": {"user": "data.steward", "groups": ["data_steward"]}},
		"action": {"operation": "ExecuteQuery"},
	}
}

test_user_with_no_role_denied if {
	not allow with input as mock_input(
		"alice", [], "SelectFromColumns",
		"gold", "uc01_wia_funnel", "mart_uc01_wia_funnel_daily",
	)
		with data.uwv_role_mappings as data.uwv_role_mappings
}

# --- C6: impersonation alleen voor platform_admin ----------------------

test_impersonate_denied_for_non_admin if {
	not allow with input as {
		"context": {"identity": {"user": "alice", "groups": ["data_steward"]}},
		"action": {"operation": "ImpersonateUser", "resource": {"user": {"user": "platform.admin"}}},
	}
}

test_impersonate_allowed_for_platform_admin if {
	allow with input as {
		"context": {"identity": {"user": "admin", "groups": ["platform_admin"]}},
		"action": {"operation": "ImpersonateUser", "resource": {"user": {"user": "someone"}}},
	}
}

# --- H1: writes begrensd tot toegestane catalogs -----------------------

test_data_engineer_write_bronze_allowed if {
	allow with input as mock_input(
		"eng", ["data_engineer"], "InsertIntoTable",
		"bronze", "uwv", "persoon",
	)
}

# data_engineer is read/write-scoped op bronze; schrijven in sensitive moet nu falen.
test_data_engineer_write_sensitive_denied if {
	not allow with input as mock_input(
		"eng", ["data_engineer"], "DropTable",
		"sensitive", "wajong", "dossier",
	)
}

test_smoketest_write_gold_allowed if {
	allow with input as mock_input(
		"smoketest", ["smoketest"], "CreateTable",
		"gold", "uc05_client_360", "mart_uc05_client_360",
	)
}
