// External-link constants used across the portal. Centralised so a CNAME
// switch (GitHub Pages → custom domain) is a one-line change.

// Public documentation site (MkDocs Material, gebouwd door
// .github/workflows/docs.yml). Voor custom domain: pas dit aan én
// configureer de CNAME in docs/CNAME.
export const DOCS_URL = 'https://fresh-minds.github.io/FreshStackableDataPlatform/';

// Deep-link naar een specifieke architectuurlaag in de docs. De anchors
// komen overeen met de stage-id's in `components.ts` (identity, ingestion,
// storage, transformation, consumption, discovery, pipeline, observability,
// agents) en met de headings in `docs/architectuur/index.md`.
export function docsArchitectureUrl(stageId?: string): string {
  const base = `${DOCS_URL}architectuur/`;
  return stageId ? `${base}#${stageId}` : base;
}
