# Toegang aanvragen tot data — gebruikersgids

Praktische gids voor het aanvragen van toegang tot een dataset op het UWV
data-platform. Architectuur: zie [ADR-0008](adr/0008-self-service-data-access.md).
Bridge-service: zie [platform/18-om-access-bridge/](../platform/18-om-access-bridge/README.md).

---

## TL;DR — 30 seconden (portal-flow)

1. Open Mijn werkplek → scroll naar **"Andere data nodig?"** → klik **"Vraag toegang aan"**.
2. Vul het formulier in: dataset-FQN, gebruikersnaam, doelbinding, motivatie.
3. Submit. De portal maakt namens jou een Task aan in OpenMetadata en stuurt 'm naar de owner.
4. Bij approval krijg je automatisch de rol `data_access:<catalog>.<schema>` toegekend.

Direct: `https://platform.uwv-platform.local:8443/access-request`.

> Liever handmatig in OpenMetadata? Dat kan ook — zie [§ Handmatige variant](#handmatige-variant-direct-in-openmetadata) onderaan.

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

## Portal-flow (aanbevolen)

### 1. Open het access-request-formulier

Via Mijn werkplek → sectie *"Andere data nodig?"* → knop **"Vraag
toegang aan"**. Of direct: <https://platform.uwv-platform.local:8443/access-request>.

### 2. Vul de velden in

| Veld | Wat je invult |
|---|---|
| **Welke dataset?** | OM-FQN — bv. `uwv-trino.gold.uc11_klantreis.mart_uc11_klantreis_events`. Vind 'm via OpenMetadata → Explore → klik op het asset → kopieer de FQN onder de titel. |
| **Wie ben je?** | Je Keycloak-gebruikersnaam (eerste deel van je e-mail, bv. `researcher`, `fez.analist`). |
| **Voor welk doel?** | Kies een doelbinding (AVG art. 5 lid 1b). |
| **Hoe lang?** | Optioneel — bv. "2 maanden, t/m 2026-08-01". |
| **Motivatie** | Korte uitleg: project, waarom de bestaande aggregaten niet volstaan, etc. |

### 3. Verzend

De portal maakt namens jou een Task aan in OpenMetadata, met
**`Request Access`** automatisch in de description en de owner van het
asset als assignee. Je ziet meteen of het gelukt is + de Task-ID.

### 4. Wat ziet de Reviewer?

De Owner/Reviewer:
- Krijgt notificatie in OM (Activity Feed van het asset + **My Data**).
- Klikt **Accept Suggestion** of **Resolve → Approved**.
- Bij Reject: motivatie in een comment; geen grant.

### 5. Bij approval — automatisch

1. OM publiceert een `taskResolved`-event naar de [om-access-bridge](../platform/18-om-access-bridge/) (HMAC-signed).
2. Bridge parsed het asset FQN → `<catalog>.<schema>` → ensures realm-role `data_access:<catalog>.<schema>` in Keycloak en kent 'm aan jou toe.
3. Bij je volgende JWT-refresh (binnen 15 min) zit de nieuwe rol in je token.
4. OPA-Rego accepteert de rol als grant; doelbinding moet kloppen met de purposes die op die resource staan (zie [data.json](../platform/10-opa/policies/data.json) → `resource_purposes`).

---

## Voorbeelden

### Voorbeeld 1 — Researcher wil naar UC-11 klantreis-mart

```
Asset:      uwv-trino.gold.uc11_klantreis.mart_uc11_klantreis_events
Requester:  researcher
Purpose:    onderzoek
Duration:   2 maanden, t/m 2026-08-01
Motivation: UC-11 funnel-analyse — afsluitratio per kanaal. Synthetische
            cohort + aggregaten, geen individuele BSN's.
```

Grant na approval: realm-role `data_access:gold.uc11_klantreis`.

### Voorbeeld 2 — FEZ-analist wil bronze-data voor reconciliatie

```
Asset:      uwv-trino.bronze.uwv.polisadm_ikv
Requester:  fez.analist
Purpose:    kwaliteitscontrole
Duration:   2 weken
Motivation: Q2 bronze-reconciliatie — silver/gold-aggregaten checken
            tegen bronze na Q2-ETL-incident.
```

Grant: `data_access:bronze.uwv`.

---

## Handmatige variant (direct in OpenMetadata)

Voor wie liever in OM blijft, of voor scriptbare scenario's: dezelfde
flow handmatig.

1. Open <https://openmetadata.uwv-platform.local:8443>.
2. Sidebar links → **Explore** → filter Tables → zoek dataset.
3. Op asset-pagina: tab **Activity Feed** → **+ Add Task** → **Request Description**.
4. **Description begint met `Request Access`** — anders triggert de bridge niet.
5. Assignee = de Owner / Reviewer rechts op de asset-pagina.
6. Submit. Verder loopt het identiek aan de portal-flow.

> De portal-flow doet stap 3–5 voor je en voorkomt dat je de
> "Request Access"-string vergeet (anders blijft de Task hangen).

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
