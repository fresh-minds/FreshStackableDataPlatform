/*
  v2-homepage.ts — sample data for the v2 workspace homepage.

  Used by:
    - src/pages/index.astro                   (live /)
    - src/pages/styleguide/portal-v2.astro    (mockup showcase)
    - src/components/shell/WorkspaceHome.astro

  In fase 2+ these arrays are replaced by:
    - RECENTS    → /api/portal/recents       (server-tracked per user)
    - SHORTCUTS  → /api/portal/shortcuts     (derived from role-shortcuts.ts
                                              + OPA-policy mapping)
    - EXPLORE    → static; mirrors src/data/components.ts categories

  For now: dummy data, demonstrating the layout.
*/

// Item type drives the colour-tint behind the brand icon and the chip label.
export type ItemType =
  | 'dashboard' | 'dag' | 'table' | 'notebook' | 'query' | 'pipeline';

// Service slug — must match a filename in portal/public/icons/brand/.
export type ServiceSlug =
  | 'airflow' | 'dbt' | 'grafana' | 'hive' | 'jupyter' | 'kafka'
  | 'keycloak' | 'minio' | 'multica' | 'nifi' | 'opa' | 'openmetadata'
  | 'opensearch' | 'prometheus' | 'spark' | 'superset' | 'trino';

export interface RecentItem {
  type: ItemType;
  service: ServiceSlug;
  title: string;
  subtitle: string;
  owner: string;
  status: 'ok' | 'warn' | 'down' | null;
  starred: boolean;
  href: string;
}

export interface ShortcutItem {
  type: ItemType;
  service: ServiceSlug;
  title: string;
  subtitle: string;
  href: string;
  badge?: string;
}

export interface ExploreItem {
  type: ItemType;
  service: ServiceSlug;
  title: string;
  subtitle: string;
  href: string;
}

export interface ExploreCategory {
  title: string;
  sub: string;
  items: ExploreItem[];
}

// Recent items — most-recently-opened by the user.
export const RECENTS: RecentItem[] = [
  { type: 'dashboard', service: 'superset',     title: 'WIA-monitor 2026',          subtitle: 'Vandaag · 09:14',  owner: 'data_steward',  status: 'ok',   starred: true,  href: '#dash-1' },
  { type: 'dag',       service: 'airflow',      title: 'sales_bronze_to_silver',     subtitle: 'Gisteren · 23:42', owner: 'data_engineer', status: 'down', starred: false, href: '#dag-1' },
  { type: 'notebook',  service: 'jupyter',      title: 'Inkomensanalyse Q1',         subtitle: 'Vandaag · 08:32',  owner: 'researcher',    status: null,   starred: true,  href: '#nb-1' },
  { type: 'table',     service: 'openmetadata', title: 'silver.uwv_wia.aanvraag',    subtitle: '2 dagen geleden',  owner: 'platform',      status: 'ok',   starred: false, href: '#tbl-1' },
  { type: 'query',     service: 'trino',        title: 'WIA-doorlooptijd per regio', subtitle: 'Vandaag · 10:01',  owner: 'data_analyst',  status: null,   starred: false, href: '#q-1' },
  { type: 'pipeline',  service: 'dbt',          title: 'dbt · silver_to_gold_wia',   subtitle: 'Vandaag · 04:30',  owner: 'data_engineer', status: 'ok',   starred: false, href: '#pipe-1' },
];

