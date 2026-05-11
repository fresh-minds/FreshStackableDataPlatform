# Toegang aanvragen tot data — gebruikersgids

Praktische gids voor het aanvragen van toegang tot een dataset op het UWV
data-platform. Architectuur: zie [ADR-0008](adr/0008-self-service-data-access.md).
Bridge-service: zie [platform/18-om-access-bridge/](../platform/18-om-access-bridge/README.md).

---

## TL;DR — 30 seconden

1. Open Mijn werkplek → scroll naar **"Andere data nodig?"** → klik **"Vraag toegang aan in de catalogus"**. (Of ga rechtstreeks naar OpenMetadata.)
2. Zoek je dataset in **Explore** → klik 'm aan.
3. Tab **Activity Feed** → **Add Task** → type **Request Description**.
4. **Titel/description begint met `Request Access`** — anders triggert de bridge niet (convention guard).
5. Assignee = de Owner / Reviewer van het asset.
6. Submit. Reviewer keurt de Task goed → je krijgt automatisch de juiste rol toegekend bij je volgende login.

---

## Wat is "toegang aanvragen" hier?

Het UWV-platform gebruikt **default-deny** met doelbinding (R-AVG-06). Jouw
primaire rol (`wia_beoordelaar`, `crm_medewerker`, `researcher`, …)
bepaalt welke catalogs/schemas je *standaard* mag zien. Als je daarnaast
toegang nodig hebt tot een andere zone — bv. `gold.uc05_client_360` —
loopt dat via deze flow:

1. Jij maakt een Task op het asset in OpenMetadata.
2. De Owner/Reviewer keurt de Task goed.
3. De **om-access-bridge** vertaalt de approval naar een realm-role
   `data_access:<catalog>.<schema>` in Keycloak.
4. OPA-Rego herkent die rol als grant; Trino laat de query door zolang je
   een doelbinding-purpose declareert die op de granted resource staat.

De grant geldt op **schema-niveau** (catalog.schema), niet per tabel.

---

## Stap-voor-stap UI

### 1. Open OpenMetadata

Via de portal: Mijn werkplek → sectie *"Andere data nodig?"* → knop
**"Vraag toegang aan in de catalogus"**. SSO regelt dat je niet opnieuw
hoeft in te loggen.

Direct: https://openmetadata.uwv-platform.local

### 2. Zoek je dataset

- Sidebar links → **Explore**.
- Filter **Service type = Database / Table** (de meeste UWV-data zit in
  Trino-tables onder `trino → bronze | silver | gold | sensitive`).
- Zoek bv. `mart_uc05_client_360` en klik het asset aan.

Je weet niet welke dataset je nodig hebt? Check de
[CGM glossary](../platform/13-openmetadata-config/glossary-cgm.yaml) — elke
CGM-term linkt naar de relevante tabellen.

### 3. Maak een access-request Task

Op de asset-detail-pagina:

- Tab **Activity Feed** (of **Conversations**) onderaan.
- Knop **+ Add Task** of het **`...`-menu → Request Description**.
- Type kiezen: **Request Description** (OM 1.5 heeft geen aparte
  *Request Access*-type — `Request Description` is onze conventie-drager).

### 4. Vul het Task-formulier in — de **conventie**

| Veld | Wat je invult | Waarom |
|---|---|---|
| **Title / Description** | Start met `Request Access` — bijv. *"Request Access — gebruiker `alice.researcher`, doel `klantcontact`, einddatum 2026-08-01."* | De bridge filtert op deze keyword (convention guard). Zonder `request access` in de description doet de bridge niets. |
| **Assignees** | De Owner van het asset of een Reviewer (zie de **Owners**-sectie rechts op de asset-pagina) | Alleen Owners/Reviewers krijgen Resolve-rechten in OM. |
| **Suggest description** | Mag leeg blijven, of plak een korte motivatie. | Niet kritiek voor de grant — wel handig voor audit-trail. |

> **Belangrijk** — de string `Request Access` (case-insensitive) moet in
> de **description** of **message** van de Task voorkomen. Zonder deze
> markering negeert de bridge het event (HTTP 400 in de logs).

### 5. Submit

Je ziet de Task verschijnen in de Activity Feed. De Assignee krijgt een
notificatie. Sluit het tabblad en wacht.

### 6. Wat ziet de Reviewer?

De Owner/Reviewer:

- Ziet de Task in hun **My Data** of in de Activity Feed van het asset.
- Klikt **Accept Suggestion** of **Resolve** met resolution **Approved**.
- Bij Reject: motivatie in een comment; geen grant; jij krijgt notificatie.

### 7. Wat gebeurt er bij approval?

1. OM publiceert een `taskResolved`-event naar de [om-access-bridge](../platform/18-om-access-bridge/) (HMAC-signed).
2. Bridge parsed het asset FQN → `<catalog>.<schema>` → ensures realm-role
   `data_access:<catalog>.<schema>` in Keycloak en kent 'm aan jou toe.
