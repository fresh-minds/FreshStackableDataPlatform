# docs/ — Index

Alle documentatie van het UWV Reference Data Platform op één plek. De
[top-level `README.md`](../README.md) is het instappunt; van daar verwijst
deze map dieper.

## Per onderwerp

### Architectuur en context

- [architecture.md](architecture.md) — High-level architectuur, lagen, Definition of Done.
- [context-summary.md](context-summary.md) — Achtergrondsamenvatting van de vier referentiedocumenten (NORA, AVG, BIO, AI Act).
- [compliance-mapping.md](compliance-mapping.md) — Per requirement (R-NORA-/R-AVG-/R-BIO-/R-NIS2-/R-AIACT-) waar het in de repo wordt geadresseerd.

### Beslissingen (ADR's)

- [0001 — Stackable als basis](adr/0001-stackable-as-base.md)
- [0002 — Iceberg vs Delta](adr/0002-iceberg-vs-delta.md)
- [0003 — OPA als Trino-authz](adr/0003-opa-as-trino-authz.md)
- [0004 — OpenMetadata als catalog](adr/0004-openmetadata-as-catalog.md)
- [0005 — dbt-trino als transformatielaag](adr/0005-dbt-trino-as-transform.md)
- [0006 — Delta gekozen voor deze implementatie](adr/0006-delta-chosen-for-this-implementation.md)

### Use cases

Tien use-case-specs onder [`use-cases/`](use-cases/), elk met scope, CGM-
entiteiten, doelbinding, AI-Act-classificatie en Definition-of-Done-anchors.

| ID | Titel | Status |
|---|---|---|
| [UC-01](use-cases/uc01-wia-funnel.md) | WIA-funnel-dashboard (DoD-anchor) | Mart aanwezig |
| [UC-02](use-cases/uc02-wajong-ai.md) | Wajong AI-ondersteuning (hoog-risico) | Placeholder |
| [UC-03](use-cases/uc03-ww-risk.md) | WW-risico-screening (verboden-grens) | Placeholder + guard-test |
| [UC-04](use-cases/uc04-proactieve-tw.md) | Proactieve TW-eligibility | Mart aanwezig |
| [UC-05](use-cases/uc05-client-360.md) | Klant-360 (gepseudonimiseerd) | Mart aanwezig |
| [UC-06](use-cases/uc06-schadelast.md) | Schadelast-prognose 5 jaar | Mart aanwezig |
| [UC-07](use-cases/uc07-dq-polisadm.md) | DQ-dagrapport polisadministratie | Mart aanwezig |
| [UC-08](use-cases/uc08-smz-planning.md) | SMZ-capaciteitsplanning | Placeholder |
| [UC-09](use-cases/uc09-reint-effect.md) | Re-integratie-effectmeting | Mart aanwezig |
| [UC-10](use-cases/uc10-gegevensdiensten.md) | Gegevensdiensten-API | Placeholder |

### Operationeel

- [runbook.md](runbook.md) — Cluster-lifecycle, healthchecks, troubleshooting (skeleton, fase 0).
- [improvements.md](improvements.md) — Roadmap met bekende gaps, prio + effort.
- [documentation-gap-report.md](documentation-gap-report.md) — Aparte audit van doc-coverage.

### Persona-handleidingen

Onder [`handleidingen/`](handleidingen/) staan 13 stap-voor-stap-handleidingen
voor verschillende rollen (WIA-beoordelaar, WW-handhaver, FEZ-analist,
data-steward, platform-admin, …). Zie [handleidingen/README.md](handleidingen/README.md)
voor de index.

## Conventies

- **Taal:** Nederlands voor inhoudelijke content; Engels voor technische
  identifiers (paden, kolomnamen, tool-namen).
- **ADR-format:** numbered, immutable. Een nieuwe beslissing krijgt een
  nieuw ADR; de oude wordt niet bewerkt maar als "superseded by" gemarkeerd.
- **Use-case-format:** scope, CGM-entiteiten, doelbinding, legal_basis,
  risk_tier, DoD-anchor, datapad (bronze → silver → gold).
- **Compliance-meta** in dbt-modellen sluit 1-op-1 aan op
  [`compliance-mapping.md`](compliance-mapping.md). Zie
  [`../dbt/README.md#compliance-velden-in-meta`](../dbt/README.md).

## Bijdragen

`CONTRIBUTING.md` is nog open (zie [improvements #1.18](improvements.md)).
Tot die er is: een nieuwe doc volgt de bestaande structuur (ADR ↔ use-case ↔
handleiding), en kruisverwijzingen worden bijgewerkt in deze index én in de
top-level [`README.md`](../README.md).