// Persona-shortcuts — pinned by the active role's playbook.
// In fase 3 this list is computed from role-shortcuts.ts + OPA policy.
export const SHORTCUTS: ShortcutItem[] = [
  { type: 'dag',       service: 'airflow',      title: 'Airflow workflows',     subtitle: '47 DAGs · 12 actief',     href: '#airflow',      badge: 'Persona' },
  { type: 'pipeline',  service: 'dbt',          title: 'dbt-docs lineage',      subtitle: '23 models · silver+gold', href: '#dbt',          badge: 'Persona' },
  { type: 'table',     service: 'openmetadata', title: 'OpenMetadata catalog',  subtitle: '184 tabellen · 6 schema', href: '#openmetadata', badge: 'Persona' },
  { type: 'query',     service: 'trino',        title: 'Trino queries',         subtitle: 'SQLLab · live engine',    href: '#trino',        badge: 'Persona' },
  { type: 'notebook',  service: 'jupyter',      title: 'Jupyter Lab',           subtitle: 'Persoonlijke notebooks',  href: '#jupyter',      badge: 'Persona' },
  { type: 'dashboard', service: 'superset',     title: 'Datakwaliteit silver',  subtitle: 'Superset · DQ-monitor',   href: '#dq',           badge: 'Persona' },
];

// "Verkennen" — all platform services, grouped by stage.
// In fase 1.4+ this list is derived from src/data/components.ts.
export const EXPLORE: ExploreCategory[] = [
  {
    title: 'Pipeline & Compute',
    sub:   'Ingest, transform, query',
    items: [
      { type: 'dag',      service: 'airflow', title: 'Airflow', subtitle: 'Orchestratie',        href: '#airflow' },
      { type: 'pipeline', service: 'spark',   title: 'Spark',   subtitle: 'Distributed compute', href: '#spark' },
      { type: 'query',    service: 'trino',   title: 'Trino',   subtitle: 'SQL-engine',          href: '#trino' },
      { type: 'pipeline', service: 'dbt',     title: 'dbt',     subtitle: 'Transformations',     href: '#dbt' },
      { type: 'dag',      service: 'nifi',    title: 'NiFi',    subtitle: 'Stream ingestion',    href: '#nifi' },
      { type: 'pipeline', service: 'kafka',   title: 'Kafka',   subtitle: 'Event streaming',     href: '#kafka' },
    ],
  },
  {
    title: 'BI & Analyse',
    sub:   'Dashboards, queries, notebooks',
    items: [
      { type: 'dashboard', service: 'superset', title: 'Superset', subtitle: 'Dashboards + SQLLab',     href: '#superset' },
      { type: 'notebook',  service: 'jupyter',  title: 'Jupyter',  subtitle: 'Notebooks (Trino+Delta)', href: '#jupyter' },
      { type: 'pipeline',  service: 'dbt',      title: 'dbt-docs', subtitle: 'Lineage + tests',         href: '#dbt-docs' },
    ],
  },
  {
    title: 'Catalog & Governance',
    sub:   'Discover, lineage, policies',
    items: [
      { type: 'table', service: 'openmetadata', title: 'OpenMetadata', subtitle: 'Catalog + lineage', href: '#openmetadata' },
      { type: 'table', service: 'minio',        title: 'MinIO',        subtitle: 'Object storage',    href: '#minio' },
      { type: 'table', service: 'hive',         title: 'Hive',         subtitle: 'Metastore',         href: '#hive' },
      { type: 'query', service: 'opa',          title: 'OPA',          subtitle: 'Policy engine',     href: '#opa' },
    ],
  },
  {
    title: 'Observability',
    sub:   'Metrics, logs, traces',
    items: [
      { type: 'dashboard', service: 'grafana',    title: 'Grafana',    subtitle: 'Metrics dashboards', href: '#grafana' },
      { type: 'query',     service: 'opensearch', title: 'OpenSearch', subtitle: 'Vector log search',  href: '#opensearch' },
      { type: 'pipeline',  service: 'prometheus', title: 'Prometheus', subtitle: 'Metrics scrape',     href: '#prometheus' },
    ],
  },
];

// Hero stats — in fase 2 fetched from /api/portal/stats.
export interface HeroStat {
  value: string;
  label: string;
  tone?: 'down' | 'ok' | 'warn';
}
export const HERO_STATS: HeroStat[] = [
  { value: '47',  label: 'DAGs' },
  { value: '184', label: 'Tabellen' },
  { value: '23',  label: 'Dashboards' },
  { value: '1',   label: 'Gefaald', tone: 'down' },
];