3. Bij je **volgende JWT-refresh** (binnen 15 min — `accessTokenLifespan: 900s`) zit de nieuwe rol in je token.
4. OPA-Rego accepteert de rol als grant; doelbinding moet kloppen met de
   purposes die op die resource staan (zie
   [data.json](../platform/10-opa/policies/data.json) → `resource_purposes`).

---

## Voorbeelden

### Voorbeeld 1 — Researcher wil naar CRM-mart

```
Titel:        Request Access — UC-05 evaluatieanalyse
Description:  Request Access — gebruiker alice.researcher, doel klantcontact.
              Project: UC-05 effectiviteit telefonisch klantcontact. Periode:
              juni-augustus 2026. Synthetische cohort + aggregaten, geen
              individuele BSN's gebruikt.
Asset:        trino.gold.uc05_client_360.mart_uc05_client_360
Assignees:    data.steward + crm.medewerker
```

Grant na approval: realm-role `data_access:gold.uc05_client_360`.
Doelbinding-check: query moet `purpose=klantcontact` of `purpose=behandeling` declareren (zie `resource_purposes` mapping).

### Voorbeeld 2 — FEZ-analist wil bronze-data voor reconciliatie

```
Titel:        Request Access — Q2 bronze-reconciliatie polisadm
Description:  Request Access — gebruiker fez.analist, doel kwaliteitscontrole.
              Korte engagement (2 weken) om silver/gold-aggregaten tegen
              bronze te checken na de Q2-ETL-incident.
Asset:        trino.bronze.uwv.polisadm_ikv
Assignees:    data.engineer + data.steward
```

Grant: `data_access:bronze.uwv`. NB: `data.engineer` heeft JIT-eis — de
approval geldt voor de duur van het project.

---

## Veelgestelde vragen

**Hoe lang duurt het voor de grant actief is?**
Zodra de Task is gesloten met Approved: binnen seconden in Keycloak,
binnen één JWT-refresh in Trino (≤ 15 min, of forceer met logout-login).

**Kan ik mijn grants zien?**
Ja — in OpenMetadata onder je profiel zie je je rollen (via SSO). Of in
Keycloak: open `/realms/uwv/account/` en bekijk de "Roles" sectie.

**Hoe trek ik een grant in?**
Vraag een platform-admin om de `data_access:<...>`-rol uit Keycloak te
verwijderen. Een automatische intrekkings-flow (TTL op grant) staat als
follow-up in [docs/improvements.md](improvements.md).

**Wat als de Owner/Reviewer niet reageert?**
Default-SLA: 5 werkdagen. Daarna mag je platform-admin escaleren. (Een
SLA-DAG op open Tasks is een open issue.)

**De bridge zegt 400 op mijn Task — wat ging er fout?**
Drie veelvoorkomende oorzaken:

| Status / log-bericht | Wat te doen |
|---|---|
| `Task is niet als access-request gemarkeerd` | Voeg `Request Access` toe aan de description en re-submit. |
| `Asset FQN ... niet bruikbaar` | Asset is geen Trino-table. Alleen `trino.<catalog>.<schema>.<table>` werkt; voor andere asset-types (Topics, Dashboards) is dit pad nog niet ondersteund. |
| `Task niet approved` | Reviewer heeft de Task gesloten met een andere resolution (Closed zonder Approved). Maak een nieuwe Task. |

---

## Voor reviewers — wat doe ik?

Als Owner/Reviewer van een dataset:

1. Je krijgt notificatie in OM bij een nieuwe access-request Task.
2. Bekijk de description: wie vraagt, waarvoor, hoe lang.
3. Check of de aanvrager de purpose mag declareren (zie
   [trino-doelbinding.rego](../opa-policies-src/trino/trino-doelbinding.rego))
   — als de aanvrager's primaire rol de purpose niet kent, helpt de grant
   niet en moet je afwijzen of escaleren.
4. Klik **Accept Suggestion** / **Resolve → Approved** in OM.
5. Vermeld in een comment de geldigheidsduur (audit-trail).

Voor afwijzing: zelfde knoppen maar resolution **Closed** zonder approved;
voeg motivatie toe.

---

## Voor ontwikkelaars — pad voor uitbreiding

- **Custom Task-type "Request Access"**: vereist OM 1.6+ of een
  community-plugin. Out of scope voor MVP.
- **Portal-formulier** dat de Task automatisch aanmaakt (optie B uit
  ADR-0008 follow-up): heeft een ADR-0009 nodig.
- **TTL op grants**: dagelijkse CronJob die `data_access:*` rollen ouder
  dan X weken intrekt. Mooie eerste-uitbreiding.
- **Inzage/wisrecht (R-AVG-10)**: dit is een **andere** flow — gebruiker
  vraagt inzage in eigen data, niet toegang tot een dataset. Zie
  `gdpr_request`-DAG in [docs/improvements.md](improvements.md).
