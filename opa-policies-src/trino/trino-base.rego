package trino

# =====================================================================
#  UWV PLATFORM — TRINO OPA BASE POLICY (fase 9)
# =====================================================================
#
#  Vervangt de allow-all base-policy uit fase 3.
#  Default-deny + bouwt allow op via:
#    - role-mapping     (trino-uwv-roles.rego)
#    - doelbinding      (trino-doelbinding.rego, R-AVG-06)
#    - row filters      (trino-row-filters.rego, R-BIO-11)
#    - column masks     (trino-column-masks.rego, R-AVG-07 + R-BIO-11)
#
#  Trino OPA Access Controller spec (v2):
#    https://trino.io/docs/current/security/opa-access-control.html
# =====================================================================

import rego.v1

# --- defaults ----------------------------------------------------------

default allow := false

default rowFilters := []

default columnMask := {}

# --- helpers -----------------------------------------------------------

# Authenticated user is altijd verplicht.
authenticated if {
	input.context.identity.user
	input.context.identity.user != ""
}

# UWV-rollen uit Keycloak: groups-claim of (fallback) leeg.
user_roles := input.context.identity.groups

# Voor static-auth (smoketest user, geen groups-claim) plak handmatig de rol op
# o.b.v. de username.
user_roles := ["smoketest"] if {
	input.context.identity.user == "smoketest"
	not input.context.identity.groups
}

# Purpose komt via Trino's `extraCredentials` (HTTP-header X-Trino-Extra-Credential).
# Lege string = geen purpose meegegeven.
user_purpose := lower(input.context.identity.extraCredentials.purpose) if {
	input.context.identity.extraCredentials.purpose
}

user_purpose := "" if {
	not input.context.identity.extraCredentials
}

user_purpose := "" if {
	input.context.identity.extraCredentials
	not input.context.identity.extraCredentials.purpose
}

# Operation-categorisatie.
is_read_op if input.action.operation == "SelectFromColumns"

is_read_op if input.action.operation == "ReadFromTable"

is_read_op if input.action.operation == "FilterColumns"

is_read_op if input.action.operation == "ShowSchemas"

is_read_op if input.action.operation == "ShowTables"

is_read_op if input.action.operation == "ShowColumns"

is_meta_op if input.action.operation == "ExecuteQuery"

is_meta_op if input.action.operation == "AccessCatalog"

is_meta_op if input.action.operation == "ImpersonateUser"

is_meta_op if input.action.operation == "ReadSystemInformation"

is_write_op if input.action.operation == "InsertIntoTable"

is_write_op if input.action.operation == "DeleteFromTable"

is_write_op if input.action.operation == "TruncateTable"

is_write_op if input.action.operation == "DropTable"

is_write_op if input.action.operation == "DropSchema"

is_write_op if input.action.operation == "CreateTable"

is_write_op if input.action.operation == "CreateSchema"

# --- top-level allow ---------------------------------------------------

# Meta-operations (cataloglist, queryplan, etc.) — alleen authenticated.
allow if {
	authenticated
	is_meta_op
}

# Read-operations — full chain: role + doelbinding.
allow if {
	authenticated
	is_read_op
	role_allows_resource
	purpose_allows_resource
}

# Write-operations — alleen voor data_engineer + platform_admin.
allow if {
	authenticated
	is_write_op
	some r in user_roles
	r in {"data_engineer", "platform_admin"}
}

# --- batch (voor SHOW TABLES / FilterColumns op een lijst) ------------
batch contains i if {
	authenticated
	some i, _ in input.action.filterResources

	# Vrijgevig op meta-list-ops; per-resource policies vangen het later af.
	is_read_op
}
