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
  | 'dbt-docs'
  | 'prometheus'
  | 'opensearch'
  | 'multica';

// Legacy "layer" — fijne granulariteit voor de oude card-tag.
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
  | 'observability'
  | 'ai-agents';

// Reference-architecture lanes (Monte-Carlo-stijl).
// Hier groeperen we componenten in de plek die ze in de pipeline innemen.
export type ComponentStage =
  | 'sources'
  | 'ingestion'
  | 'storage'
  | 'transformation'
  | 'consumption'
  | 'discovery'
  | 'pipeline'
  | 'observability'
  | 'identity'
  | 'agents';

export interface PlatformComponent {
  id: ComponentId;
  name: string;
  layer: ComponentLayer;
  stage: ComponentStage;
  short: string;
  purpose: string;
  icon: string;
  url: string | null;
  prometheusJob?: string;
  rolesUsing: string[];
}

export const components: PlatformComponent[] = [
  {
    id: 'keycloak',
    name: 'Keycloak',
    layer: 'auth',
    stage: 'identity',
    short: 'OIDC-identity provider — single sign-on en MFA voor alle componenten.',
    purpose: 'Eén keer inloggen, overal toegang volgens je rol. MFA en audit-log centraal.',
    icon: '/icons/brand/keycloak.svg',
    url: 'https://keycloak.uwv-platform.local:8443',
    prometheusJob: 'keycloak',
    rolesUsing: ['*'],
  },
  {
    id: 'nifi',
    name: 'Apache NiFi',
    layer: 'streaming',
    stage: 'ingestion',
    short: 'Visuele ingestion-flows — bronsystemen → Kafka.',
    purpose: 'Data uit UWV-bronsystemen ophalen en in het platform binnenbrengen.',
    icon: '/icons/brand/nifi.svg',
    url: 'https://nifi.uwv-platform.local:8443',
    prometheusJob: 'nifi',
    rolesUsing: ['platform_admin', 'data_engineer'],
  },
  {
    id: 'kafka',
    name: 'Kafka',
    layer: 'streaming',
    stage: 'ingestion',
    short: 'Event-bus tussen NiFi-ingestion en Spark Structured Streaming.',
    purpose: 'Data-events bufferen en doorzetten naar verwerking. Schaalbare doorvoer.',
    icon: '/icons/brand/kafka.svg',
    url: null,
    prometheusJob: 'kafka',
    rolesUsing: ['platform_admin', 'data_engineer'],
  },
  {
    id: 'minio',
    name: 'MinIO',
    layer: 'storage',
    stage: 'storage',
    short: 'S3-compatible object store met buckets bronze/silver/gold/sensitive.',
    purpose: 'Het lakehouse waar alle data fysiek staat — gelaagd in zones met aparte toegangsregels.',
    icon: '/icons/brand/minio.svg',
    // /go/minio/ is een portal-redirect die de Keycloak SSO-flow start;
    // zie portal/nginx.conf + portal/src/pages/go/minio.astro voor de
    // workaround voor de embedded MinIO Console-quirk via de externe ingress.
    url: '/go/minio/',
    prometheusJob: 'minio',
    rolesUsing: ['platform_admin', 'data_engineer'],
  },
  {
    id: 'hive',
    name: 'Hive Metastore',
    layer: 'metadata',
    stage: 'storage',
    short: 'Catalog backend — houdt tabel-schemas en partities bij voor Trino en Spark.',
    purpose: 'Vertaalt bestanden in MinIO naar tabellen met kolommen en types.',
    icon: '/icons/brand/hive.svg',
    url: null,
    prometheusJob: 'hive',
    rolesUsing: ['platform_admin', 'data_engineer'],
  },
  {
    id: 'spark',
    name: 'Apache Spark',
    layer: 'compute',
    stage: 'transformation',
    short: 'Streaming + batch jobs die Delta-tabellen op MinIO schrijven.',
    purpose: 'Zware data-bewerkingen — opschonen, joinen, aggregeren — in stream of batch.',
    icon: '/icons/brand/spark.svg',
    url: null,
    prometheusJob: 'spark',
    rolesUsing: ['platform_admin', 'data_engineer'],
  },
  {
    id: 'trino',
    name: 'Trino',
    layer: 'query',
    stage: 'transformation',
    short: 'SQL query-engine over Delta-lakehouse, met OPA-authorisatie.',
    purpose: 'Snel SQL draaien over de hele lakehouse — voor dbt-modellen én eindgebruikers.',
    icon: '/icons/brand/trino.svg',
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
    stage: 'transformation',
    short: 'Open Policy Agent — beslist per Trino-query wat een rol mag zien (rij-filters, kolom-maskers, doelbinding).',
    purpose: 'Doelbinding, rij-filters en kolom-maskering afdwingen op iedere query.',
    icon: '/icons/brand/opa.svg',
    url: null,
    prometheusJob: 'opa',
    rolesUsing: ['platform_admin'],
  },
  {
    id: 'superset',
    name: 'Apache Superset',
    layer: 'bi',
    stage: 'consumption',
    short: 'Dashboards en SQL Lab — primaire UI voor de meeste eindgebruikers.',
    purpose: 'Dashboards en ad-hoc analyse voor business-rollen — zonder SQL hoeven kennen.',
    icon: '/icons/brand/superset.svg',
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
    stage: 'discovery',
    short: 'Catalog, glossary, lineage, data-quality.',
    purpose: 'Wat hebben we, wie is eigenaar, hoe is het opgebouwd, en is het op orde?',
    icon: '/icons/brand/openmetadata.svg',
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
    id: 'dbt-docs',
    name: 'dbt docs',
    layer: 'governance',
    stage: 'discovery',
    // Statisch geëxporteerde `dbt docs generate --static`-bundel. Geserveerd
    // door de portal-nginx zelf op /dbt-docs/ — geen aparte service, geen
    // Prometheus-job (vandaar geen status-dot).
    short: 'Modellen, tests, sources en lineage van de dbt-projectdefinities.',
    purpose: 'Wat doen onze dbt-modellen, welke tests draaien er, en hoe vloeit data van staging naar marts?',
    icon: '/icons/brand/dbt.svg',
    url: '/dbt-docs.html',
    rolesUsing: ['data_engineer', 'data_steward', 'platform_admin'],
  },
  {
    id: 'airflow',
    name: 'Apache Airflow',
    layer: 'orchestration',
    stage: 'pipeline',
    short: 'DAG-orchestratie voor batch-jobs en dbt-runs.',
    purpose: 'Plant en bewaakt alle scheduled jobs — wat draait wanneer, in welke volgorde.',
    icon: '/icons/brand/airflow.svg',
    url: 'https://airflow.uwv-platform.local:8443',
    prometheusJob: 'airflow',
    rolesUsing: ['platform_admin', 'data_engineer'],
  },
  {
    id: 'prometheus',
    name: 'Prometheus',
    layer: 'observability',
    stage: 'observability',
    short: 'Metrics + alerts; voedt de status-badges in deze portal.',
    purpose: 'Metrics verzamelen en alerteren als iets stuk dreigt te gaan.',
    icon: '/icons/brand/prometheus.svg',
    url: 'https://prometheus.uwv-platform.local:8443',
    prometheusJob: 'prometheus',
    rolesUsing: ['platform_admin'],
  },
  {
    id: 'opensearch',
    name: 'OpenSearch',
    layer: 'observability',
    stage: 'observability',
    short: 'Logs (Vector) + search-backend voor OpenMetadata.',
    purpose: 'Logs centraal doorzoekbaar maken — debugging en audit-trail.',
    icon: '/icons/brand/opensearch.svg',
    // Externe URL wijst naar OpenSearch Dashboards (port 5601). De REST-API
    // (port 9200) is alleen intern bereikbaar via cluster-DNS.
    url: 'https://opensearch.uwv-platform.local:8443',
    prometheusJob: 'opensearch',
    rolesUsing: ['platform_admin', 'data_steward'],
  },
  {
    id: 'multica',
    name: 'Multica',
    layer: 'ai-agents',
    stage: 'agents',
    // Dev-loop-lane: coördineert coding agents (Claude Code/Codex/Copilot CLI/…)
    // die op de laptop van de developer draaien — de server houdt taken,
    // voortgang en skills bij. Niet hetzelfde als Nanitics (runtime).
    short: 'Coördinatie van coding agents (Claude Code, Codex, Copilot CLI, …) — taken, voortgang, skills.',
    purpose: 'Taken toewijzen aan coding agents; voortgang volgen. Agents draaien op je laptop.',
    icon: '/icons/brand/multica.svg',
    url: 'https://multica.uwv-platform.local:8443',
    prometheusJob: 'multica-backend',
    rolesUsing: ['platform_admin', 'data_engineer'],
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

export function componentsByStage(stage: ComponentStage): PlatformComponent[] {
  return components.filter((c) => c.stage === stage);
}

// Stage-meta voor lane-headers in het reference-diagram en gegroepeerde
// kaarten. Volgorde hier bepaalt de volgorde van de swim-lanes.
export type StageCategory = 'discovery' | 'pipeline' | 'observability' | 'identity' | 'agents';

export interface StageMeta {
  id: ComponentStage;
  title: string;
  blurb: string;
  icon: string;
  // Legacy field used by the older diagram. 'pipeline-step' = main flow;
  // 'overlay' = cross-cutting (discovery / pipeline / observability /
  // agents); 'side' = sources / identity; 'output' = consumption.
  kind: 'pipeline-step' | 'overlay' | 'side' | 'output';
  // For the swim-lane diagram: tints the lane background and eyebrow with
  // the matching --cat-* token. Pipeline-step / output / sources lanes
  // stay neutral.
  category?: StageCategory;
  // Mono tags shown next to the lane title (BATCH / STREAM / etc.).
  tags?: string[];
}

export const stages: StageMeta[] = [
  { id: 'sources',        title: 'Bronnen',                  blurb: 'Synthetische UWV-bronsystemen — batches en streams.',                  icon: '/icons/stage/sources.svg',        kind: 'side',          tags: ['BATCH', 'STREAM'] },
  { id: 'ingestion',      title: 'Ingestie',                 blurb: 'Data binnenhalen en op een event-bus zetten.',                          icon: '/icons/stage/ingestion.svg',      kind: 'pipeline-step', tags: ['BATCH', 'STREAM'] },
  { id: 'storage',        title: 'Opslag & Verwerking',      blurb: 'Lakehouse met zones en een tabel-catalog.',                              icon: '/icons/stage/storage.svg',        kind: 'pipeline-step', tags: ['LAKEHOUSE'] },
  { id: 'transformation', title: 'Transformatie & Modellen', blurb: 'Opschonen, joinen, modelleren — met policy-checks per query.',          icon: '/icons/stage/transformation.svg', kind: 'pipeline-step', tags: ['BATCH', 'POLICY'] },
  { id: 'consumption',    title: 'BI / Analytics',           blurb: 'Eindgebruikers consumeren via dashboards en SQL.',                       icon: '/icons/stage/consumption.svg',    kind: 'output',        tags: ['QUERY'] },
  { id: 'discovery',      title: 'Data Discovery',           blurb: 'Catalog, lineage en data-kwaliteit — wat hebben we eigenlijk?',         icon: '/icons/stage/discovery.svg',      kind: 'overlay',       category: 'discovery' },
  { id: 'pipeline',       title: 'Pipeline-orkestratie',     blurb: 'Wat draait wanneer, in welke volgorde, met welke afhankelijkheid.',     icon: '/icons/stage/pipeline.svg',       kind: 'overlay',       category: 'pipeline' },
  { id: 'observability',  title: 'Observability',            blurb: 'Metrics, logs en alerts om de gezondheid van het platform te zien.',    icon: '/icons/stage/observability.svg',  kind: 'overlay',       category: 'observability' },
  { id: 'identity',       title: 'Identiteit & Toegang',     blurb: 'SSO regelt wie wat mag — elk onderdeel checkt het token.',              icon: '/icons/stage/identity.svg',       kind: 'side',          category: 'identity' },
  // Coding agents lane: coördineert agents die op de laptop van de developer
  // draaien (Multica). De voormalige runtime-agent lane (Nanitics) is uit het
  // platform gehaald en bewaard op de feature/nanitics branch.
  { id: 'agents',         title: 'Agents & AI-tooling',      blurb: 'Coördinatie van coding agents (Multica) en gerelateerde dev-loop tooling.', icon: '/icons/stage/agents.svg',         kind: 'overlay',       category: 'agents' },
];

export function stageById(id: ComponentStage): StageMeta | undefined {
  return stages.find((s) => s.id === id);
}
