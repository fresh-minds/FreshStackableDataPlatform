// Track-metadata: koppelt rollen aan een korte trackomschrijving en aan de
// volgorde van de drie levels. Modules zelf staan als MDX in src/content/learn.

import type { RoleId } from './roles';

export type Level = 'foundation' | 'practitioner' | 'expert';

export interface LevelMeta {
  id: Level;
  title: string;
  blurb: string;
}

export const levels: LevelMeta[] = [
  { id: 'foundation',   title: 'Foundation',   blurb: 'Wat is dit platform en wat doet jouw rol erop?' },
  { id: 'practitioner', title: 'Practitioner', blurb: 'Hands-on: één concrete taak van begin tot eind.' },
  { id: 'expert',       title: 'Expert',       blurb: 'Eigen werk leveren — bouwen, reviewen, troubleshooten.' },
];

export interface TrackMeta {
  role: RoleId;
  oneLiner: string;
}

// Korte zin per rol — staat boven de track op /learn/<rol>/.
export const tracks: TrackMeta[] = [
  { role: 'wia_beoordelaar',          oneLiner: 'WIA-aanvragen beoordelen met dashboards en doelbinding-bewuste queries.' },
  { role: 'ww_handhaver',             oneLiner: 'WW-risk-signalen interpreteren binnen de grenzen van handhavingsdoel.' },
  { role: 'wajong_arbeidsdeskundige', oneLiner: 'Wajong-dossiers en AI-uitkomsten beoordelen met menselijke regie.' },
  { role: 'crm_medewerker',           oneLiner: 'Klantbeeld opbouwen zonder onnodige PII-exposure.' },
  { role: 'fez_analist',              oneLiner: 'Schadelast en lastprognose analyseren op gemodelleerde marts.' },
  { role: 'smz_planner',              oneLiner: 'Sociaal-medische capaciteitsplanning op geaggregeerde data.' },
  { role: 'proactief_dienstverlener', oneLiner: 'Proactief contact met inzage- en opt-out-discipline.' },
  { role: 'researcher',               oneLiner: 'Onderzoek doen op gepseudonimiseerde sandbox-zones.' },
  { role: 'data_steward',             oneLiner: 'Data-kwaliteit, lineage en classificaties bewaken.' },
  { role: 'data_engineer',            oneLiner: 'Pipelines bouwen van bron tot mart, met tests en lineage.' },
  { role: 'platform_admin',           oneLiner: 'Cluster, identity en operators beheren — incl. break-glass.' },
];

export function trackFor(role: RoleId): TrackMeta | undefined {
  return tracks.find((t) => t.role === role);
}

export function levelMeta(id: Level): LevelMeta {
  return levels.find((l) => l.id === id)!;
}

// Stabiele module-key die door content-frontmatter en localStorage wordt gebruikt.
export function moduleKey(role: RoleId, level: Level, order: number): string {
  return `${role}/${level}/${order}`;
}
