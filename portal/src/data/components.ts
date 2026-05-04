// Centrale registry van platform-componenten.
// Enige plek waar URLs, beschrijvingen en welke rollen welke component
// gebruiken bij elkaar staan. Wordt gelezen door architectuur-diagram,
// rol-werkplek en status-badges.

export type ComponentId =
  | 'keycloak'
  | 'minio'
  | 'hive'
  | 'kafka'
  | 'nifi'
  | 'spark'
  | 'trino'
  | 'opa'
  | 'airflow'
  | 'superset'
  | 'openmetadata'
  | 'prometheus'
  | 'opensearch';

export type ComponentLayer =
  | 'auth'
  | 'storage'
  | 'metadata'
  | 'streaming'
  | 'compute'
  | 'query'
  | 'policy'
  | 'orchestration'
  | 'bi'
  | 'governance'
  | 'observability';

export interface PlatformComponent {
  id: ComponentId;
  name: string;
  layer: ComponentLayer;
  short: string;
  url: string | null;
  prometheusJob?: string;
  rolesUsing: string[];
}

export const components: PlatformComponent[] = [
  {
    id: 'keycloak',
    name: 'Keycloak',
    layer: 'auth',
    short: 'OIDC-identity provider — single sign-on en MFA voor alle componenten.',
    url: 'https://keycloak.uwv-platform.local:8443',
    prometheusJob: 'keycloak',
    rolesUsing: ['*'],
  },
  {
    id: 'minio',
    name: 'MinIO',
    layer: 'storage',
    short: 'S3-compatible object store met buckets bronze/silver/gold/sensitive.',
    url: 'https://minio-console.uwv-platform.local:8443',
    prometheusJob: 'minio',
    rolesUsing: ['platform_admin', 'data_engineer'],
  },
  {
    id: 'hive',
    name: 'Hive Metastore',
    layer: 'metadata',
    short: 'Catalog backend — houdt tabel-schemas en partities bij voor Trino en Spark.',
    url: null,
    prometheusJob: 'hive',
    rolesUsing: ['platform_admin', 'data_engineer'],
  },
  {
    id: 'kafka',
    name: 'Kafka',
    layer: 'streaming',
    short: 'Event-bus tussen NiFi-ingestion en Spark Structured Streaming.',
    url: null,
    prometheusJob: 'kafka',
    rolesUsing: ['platform_admin', 'data_engineer'],
  },
  {
    id: 'nifi',
    name: 'Apache NiFi',
    layer: 'streaming',
    short: 'Visuele ingestion-flows — bronsystemen → Kafka.',
    url: 'https://nifi.uwv-platform.local:8443',
    prometheusJob: 'nifi',
    rolesUsing: ['platform_admin', 'data_engineer'],
  },
  {
    id: 'spark',
    name: 'Apache Spark',
    layer: 'compute',
    short: 'Streaming + batch jobs die Delta-tabellen op MinIO schrijven.',
    url: null,
    prometheusJob: 'spark',
    rolesUsing: ['platform_admin', 'data_engineer'],
  },
  {
    id: 'trino',
    name: 'Trino',
    layer: 'query',
    short: 'SQL query-engine over Delta-lakehouse, met OPA-authorisatie.',
    url: 'https://trino.uwv-platform.local:8443',
    prometheusJob: 'trino',
    rolesUsing: [
      'wia_beoordelaar',
      'ww_handhaver',
      'wajong_arbeidsdeskundige',
      'fez_analist',
      'smz_planner',
      'proactief_dienstverlener',
      'researcher',
      'data_steward',
      'data_engineer',
      'platform_admin',
    ],
  },
  {
    id: 'opa',
    name: 'OPA',
    layer: 'policy',
    short: 'Open Policy Agent — beslist per Trino-query wat een rol mag zien (rij-filters, kolom-maskers, doelbinding).',
    url: null,
    prometheusJob: 'opa',
    rolesUsing: ['platform_admin'],
  },
  {
    id: 'airflow',
    name: 'Apache Airflow',
    layer: 'orchestration',
    short: 'DAG-orchestratie voor batch-jobs en dbt-runs.',
    url: 'https://airflow.uwv-platform.local:8443',
    prometheusJob: 'airflow',
    rolesUsing: ['platform_admin', 'data_engineer'],
  },
  {
    id: 'superset',
    name: 'Apache Superset',
    layer: 'bi',
    short: 'Dashboards en SQL Lab — primaire UI voor de meeste eindgebruikers.',
    url: 'https://superset.uwv-platform.local:8443',
    prometheusJob: 'superset',
    rolesUsing: [
      'wia_beoordelaar',
      'ww_handhaver',
      'wajong_arbeidsdeskundige',
      'crm_medewerker',
      'fez_analist',
      'smz_planner',
      'proactief_dienstverlener',
      'researcher',
      'data_steward',
      'platform_admin',
    ],
  },
  {
    id: 'openmetadata',
    name: 'OpenMetadata',
    layer: 'governance',
    short: 'Catalog, glossary, lineage, data-quality.',
    url: 'https://openmetadata.uwv-platform.local:8443',
    prometheusJob: 'openmetadata',
    rolesUsing: [
      'wia_beoordelaar',
      'ww_handhaver',
      'wajong_arbeidsdeskundige',
      'crm_medewerker',
      'fez_analist',
      'smz_planner',
      'researcher',
      'data_steward',
      'data_engineer',
      'platform_admin',
    ],
  },
  {
    id: 'prometheus',
    name: 'Prometheus',
    layer: 'observability',
    short: 'Metrics + alerts; voedt de status-badges in deze portal.',
    url: null,
    prometheusJob: 'prometheus',
    rolesUsing: ['platform_admin'],
  },
  {
    id: 'opensearch',
    name: 'OpenSearch',
    layer: 'observability',
    short: 'Logs (Vector) + search-backend voor OpenMetadata.',
    url: null,
    prometheusJob: 'opensearch',
    rolesUsing: ['platform_admin', 'data_steward'],
  },
];

export function componentsForRole(role: string): PlatformComponent[] {
  return components.filter(
    (c) => c.rolesUsing.includes('*') || c.rolesUsing.includes(role),
  );
}

export function componentById(id: ComponentId): PlatformComponent | undefined {
  return components.find((c) => c.id === id);
}
