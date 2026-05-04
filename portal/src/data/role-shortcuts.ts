// Curated shortcuts per rol — handmatig onderhouden, geen afgeleide data.
// Past bij de "dagelijkse workflows" uit docs/handleidingen/<rol>.md.
//
// Toevoegen van een shortcut = één entry hier; verschijnt automatisch op /me.

import type { RoleId } from './roles';
import type { ComponentId } from './components';

export interface Shortcut {
  title: string;
  hint: string;
  component: ComponentId;
  href: string;
}

export const shortcuts: Record<RoleId, Shortcut[]> = {
  wia_beoordelaar: [
    { title: 'WIA Funnel dashboard', hint: 'Voorraad en doorlooptijden in jouw regio', component: 'superset', href: 'https://superset.uwv-platform.local:8443/dashboard/list/?filters=(slug:wia-funnel)' },
    { title: 'SQL Lab — open > 8 weken', hint: 'Wettelijke termijn-overschrijdingen', component: 'superset', href: 'https://superset.uwv-platform.local:8443/sqllab/' },
    { title: 'Tabel: silver.wia.aanvraag', hint: 'Definities en eigenaren opzoeken', component: 'openmetadata', href: 'https://openmetadata.uwv-platform.local:8443/table/trino.silver.wia.aanvraag' },
  ],
  ww_handhaver: [
    { title: 'WW Risk dashboard', hint: 'Risico-scores per dossier', component: 'superset', href: 'https://superset.uwv-platform.local:8443/dashboard/list/?filters=(slug:ww-risk)' },
    { title: 'Trino: silver.ww + iban onmasked', hint: 'Bankrekening alleen voor handhavingsdoel', component: 'trino', href: 'https://trino.uwv-platform.local:8443' },
    { title: 'Lineage WW-funnel', hint: 'Bron → silver → gold', component: 'openmetadata', href: 'https://openmetadata.uwv-platform.local:8443/lineage/trino.gold.uc03_ww_risk' },
  ],
  wajong_arbeidsdeskundige: [
    { title: 'Wajong Sensitive Vault', hint: '4-eyes check vereist', component: 'trino', href: 'https://trino.uwv-platform.local:8443' },
    { title: 'UC02 Wajong dashboard', hint: 'Reïntegratie-trajecten', component: 'superset', href: 'https://superset.uwv-platform.local:8443/dashboard/list/?filters=(slug:uc02-wajong)' },
    { title: 'Glossary: „participatie” termen', hint: 'Begrippen opéén plek', component: 'openmetadata', href: 'https://openmetadata.uwv-platform.local:8443/glossary' },
  ],
  crm_medewerker: [
    { title: 'Klant 360 (UC-05)', hint: 'BSN gemaskeerd, alleen klantcontact-doel', component: 'superset', href: 'https://superset.uwv-platform.local:8443/dashboard/list/?filters=(slug:client-360)' },
    { title: 'Tabel: gold.uc05_client_360', hint: 'Welke kolommen je ziet', component: 'openmetadata', href: 'https://openmetadata.uwv-platform.local:8443/table/trino.gold.uc05_client_360' },
  ],
  fez_analist: [
    { title: 'Lastprognose (UC-06)', hint: 'Geaggregeerde uitkeringen, geen PII', component: 'superset', href: 'https://superset.uwv-platform.local:8443/dashboard/list/?filters=(slug:uc06-lastprognose)' },
    { title: 'Tabel: gold.uc06_lastprognose', hint: 'Definities + eigenaar', component: 'openmetadata', href: 'https://openmetadata.uwv-platform.local:8443/table/trino.gold.uc06_lastprognose' },
  ],
  smz_planner: [
    { title: 'SMZ Capaciteitsplanning', hint: 'UC-08 — geen cliënt-PII', component: 'superset', href: 'https://superset.uwv-platform.local:8443/dashboard/list/?filters=(slug:uc08-smz)' },
    { title: 'Glossary: spreekuur-typen', hint: 'Welke planning-categorieën bestaan', component: 'openmetadata', href: 'https://openmetadata.uwv-platform.local:8443/glossary' },
  ],
  proactief_dienstverlener: [
    { title: 'TW-eligibility werklijst', hint: 'UC-04 — opt-out gefilterd', component: 'superset', href: 'https://superset.uwv-platform.local:8443/dashboard/list/?filters=(slug:uc04-tw)' },
    { title: 'Doelbinding & opt-out', hint: 'Welke regels gelden voor proactief contact', component: 'openmetadata', href: 'https://openmetadata.uwv-platform.local:8443/glossary/term/proactieve_dienstverlening' },
  ],
  researcher: [
    { title: 'Sandbox-zone', hint: 'Gepseudonimiseerde panels voor onderzoek', component: 'trino', href: 'https://trino.uwv-platform.local:8443' },
    { title: 'Lineage UC-09', hint: 'Hoe het sandbox-panel is opgebouwd', component: 'openmetadata', href: 'https://openmetadata.uwv-platform.local:8443/lineage/trino.sandbox.uc09_research' },
  ],
  data_steward: [
    { title: 'Data Quality dashboard', hint: 'DQ-checks en profielen', component: 'openmetadata', href: 'https://openmetadata.uwv-platform.local:8443/data-quality' },
    { title: 'Glossary onderhouden', hint: 'Termen, eigenaars, classificaties', component: 'openmetadata', href: 'https://openmetadata.uwv-platform.local:8443/glossary' },
    { title: 'Trino: profiler-queries', hint: 'Verkennen op kwaliteits-doel', component: 'trino', href: 'https://trino.uwv-platform.local:8443' },
  ],
  data_engineer: [
    { title: 'NiFi flows', hint: 'Ingestion-pipelines bewerken', component: 'nifi', href: 'https://nifi.uwv-platform.local:8443' },
    { title: 'Airflow DAGs', hint: 'Batch- en dbt-runs', component: 'airflow', href: 'https://airflow.uwv-platform.local:8443' },
    { title: 'MinIO buckets', hint: 'bronze/silver/gold/sensitive', component: 'minio', href: 'https://minio-console.uwv-platform.local:8443' },
    { title: 'JIT-toegang aanvragen', hint: 'Bronze alleen met just-in-time', component: 'keycloak', href: 'https://keycloak.uwv-platform.local:8443/realms/uwv/account' },
  ],
  platform_admin: [
    { title: 'Cluster-status (Prometheus)', hint: 'Up/Down per service', component: 'prometheus', href: '/architecture' },
    { title: 'Keycloak admin', hint: 'Users, rollen, MFA', component: 'keycloak', href: 'https://keycloak.uwv-platform.local:8443/admin' },
    { title: 'OpenSearch logs', hint: 'Audit + applicatie-logs', component: 'opensearch', href: 'https://opensearch.uwv-platform.local:8443' },
    { title: 'Break-glass procedure', hint: 'Alleen in nood; alles wordt gelogd', component: 'opa', href: 'docs/runbook.md' },
  ],
};
