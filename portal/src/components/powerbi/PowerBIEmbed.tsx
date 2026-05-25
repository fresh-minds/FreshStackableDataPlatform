/*
  PowerBIEmbed — React Island voor de portal-shell.

  Rendert een Power BI rapport binnen het v2-shell-frame:
    1. POST /api/portal/powerbi/embed/<reportId> — krijgt een embed-token
       gegrond op de gefedereerde Entra-identiteit van de portal-user
       (via oauth2-proxy + Keycloak↔Entra broker, ADR-0008).
    2. Render <PowerBIEmbed config={...}> uit powerbi-client-react.
    3. Handle loading + error states; auto-refresh token bij expiry.

  Geen MSAL.js in de browser — de embed-token komt vanuit de portal-backend,
  de Entra-tokens van de user worden alleen in Keycloak gehouden. Dit is de
  App-Owns-Data-met-effective-identity flow, niet pure User-Owns-Data.
*/
import { useEffect, useRef, useState } from "react";
import { PowerBIEmbed as PowerBIEmbedRC } from "powerbi-client-react";
import { models } from "powerbi-client";
import type { Report } from "powerbi-client";

interface Props {
  /** Power BI report-ID. Default = UC-12 FOCUS FinOps dashboard. */
  reportId?: string;
  /** Optionele page-naam binnen het report. */
  pageName?: string;
}

interface EmbedConfig {
  embedUrl:    string;
  accessToken: string;
  expiration:  string;
  reportId:    string;
  datasetId:   string;
}

// UC-12 FOCUS FinOps dashboard — gedeployed in Phase 1 van het Power BI plan.
const DEFAULT_REPORT_ID = "3f508254-867b-4b58-9c7d-ebafb0947df2";

async function fetchEmbedConfig(reportId: string): Promise<EmbedConfig> {
  const resp = await fetch(`/api/portal/powerbi/embed/${reportId}`, {
    method:      "POST",
    credentials: "include",
    headers:     { "Content-Type": "application/json" },
    body:        JSON.stringify({}),
  });
  if (!resp.ok) {
    const txt = await resp.text();
    throw new Error(`embed-token (${resp.status}): ${txt.slice(0, 240)}`);
  }
  return await resp.json();
}

export default function PowerBIEmbed({
  reportId = DEFAULT_REPORT_ID,
  pageName,
}: Props): JSX.Element {
  const [cfg, setCfg]   = useState<EmbedConfig | null>(null);
  const [err, setErr]   = useState<string | null>(null);
  const reportRef       = useRef<Report | null>(null);

  // Initiële fetch — abort-able, react-strict-mode-safe.
  useEffect(() => {
    let cancelled = false;
    setCfg(null);
    setErr(null);
    fetchEmbedConfig(reportId)
      .then((c) => { if (!cancelled) setCfg(c); })
      .catch((e) => { if (!cancelled) setErr(String(e?.message ?? e)); });
    return () => { cancelled = true; };
  }, [reportId]);

  // Token-refresh — embed-tokens leven max 60min. We refreshen 5min vóór
  // expiry zodat lange sessies geen onderbreking krijgen.
  useEffect(() => {
    if (!cfg?.expiration) return;
    const expiresAt = new Date(cfg.expiration).getTime();
    const refreshIn = Math.max(60_000, expiresAt - Date.now() - 5 * 60_000);
    const t = window.setTimeout(async () => {
      try {
        const next = await fetchEmbedConfig(reportId);
        setCfg(next);
        // Geef de nieuwe token aan de embed zonder remount.
        await reportRef.current?.setAccessToken(next.accessToken);
      } catch (e) {
        console.warn("powerbi: token-refresh faalde", e);
      }
    }, refreshIn);
    return () => window.clearTimeout(t);
  }, [cfg?.expiration, reportId]);

  if (err) {
    return (
      <div className="pbi-fallback">
        <h2>Power BI laden faalde</h2>
        <p className="pbi-fallback-detail mono">{err}</p>
        <p>
          Controleer dat je bent ingelogd via Entra (Keycloak-broker), en dat
          de portal-backend de FABRIC_* env-vars heeft. Zie{" "}
          <code>docs/use-cases/powerbi-embed-aks-entra.md</code>.
        </p>
        <a
          className="pbi-fallback-link"
          href={`https://app.fabric.microsoft.com/groups/me/reports/${reportId}`}
          target="_blank"
          rel="noopener noreferrer"
        >
          Open direct op app.fabric.microsoft.com ↗
        </a>
      </div>
    );
  }

  if (!cfg) {
    return (
      <div className="pbi-loading" aria-live="polite">
        <span className="pbi-spinner" aria-hidden="true" />
        <span>Power BI rapport laden…</span>
      </div>
    );
  }

  return (
    <div className="pbi-wrap">
      <PowerBIEmbedRC
        embedConfig={{
          type:        "report",
          id:          cfg.reportId,
          embedUrl:    cfg.embedUrl,
          accessToken: cfg.accessToken,
          tokenType:   models.TokenType.Embed,
          pageName,
          settings: {
            panes: {
              filters:     { visible: false, expanded: false },
              pageNavigation: { visible: true, position: models.PageNavigationPosition.Bottom },
            },
            background: models.BackgroundType.Transparent,
            layoutType: models.LayoutType.Custom,
            customLayout: { displayOption: models.DisplayOption.FitToPage },
          },
        }}
        eventHandlers={
          new Map<string, (evt?: unknown) => void>([
            ["loaded",   () => console.info("powerbi: report loaded")],
            ["rendered", () => console.info("powerbi: report rendered")],
            ["error",    (evt) => {
              console.error("powerbi: error", evt);
              setErr(`Power BI runtime error — zie console.`);
            }],
          ])
        }
        getEmbeddedComponent={(embed) => {
          reportRef.current = embed as Report;
        }}
        cssClassName="pbi-frame"
      />
      <style>{`
        .pbi-wrap, .pbi-frame, .pbi-frame > iframe { width: 100%; height: 100%; border: 0; }
        .pbi-wrap { display: flex; flex: 1; min-height: 0; background: var(--bg-sunken, #0c0c0c); }
        .pbi-loading {
          flex: 1; display: flex; align-items: center; justify-content: center;
          gap: 12px; color: var(--ink-3, #888); font-size: var(--text-meta, 13px);
        }
        .pbi-spinner {
          width: 14px; height: 14px; border: 2px solid var(--ink-4, #444);
          border-top-color: var(--accent, #c4451c); border-radius: 50%;
          animation: pbi-spin 0.8s linear infinite;
        }
        @keyframes pbi-spin { to { transform: rotate(360deg); } }
        .pbi-fallback {
          margin: auto; max-width: 520px;
          background: var(--bg-elev, #161616); border: 1px solid var(--line, #2a2a2a);
          border-radius: 8px; padding: 24px; display: grid; gap: 12px;
          color: var(--ink-1, #ededed); font-size: var(--text-meta, 13px);
        }
        .pbi-fallback h2 { margin: 0; font-size: 16px; }
        .pbi-fallback-detail {
          font-family: var(--font-mono, ui-monospace, SFMono-Regular, monospace);
          color: var(--ink-3, #888); font-size: 12px;
          background: var(--bg-sunken, #0a0a0a); padding: 8px 10px; border-radius: 4px;
          white-space: pre-wrap; word-break: break-word;
        }
        .pbi-fallback-link {
          display: inline-block; margin-top: 6px;
          color: var(--accent, #c4451c); text-decoration: none; font-weight: 500;
        }
        .pbi-fallback-link:hover { text-decoration: underline; }
      `}</style>
    </div>
  );
}
