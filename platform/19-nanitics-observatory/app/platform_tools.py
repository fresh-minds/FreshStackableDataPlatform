"""Shared read-only data-plane tools for the platform observer agents.

Where `watcher.py` reads *operational* signals (Prometheus, Alertmanager,
OpenSearch, K8s events), this module reads *data-plane* signals:

    - query_trino(sql)            — read-only SQL against Trino (silver/gold)
    - openmetadata_search(query)  — search the OpenMetadata catalog
    - openmetadata_get(path)      — fetch a single OpenMetadata REST resource

The observer agents in `observers.py` compose these with the watcher's
Multica-filing tools. None of these tools can mutate the platform:
`query_trino` refuses anything that is not a read-only statement, and the
OpenMetadata tools only ever issue GETs. The worst-case failure mode is
the same as the watcher's — *noise in Multica*, never data loss.

Environment:
    TRINO_HOST              — coordinator host (default in-cluster Service)
    TRINO_PORT              — default 8443 (TLS) — see TRINO_HTTP_SCHEME
    TRINO_HTTP_SCHEME       — 'https' (default) or 'http'
    TRINO_USER              — read-only service user OPA grants SELECT to
    TRINO_PASSWORD          — optional; enables BasicAuth when set
    TRINO_CATALOG           — default catalog (default 'gold')
    TRINO_SCHEMA            — default schema (default 'information_schema')
    TRINO_VERIFY_TLS        — 'false' to skip cert verify (k3d self-signed)
    TRINO_MAX_ROWS          — hard row cap per query (default 200)
    TRINO_PURPOSE           — doelbinding purpose header (empty = fail closed)
    OPENMETADATA_URL        — base URL incl. /api (default in-cluster Service)
    OPENMETADATA_JWT_TOKEN  — optional bot JWT; sent as Bearer when set
    PLATFORM_HTTP_TIMEOUT   — seconds, default 15
"""

from __future__ import annotations

import asyncio
import json
import os
from typing import Any

import httpx
from nanitics import tool

# --- Trino ----------------------------------------------------------------
TRINO_HOST = os.environ.get(
    "TRINO_HOST", "trino-coordinator.uwv-data.svc.cluster.local"
)
TRINO_PORT = int(os.environ.get("TRINO_PORT", "8443"))
TRINO_HTTP_SCHEME = os.environ.get("TRINO_HTTP_SCHEME", "https")
TRINO_USER = os.environ.get("TRINO_USER", "nanitics-observer")
TRINO_PASSWORD = os.environ.get("TRINO_PASSWORD", "")
TRINO_CATALOG = os.environ.get("TRINO_CATALOG", "gold")
TRINO_SCHEMA = os.environ.get("TRINO_SCHEMA", "information_schema")
TRINO_VERIFY_TLS = os.environ.get("TRINO_VERIFY_TLS", "true").lower() == "true"
TRINO_MAX_ROWS = int(os.environ.get("TRINO_MAX_ROWS", "200"))
# Doelbinding: Trino forwards this to OPA as the X-Trino-Extra-Credential
# 'purpose'. Empty = no purpose sent → OPA FAILS CLOSED on doelbinding-gated
# resources. Set per the observer's purpose (e.g. 'sturingsinfo' for funnel,
# 'kwaliteitscontrole' for dq-sentinel, 'beleid' for damage). uc11/uc12 are
# unmapped and read regardless.
TRINO_PURPOSE = os.environ.get("TRINO_PURPOSE", "")

# --- OpenMetadata ---------------------------------------------------------
OPENMETADATA_URL = os.environ.get(
    "OPENMETADATA_URL",
    "http://openmetadata.uwv-meta.svc.cluster.local:8585/api",
).rstrip("/")
OPENMETADATA_JWT_TOKEN = os.environ.get("OPENMETADATA_JWT_TOKEN", "")

HTTP_TIMEOUT_SECONDS = float(os.environ.get("PLATFORM_HTTP_TIMEOUT", "15"))

# Only these leading keywords are accepted by query_trino. Everything else
# (INSERT, UPDATE, DELETE, MERGE, CREATE, DROP, ALTER, CALL, GRANT, …) is
# refused before a connection is even opened.
_READ_ONLY_PREFIXES = {"select", "show", "describe", "desc", "with", "explain"}


