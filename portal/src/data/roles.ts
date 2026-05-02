// Rol-metadata: leesbare naam, domein, link naar handleiding.
// Capability-data (catalogs/PII/medisch) wordt geladen uit
// role-mappings.generated.json (gegenereerd uit opa-policies-src).

import roleMappings from './role-mappings.generated.json';

export type RoleId =
  | 'wia_beoordelaar'
  | 'ww_handhaver'
  | 'wajong_arbeidsdeskundige'
  | 'crm_medewerker'
  | 'fez_analist'
  | 'smz_planner'
  | 'proactief_dienstverlener'
  | 'researcher'
  | 'data_steward'
  | 'data_engineer'
  | 'platform_admin';

export interface RoleMeta {
  id: RoleId;
  displayName: string;
  domain: string;
  category: 'business' | 'tech';
  handleidingPath: string;
}

export const roles: RoleMeta[] = [
  { id: 'wia_beoordelaar', displayName: 'WIA-beoordelaar', domain: 'AG / WIA', category: 'business', handleidingPath: 'docs/handleidingen/01-wia-beoordelaar.md' },
  { id: 'ww_handhaver', displayName: 'WW-handhaver', domain: 'WW', category: 'business', handleidingPath: 'docs/handleidingen/02-ww-handhaver.md' },
  { id: 'wajong_arbeidsdeskundige', displayName: 'Wajong-arbeidsdeskundige', domain: 'AG / Wajong', category: 'business', handleidingPath: 'docs/handleidingen/03-wajong-arbeidsdeskundige.md' },
  { id: 'crm_medewerker', displayName: 'CRM-medewerker', domain: 'CRM / Klantcontact', category: 'business', handleidingPath: 'docs/handleidingen/04-crm-medewerker.md' },
  { id: 'fez_analist', displayName: 'FEZ-analist', domain: 'Financiën', category: 'business', handleidingPath: 'docs/handleidingen/05-fez-analist.md' },
  { id: 'smz_planner', displayName: 'SMZ-planner', domain: 'Sociaal-medisch', category: 'business', handleidingPath: 'docs/handleidingen/06-smz-planner.md' },
  { id: 'proactief_dienstverlener', displayName: 'Proactief dienstverlener', domain: 'TW (proactief)', category: 'business', handleidingPath: 'docs/handleidingen/07-proactief-dienstverlener.md' },
  { id: 'researcher', displayName: 'Researcher', domain: 'Onderzoek (sandbox)', category: 'business', handleidingPath: 'docs/handleidingen/08-researcher.md' },
  { id: 'data_steward', displayName: 'Data-steward', domain: 'Governance', category: 'tech', handleidingPath: 'docs/handleidingen/09-data-steward.md' },
  { id: 'data_engineer', displayName: 'Data-engineer', domain: 'Pipelines', category: 'tech', handleidingPath: 'docs/handleidingen/10-data-engineer.md' },
  { id: 'platform_admin', displayName: 'Platform-admin', domain: 'Cluster / security', category: 'tech', handleidingPath: 'docs/handleidingen/11-platform-admin.md' },
];

export interface RoleCapability {
  catalogs: string[];
  schemas: string[] | null;
  purposes: string[];
  can_see_pii: boolean;
  can_see_medical: boolean;
  can_see_bankrekening: boolean;
  regio_filter: boolean;
  break_glass: boolean;
  jit_required?: boolean;
  four_eyes_required?: boolean;
  _role_purpose?: string;
}

const rawRoles = (roleMappings as { uwv_role_mappings: { roles: Record<string, RoleCapability> } })
  .uwv_role_mappings.roles;

export function capabilityFor(role: RoleId): RoleCapability | undefined {
  return rawRoles[role];
}

export function roleById(id: string): RoleMeta | undefined {
  return roles.find((r) => r.id === id);
}

export function isKnownRole(id: string): id is RoleId {
  return roles.some((r) => r.id === id);
}
