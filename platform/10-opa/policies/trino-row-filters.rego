package trino

# Row filters (R-BIO-11).
#
# Per (rol × schema) een filter-expressie die Trino aan elke SELECT toevoegt.
# Trino verwacht: data.trino.rowFilters → [ { "expression": "..." }, ... ]
#
# `rowFilters` is een PARTIAL SET rule: elke toepasselijke regel voegt een
# element toe. Trino AND-combineert alle elementen, dus filters STACKEN nu
# (een user met meerdere rollen krijgt álle bijbehorende restricties i.p.v.
# een complete-rule conflict of een stil verloren filter). Een lege set
# serialiseert naar `[]`.
#
# Implementaties:
#   - WIA-beoordelaar in `silver.wia.*` / `gold.uc01_wia_funnel.*`:
#       regio_code = '<eigen regio uit extraCredentials.regio>' (fail-closed)
#   - UC-04 mart: opt_out = false  (verberg cliënten die zich hebben afgemeld)

import rego.v1

# --- regio-helper ------------------------------------------------------
# LET OP: `regio` komt uit een door de client aangeleverde extra-credential
# header en is NIET geverifieerd tegen de werkelijke regio van de user. Dit
# is een bekende beperking (self-asserted attribuut) — de juiste fix is de
# regio uit een vertrouwde token-claim halen. De filters hieronder zijn wél
# fail-closed gemaakt: zonder geldige regio is er geen nationale toegang.
_regio := lower(input.context.identity.extraCredentials.regio)

_valid_regio if {
	_regio != ""

	# String-injection-safe: regio mag alleen [a-z]{3} zijn.
	regex.match("^[a-z]{3}$", _regio)
}

# --- WIA regio-filter (silver.wia / gold.uc01_wia_funnel) --------------

# Geldige regio → filter op die regio.
rowFilters contains {"expression": expr} if {
	"wia_beoordelaar" in user_roles
	resource_schema in {"wia", "uc01_wia_funnel"}
	_valid_regio
	expr := sprintf("regio_code = '%s'", [upper(_regio)])
}

# Fail-closed: geen (geldige) regio → deny-all i.p.v. nationale toegang.
# Voorheen viel dit terug op géén filter (fail-open leak).
rowFilters contains {"expression": "1 = 0"} if {
	"wia_beoordelaar" in user_roles
	resource_schema in {"wia", "uc01_wia_funnel"}
	not _valid_regio
}

# --- UC-04 opt-out filter ----------------------------------------------
rowFilters contains {"expression": "opt_out = false"} if {
	resource_schema == "uc04_tw_eligibility"
}

# --- Sandbox UC-09 -----------------------------------------------------
# Alleen records met pseudo-IDs (defensief; sandbox.* is al gepseudonimiseerd).
rowFilters contains {"expression": "bsn_pseudo IS NOT NULL"} if {
	resource_catalog == "sandbox"
}

# --- UC-11 klantreis ---------------------------------------------------

# wia_beoordelaar ziet klantreis-events voor eigen regio; non-WIA events
# (regio_code IS NULL) blijven zichtbaar zodat de tijdlijn niet leeg is.
rowFilters contains {"expression": expr} if {
	"wia_beoordelaar" in user_roles
	resource_schema == "uc11_klantreis"
	_valid_regio
	expr := sprintf("regio_code = '%s' OR regio_code IS NULL", [upper(_regio)])
}

# Fail-closed variant: zonder geldige regio worden alle regionale (WIA-)rijen
# verborgen; alleen non-regionale events (regio_code IS NULL) blijven over.
rowFilters contains {"expression": "regio_code IS NULL"} if {
	"wia_beoordelaar" in user_roles
	resource_schema == "uc11_klantreis"
	not _valid_regio
}

# ww_handhaver mag geen medische WIA-status-events zien (IVA = duurzaam).
rowFilters contains {"expression": expr} if {
	"ww_handhaver" in user_roles
	resource_schema == "uc11_klantreis"
	expr := "NOT (domein = 'wia' AND event_status IN ('TOEGEKEND_WGA', 'TOEGEKEND_IVA'))"
}
