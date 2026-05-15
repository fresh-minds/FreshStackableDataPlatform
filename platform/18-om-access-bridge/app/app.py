"""OpenMetadata → Keycloak access bridge.

Twee kanten:

  1. Webhook-receiver: ontvangt taskResolved-events van OpenMetadata,
     verifieert HMAC, kent rol `data_access:<catalog>.<schema>` toe aan
     de aanvrager in Keycloak.

  2. Portal-API: POST /api/request maakt namens de gebruiker een access-
     request Task aan in OpenMetadata (conventie "Request Access" in
     description). Hiermee hoeft de eindgebruiker OM niet in om de Task
     handmatig in te vullen — het portal-formulier doet dat via deze
     endpoint.

Endpoints:

    POST /webhooks/om      — primaire webhook-receiver (HMAC)
    POST /api/request      — portal-facing: maak een access-request Task
    POST /replay/{task_id} — manueel her-toepassen (bij offline-misser)
    GET  /health           — liveness probe

Event-shape (subset van OM's webhook payload):

    {
      "entityType": "task",
      "eventType":  "taskResolved",
      "task": {
        "id":          "<uuid>",
        "status":      "Closed",
        "resolution":  "approved" | "rejected",
        "assignees":   [{"name": "data.steward", ...}],
        "createdBy":   "wia.beoordelaar",
        "about":       "trino.gold.uc05_client_360.mart_uc05_client_360"
      }
    }

`about` is de OpenMetadata FQN van de target — voor tables:
`<service>.<database>.<schema>.<table>`. We mappen de eerste twee dotted
segmenten naar `<catalog>.<schema>` (database = catalog in Trino-context).

Security: HMAC-SHA256 over de raw body met shared secret in env
`OM_WEBHOOK_SECRET`; header `X-OM-Signature: sha256=<hex>`. Replay-window:
±300s op `X-OM-Timestamp` (unix-seconds). Idempotent: zelfde task-id
twee keer is een no-op.
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import os
import time
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Header, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

LOG = logging.getLogger("om-access-bridge")
logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))

KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "http://keycloak.uwv-auth.svc.cluster.local:8080")
KEYCLOAK_REALM = os.environ.get("KEYCLOAK_REALM", "uwv")
KEYCLOAK_CLIENT_ID = os.environ.get("KEYCLOAK_CLIENT_ID", "om-access-bridge")
KEYCLOAK_CLIENT_SECRET = os.environ.get("KEYCLOAK_CLIENT_SECRET", "")
OM_WEBHOOK_SECRET = os.environ.get("OM_WEBHOOK_SECRET", "")
OM_BASE_URL = os.environ.get("OM_BASE_URL", "http://openmetadata.uwv-meta.svc.cluster.local:8585")
OM_ADMIN_TOKEN = os.environ.get("OM_ADMIN_TOKEN", "")
CORS_ALLOWED_ORIGINS = [
    o.strip() for o in os.environ.get("CORS_ALLOWED_ORIGINS", "").split(",") if o.strip()
]
REPLAY_WINDOW_SECONDS = int(os.environ.get("REPLAY_WINDOW_SECONDS", "300"))

# Trino's catalog naming komt overeen met OM's database-segment, niet
# service. Een aanvraag op een glossary-term zonder asset-link wordt
# afgewezen (kan niet naar concrete schema mappen).
#
# OM ingest registreert Trino als service "uwv-trino" (zie
# platform/13-openmetadata-config/services/). Oude conventie "trino"
# blijft als backward-compat — beide herkenbaar.
SUPPORTED_SERVICES = {"trino", "uwv-trino"}

app = FastAPI(title="OM Access Bridge — UWV data platform")

if CORS_ALLOWED_ORIGINS:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=CORS_ALLOWED_ORIGINS,
        allow_methods=["GET", "POST", "OPTIONS"],
        allow_headers=["Content-Type"],
        allow_credentials=False,
    )

# In-memory replay-protectie. State is best-effort; bij restart willen we
# liever dubbel-applyen (idempotent in Keycloak) dan grants missen.
_processed_events: set[str] = set()


# ---------------------------------------------------------------------------
# HMAC verify
# ---------------------------------------------------------------------------


def _verify_signature(raw_body: bytes, signature_header: str, timestamp: str) -> None:
    if not OM_WEBHOOK_SECRET:
        raise HTTPException(status_code=500, detail="OM_WEBHOOK_SECRET niet geconfigureerd")
    if not signature_header or not signature_header.startswith("sha256="):
        raise HTTPException(status_code=401, detail="Ontbrekende of ongeldige X-OM-Signature")
    try:
        ts = int(timestamp)
    except (TypeError, ValueError):
        raise HTTPException(status_code=401, detail="Ongeldig X-OM-Timestamp")
    drift = abs(time.time() - ts)
    if drift > REPLAY_WINDOW_SECONDS:
        raise HTTPException(status_code=401, detail=f"Timestamp buiten ±{REPLAY_WINDOW_SECONDS}s window")
    # Sign(payload) = HMAC(secret, f"{timestamp}.{raw_body}")
    signed = f"{timestamp}.".encode() + raw_body
    expected = hmac.new(OM_WEBHOOK_SECRET.encode(), signed, hashlib.sha256).hexdigest()
    received = signature_header.split("=", 1)[1]
    if not hmac.compare_digest(expected, received):
        raise HTTPException(status_code=401, detail="HMAC-signature klopt niet")


# ---------------------------------------------------------------------------
# Keycloak client
# ---------------------------------------------------------------------------


class Keycloak:
    """Dunne wrapper rond Keycloak Admin REST API.

    Houdt geen tokens vast tussen requests; goedkoper en simpeler dan
    refresh-handling, en het volume (één call per approval) rechtvaardigt
    geen pool.
    """

    def __init__(self, base_url: str, realm: str, client_id: str, client_secret: str) -> None:
        self._base = base_url.rstrip("/")
        self._realm = realm
        self._client_id = client_id
        self._client_secret = client_secret

    async def _token(self, client: httpx.AsyncClient) -> str:
        url = f"{self._base}/realms/{self._realm}/protocol/openid-connect/token"
        r = await client.post(
            url,
            data={
                "grant_type": "client_credentials",
                "client_id": self._client_id,
                "client_secret": self._client_secret,
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        r.raise_for_status()
        return r.json()["access_token"]

    async def _find_user(self, client: httpx.AsyncClient, token: str, username: str) -> dict[str, Any]:
        r = await client.get(
            f"{self._base}/admin/realms/{self._realm}/users",
            params={"username": username, "exact": "true"},
            headers={"Authorization": f"Bearer {token}"},
        )
        r.raise_for_status()
        users = r.json()
        if not users:
            raise HTTPException(status_code=404, detail=f"Keycloak-user {username!r} niet gevonden")
        return users[0]

    async def _ensure_role(self, client: httpx.AsyncClient, token: str, role_name: str) -> dict[str, Any]:
        # GET role → if 404, POST.
        get = await client.get(
            f"{self._base}/admin/realms/{self._realm}/roles/{role_name}",
            headers={"Authorization": f"Bearer {token}"},
        )
        if get.status_code == 200:
            return get.json()
        if get.status_code != 404:
            get.raise_for_status()

        create = await client.post(
            f"{self._base}/admin/realms/{self._realm}/roles",
            json={
                "name": role_name,
                "description": f"Self-service data access grant via OpenMetadata ({role_name})",
                "attributes": {"grantedBy": ["om-access-bridge"]},
            },
            headers={"Authorization": f"Bearer {token}"},
        )
        # 201 = nieuwe rol; 409 = race-condition, beide is "rol bestaat nu".
        if create.status_code not in (201, 409):
            create.raise_for_status()

        get_after = await client.get(
            f"{self._base}/admin/realms/{self._realm}/roles/{role_name}",
            headers={"Authorization": f"Bearer {token}"},
        )
        get_after.raise_for_status()
        return get_after.json()

    async def grant_role(self, username: str, role_name: str) -> None:
        async with httpx.AsyncClient(timeout=10.0) as client:
            token = await self._token(client)
            user = await self._find_user(client, token, username)
            role = await self._ensure_role(client, token, role_name)
            r = await client.post(
                f"{self._base}/admin/realms/{self._realm}/users/{user['id']}/role-mappings/realm",
                json=[{"id": role["id"], "name": role["name"]}],
                headers={"Authorization": f"Bearer {token}"},
            )
            # 204 = ok; 409 = al toegekend (idempotent ok).
            if r.status_code not in (204, 409):
                r.raise_for_status()


keycloak = Keycloak(KEYCLOAK_URL, KEYCLOAK_REALM, KEYCLOAK_CLIENT_ID, KEYCLOAK_CLIENT_SECRET)


# ---------------------------------------------------------------------------
# OpenMetadata client (Task-creatie)
# ---------------------------------------------------------------------------


class OpenMetadata:
    """Dunne wrapper voor het aanmaken van een Task in OpenMetadata.

    Gebruikt een long-lived admin/ingestion-bot JWT — POST namens een
    gebruiker via het `from`-veld van het Thread/Task-object.
    """

    def __init__(self, base_url: str, token: str) -> None:
        self._base = base_url.rstrip("/")
        self._token = token
        # OM 1.5+ verwacht UUIDs in EntityReferences; cache lookups om
        # round-trips te beperken.
        self._user_id_cache: dict[str, str] = {}

    def _auth(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self._token}"}

    async def lookup_user_id(self, client: httpx.AsyncClient, username: str) -> str | None:
        if username in self._user_id_cache:
            return self._user_id_cache[username]
        r = await client.get(
            f"{self._base}/api/v1/users/name/{username}",
            headers=self._auth(),
        )
        if r.status_code == 200:
            uid = r.json().get("id")
            if uid:
                self._user_id_cache[username] = uid
                return uid
        LOG.warning("OM user %s niet vindbaar (status=%d)", username, r.status_code)
        return None

    async def ensure_user(self, client: httpx.AsyncClient, username: str) -> str:
        """Vind of maak een OM-user aan voor `username`.

        OM 1.5 maakt users normaal automatisch aan bij eerste SSO-login,
        maar voor het portal-form (waar de gebruiker mogelijk nog nooit
        OM heeft geopend) ensuren we hier expliciet. Idempotent op 409.
        """
        uid = await self.lookup_user_id(client, username)
        if uid:
            return uid
        r = await client.post(
            f"{self._base}/api/v1/users",
            json={
                "name": username,
                "email": f"{username}@uwv-platform.local",
                "isBot": False,
                "isAdmin": False,
            },
            headers={**self._auth(), "Content-Type": "application/json"},
        )
        if r.status_code in (200, 201):
            uid = r.json().get("id")
            if uid:
                self._user_id_cache[username] = uid
                return uid
        if r.status_code == 409:  # race condition — fetch again
            uid = await self.lookup_user_id(client, username)
            if uid:
                return uid
        LOG.error("OM ensure_user faalde voor %s: %s %s", username, r.status_code, r.text[:200])
        raise HTTPException(
            status_code=502,
            detail=f"Kan OM-user {username!r} niet aanmaken (status={r.status_code})",
        )

    async def get_table(self, client: httpx.AsyncClient, fqn: str) -> dict[str, Any]:
        r = await client.get(
            f"{self._base}/api/v1/tables/name/{fqn}",
            params={"fields": "owners"},
            headers=self._auth(),
        )
        if r.status_code == 404:
            raise HTTPException(
                status_code=404,
                detail=f"Asset {fqn!r} niet gevonden in OpenMetadata (run ingestion?)",
            )
        r.raise_for_status()
        return r.json()

    async def resolve_assignee_refs(
        self,
        client: httpx.AsyncClient,
        usernames: list[str],
    ) -> list[dict[str, str]]:
        refs: list[dict[str, str]] = []
        for u in usernames:
            uid = await self.lookup_user_id(client, u)
            if uid:
                refs.append({"id": uid, "type": "user", "name": u})
        return refs

    async def create_request_task(
        self,
        *,
        requester: str,
        fqn: str,
        purpose: str,
        motivation: str,
        duration: str,
        assignees: list[dict[str, str]],
    ) -> dict[str, Any]:
        message = (
            f"Request Access — gebruiker {requester}, doel {purpose}"
            f"{', geldig ' + duration if duration else ''}.\n\n"
            f"Motivatie:\n{motivation or '(geen)'}"
        )
        # OM 1.5 CreateThread schema: het veld heet `taskDetails`, niet `task`.
        # Known fields: chatbotDetails, message, from, announcementDetails,
        # about, addressedTo, type, taskDetails.
        body = {
            "from": requester,
            "message": message,
            "about": f"<#E::table::{fqn}>",
            "type": "Task",
            "taskDetails": {
                "type": "RequestDescription",
                "assignees": assignees,
            },
        }
        async with httpx.AsyncClient(timeout=15.0) as client:
            r = await client.post(
                f"{self._base}/api/v1/feed",
                json=body,
                headers={**self._auth(), "Content-Type": "application/json"},
            )
            if r.status_code not in (200, 201):
                LOG.error("OM Task POST faalde: %s %s", r.status_code, r.text[:500])
                raise HTTPException(
                    status_code=502,
                    detail=f"OM Task POST faalde (status={r.status_code})",
                )
            return r.json()


openmetadata = OpenMetadata(OM_BASE_URL, OM_ADMIN_TOKEN)


class AccessRequestBody(BaseModel):
    asset_fqn: str = Field(..., description="trino.<catalog>.<schema>.<table>")
    requester: str = Field(..., min_length=1, description="username uit Keycloak")
    purpose: str = Field(..., min_length=1, description="doelbinding (klantcontact, etc.)")
    motivation: str = ""
    duration: str = ""


# ---------------------------------------------------------------------------
# Event handling
# ---------------------------------------------------------------------------


def _parse_grant(event: dict[str, Any]) -> tuple[str, str, str]:
    """Return (requester_username, role_name, task_id).

    Raises HTTPException als het event niet matched onze contract — een
    afwijzing op format is correcter dan stilzwijgend negeren.
    """
    if event.get("entityType") != "task":
        raise HTTPException(status_code=400, detail=f"Niet-task event: {event.get('entityType')!r}")
    task = event.get("task") or {}
    if event.get("eventType") not in {"taskResolved", "taskClosed"}:
        raise HTTPException(status_code=400, detail=f"Niet-resolved event: {event.get('eventType')!r}")
    if (task.get("resolution") or "").lower() != "approved":
        raise HTTPException(status_code=400, detail=f"Task niet approved: {task.get('resolution')!r}")

    requester = task.get("createdBy")
    if not requester:
        raise HTTPException(status_code=400, detail="Task mist 'createdBy'")

    # Convention guard (ADR-0008 / access-request-guide.md): alleen Tasks die
    # expliciet "request access" in titel of description noemen worden als
    # access-request behandeld. Dit voorkomt dat een RequestDescription-Task
    # voor een puur description-doel per ongeluk een grant triggert.
    title_or_msg = " ".join(filter(None, [
        task.get("description"),
        task.get("message"),
        task.get("taskName"),
    ])).lower()
    if "request access" not in title_or_msg:
        raise HTTPException(
            status_code=400,
            detail=(
                "Task is niet als access-request gemarkeerd. Conventie: voeg "
                "'Request Access' toe aan de Task-description om de bridge te "
                "triggeren — zie docs/access-request-guide.md (ADR-0008)."
            ),
        )

    about = task.get("about") or ""
    parts = about.split(".")
    if len(parts) < 3 or parts[0] not in SUPPORTED_SERVICES:
        raise HTTPException(
            status_code=400,
            detail=(
                f"Asset FQN {about!r} niet bruikbaar — verwacht "
                "<trino>.<catalog>.<schema>[.<table>]"
            ),
        )
    catalog, schema = parts[1], parts[2]
    role_name = f"data_access:{catalog}.{schema}"

    task_id = task.get("id") or ""
    if not task_id:
        raise HTTPException(status_code=400, detail="Task mist 'id'")

    return requester, role_name, task_id


# ---------------------------------------------------------------------------
# HTTP endpoints
# ---------------------------------------------------------------------------


@app.get("/health")
async def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "keycloak": KEYCLOAK_URL,
        "realm": KEYCLOAK_REALM,
        "client": KEYCLOAK_CLIENT_ID,
        "om_base": OM_BASE_URL,
        "om_token_configured": bool(OM_ADMIN_TOKEN),
        "cors_origins": CORS_ALLOWED_ORIGINS,
    }


@app.post("/api/request")
async def create_access_request(body: AccessRequestBody) -> dict[str, Any]:
    """Maakt een access-request Task aan op een Trino-asset in OpenMetadata.

    De portal POST hier wanneer een gebruiker het access-request-formulier
    submit. Wij vertalen het naar een Task met de conventie-string
    "Request Access" in de message zodat de bestaande webhook-flow na
    approval een grant uitvoert.
    """
    if not OM_ADMIN_TOKEN:
        raise HTTPException(
            status_code=500, detail="OM_ADMIN_TOKEN niet geconfigureerd in bridge"
        )

    parts = body.asset_fqn.split(".")
    if len(parts) < 4 or parts[0] not in SUPPORTED_SERVICES:
        raise HTTPException(
            status_code=400,
            detail=(
                f"asset_fqn {body.asset_fqn!r} ongeldig — verwacht "
                "trino.<catalog>.<schema>.<table>"
            ),
        )

    async with httpx.AsyncClient(timeout=15.0) as client:
        # Ensure de requester bestaat als OM-user. OM weigert anders
        # CreateThread met "user instance not found" (404).
        await openmetadata.ensure_user(client, body.requester)

        asset = await openmetadata.get_table(client, body.asset_fqn)

        # Owners → assignees. Als asset geen owner heeft, val terug op
        # data.steward zodat de Task niet ongeassigned blijft hangen.
        owners = asset.get("owners") or []
        owner_names = [o["name"] for o in owners if o.get("type") == "user" and o.get("name")]
        if not owner_names:
            owner_names = ["data.steward"]

        assignees = await openmetadata.resolve_assignee_refs(client, owner_names)
        if not assignees:
            raise HTTPException(
                status_code=500,
                detail=(
                    f"Geen van de assignees {owner_names!r} vindbaar als user "
                    "in OpenMetadata — kan Task niet aanmaken."
                ),
            )

        task = await openmetadata.create_request_task(
            requester=body.requester,
            fqn=body.asset_fqn,
            purpose=body.purpose,
            motivation=body.motivation,
            duration=body.duration,
            assignees=assignees,
        )

    LOG.info(
        "Access-request Task aangemaakt: requester=%s asset=%s assignees=%s",
        body.requester,
        body.asset_fqn,
        [a["name"] for a in assignees],
    )

    return {
        "status": "created",
        "task_id": task.get("id"),
        "thread_id": task.get("id"),
        "asset_fqn": body.asset_fqn,
        "assignees": [a["name"] for a in assignees],
        "message": "Aanvraag verzonden. Je krijgt een notificatie in OpenMetadata zodra de owner beslist.",
    }


@app.post("/webhooks/om")
async def webhook_om(
    request: Request,
    x_om_signature: str = Header(default=""),
    x_om_timestamp: str = Header(default=""),
) -> dict[str, str]:
    raw = await request.body()
    _verify_signature(raw, x_om_signature, x_om_timestamp)
    event = await request.json()

    requester, role_name, task_id = _parse_grant(event)
    if task_id in _processed_events:
        LOG.info("Task %s al verwerkt — no-op", task_id)
        return {"status": "duplicate", "task_id": task_id}

    LOG.info("Grant %s → user=%s task=%s", role_name, requester, task_id)
    await keycloak.grant_role(requester, role_name)
    _processed_events.add(task_id)

    return {
        "status": "granted",
        "task_id": task_id,
        "user": requester,
        "role": role_name,
    }


@app.post("/replay/{task_id}")
async def replay_task(task_id: str, event: dict[str, Any]) -> dict[str, str]:
    """Manueel her-toepassen wanneer een webhook gemist is.

    Geen HMAC-check (vereist binnen-cluster reach via service-account RBAC);
    re-uses dezelfde grant-logica.
    """
    _processed_events.discard(task_id)  # forceer re-process
    if (event.get("task") or {}).get("id") != task_id:
        raise HTTPException(status_code=400, detail="Body task.id mismatcht pad-parameter")
    requester, role_name, parsed_task_id = _parse_grant(event)
    await keycloak.grant_role(requester, role_name)
    _processed_events.add(parsed_task_id)
    return {"status": "replayed", "task_id": parsed_task_id, "user": requester, "role": role_name}