@tool(
    "query_trino",
    "Run a READ-ONLY SQL query against the platform Trino warehouse and "
    "return up to TRINO_MAX_ROWS rows as JSON {columns, rows, truncated}. "
    "Catalogs follow the platform layout: silver.<domain> (e.g. silver.wia) "
    "and gold.<uc_id> (e.g. gold.uc01_wia_funnel); the sensitive.* catalog is "
    "OPA-restricted, not readable by the observer user. ONLY SELECT / SHOW / "
    "DESCRIBE / WITH / EXPLAIN are permitted — "
    "any write or DDL statement is refused. Use this to confirm a data "
    "signal (row counts, aggregates, distributions, freshness) before "
    "filing a Multica task.",
)
async def query_trino(sql: str) -> str:
    stripped = sql.strip().rstrip(";").strip()
    if not stripped:
        return json.dumps({"error": "empty query"})
    head = stripped.split(None, 1)[0].lower()
    if head not in _READ_ONLY_PREFIXES:
        return json.dumps(
            {
                "error": (
                    f"refused: only read-only queries are allowed "
                    f"(SELECT/SHOW/DESCRIBE/WITH/EXPLAIN); got {head!r}"
                )
            }
        )

    try:
        import trino  # lazy: a missing client must not break module import
        from trino.auth import BasicAuthentication
    except ImportError as exc:  # pragma: no cover - depends on image build
        return json.dumps({"error": f"trino client not installed: {exc}"})

    def _run_sync() -> dict[str, Any]:
        auth = BasicAuthentication(TRINO_USER, TRINO_PASSWORD) if TRINO_PASSWORD else None
        conn = trino.dbapi.connect(
            host=TRINO_HOST,
            port=TRINO_PORT,
            user=TRINO_USER,
            http_scheme=TRINO_HTTP_SCHEME,
            auth=auth,
            catalog=TRINO_CATALOG,
            schema=TRINO_SCHEMA,
            verify=TRINO_VERIFY_TLS,
            extra_credential=[("purpose", TRINO_PURPOSE)] if TRINO_PURPOSE else None,
            request_timeout=HTTP_TIMEOUT_SECONDS,
        )
        cur = conn.cursor()
        try:
            cur.execute(stripped)
            rows = cur.fetchmany(TRINO_MAX_ROWS + 1)
            columns = [c[0] for c in (cur.description or [])]
        finally:
            cur.close()
            conn.close()
        truncated = len(rows) > TRINO_MAX_ROWS
        return {
            "columns": columns,
            "rows": [list(r) for r in rows[:TRINO_MAX_ROWS]],
            "truncated": truncated,
        }

    try:
        result = await asyncio.to_thread(_run_sync)
    except Exception as exc:  # noqa: BLE001 - surface any driver error as JSON
        return json.dumps({"error": f"Trino query failed: {exc}"})
    return json.dumps(result, default=str)


def _om_headers() -> dict[str, str]:
    if not OPENMETADATA_JWT_TOKEN:
        return {}
    return {"Authorization": f"Bearer {OPENMETADATA_JWT_TOKEN}"}


@tool(
    "openmetadata_search",
    "Search the OpenMetadata catalog. Returns a JSON list of matching "
    "entities {fqn, name, entityType, description, tags}. Use this to find "
    "tables/columns by name or to discover which assets carry a "
    "classification (e.g. PII, art.9-health). "
    "Args: query (free text, e.g. 'wia funnel' or 'bsn'), "
    "index (default 'table_search_index'; also 'glossary_term_search_index', "
    "'tag_search_index'), size (default 20, max 50).",
)
async def openmetadata_search(
    query: str, index: str = "table_search_index", size: int = 20
) -> str:
    size = max(1, min(size, 50))
    url = f"{OPENMETADATA_URL}/v1/search/query"
    params = {"q": query, "index": index, "from": 0, "size": size}
    try:
        async with httpx.AsyncClient(timeout=HTTP_TIMEOUT_SECONDS) as client:
            resp = await client.get(url, params=params, headers=_om_headers())
            resp.raise_for_status()
            body = resp.json()
    except httpx.HTTPError as exc:
        return json.dumps({"error": f"OpenMetadata search failed: {exc}"})

    hits = body.get("hits", {}).get("hits", []) if isinstance(body, dict) else []
    out = []
    for h in hits:
        src = h.get("_source", {}) if isinstance(h, dict) else {}
        out.append(
            {
                "fqn": src.get("fullyQualifiedName"),
                "name": src.get("name"),
                "entityType": src.get("entityType"),
                "description": (src.get("description") or "")[:280],
                "tags": [t.get("tagFQN") for t in src.get("tags", []) if isinstance(t, dict)],
            }
        )
    return json.dumps({"results": out})


@tool(
    "openmetadata_get",
    "Fetch a single OpenMetadata REST resource by path and return its JSON. "
    "Read-only (GET only). Use this for data-quality test results, profiler "
    "stats, lineage, or glossary detail once openmetadata_search points you "
    "at an entity. "
    "Args: path (REST path under the API root, e.g. "
    "'v1/dataQuality/testCases?entityLink=...&fields=testCaseResult' or "
    "'v1/tables/name/<fqn>?fields=profile,columns,tags'). "
    "Do NOT include the host or '/api' prefix — just the path.",
)
async def openmetadata_get(path: str) -> str:
    clean = path.lstrip("/")
    if clean.startswith("api/"):
        clean = clean[len("api/") :]
    url = f"{OPENMETADATA_URL}/{clean}"
    try:
        async with httpx.AsyncClient(timeout=HTTP_TIMEOUT_SECONDS) as client:
            resp = await client.get(url, headers=_om_headers())
            resp.raise_for_status()
            body = resp.json()
    except httpx.HTTPError as exc:
        return json.dumps({"error": f"OpenMetadata GET failed: {exc}"})
    # Cap the payload so a huge response can't blow the LLM context window.
    text = json.dumps(body, default=str)
    if len(text) > 12000:
        return json.dumps(
            {"truncated": True, "note": "response > 12k chars; narrow with ?fields=", "head": text[:12000]}
        )
    return text


PLATFORM_DATA_TOOLS = [query_trino, openmetadata_search, openmetadata_get]
