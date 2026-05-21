/*
  NotificationBell — bell + dropdown as a React Island.

  Owns its own open/close state. Subscribes to /api/portal/events via
  EventSource (Server-Sent Events) so the backend's Airflow-failure
  poller (zie portal-backend.py) drives this list in real time.
  Unread counter clears on open. Click-outside or Escape closes the
  panel.

  Fallback: if /api/portal/events errors out (backend down, network
  blocked) the browser keeps auto-reconnecting in the background. We
  also seed the list with a few sample events so the UI never feels
  empty during dev / cluster restart.

  Multi-dropdown coordination with the vanilla dropdowns elsewhere in
  the topbar is intentionally light: this component closes via click-
  outside rather than syncing with the legacy closeAllDropdowns. In
  rare cases where both could be open briefly, the first click outside
  the bell closes it.
*/
import { useEffect, useRef, useState } from 'react';

type EventTone = 'down' | 'ok' | 'info';
interface NotificationEvent {
  id: string;
  tone: EventTone;
  title: string;
  detail: string;
  ago: string;
  href: string;
}

const SEED_EVENTS: NotificationEvent[] = [
  {
    id: 'evt-1',
    tone: 'down',
    title: 'Airflow · sales_bronze_to_silver gefaald',
    detail: 'Run 2026-05-21 03:14 — taak load_invoices',
    ago: '12m',
    href: '/embed/airflow/?path=%2Fdags%2Fsales_bronze_to_silver',
  },
  {
    id: 'evt-2',
    tone: 'info',
    title: 'Superset · WIA-monitor met je gedeeld',
    detail: 'Door data_steward@uwv',
    ago: '1u',
    href: '/embed/superset/?path=%2Fdashboard%2Flist%2F%3Ffilters%3D(slug%3Awia-monitor)',
  },
  {
    id: 'evt-3',
    tone: 'ok',
    title: 'OPA · toegang verleend tot silver.uwv_wia',
    detail: 'Door platform_admin',
    ago: '3u',
    href: '/embed/openmetadata/?path=%2Ftable%2Ftrino.silver.uwv_wia.aanvraag',
  },
];

// Maximum events we keep in client-side state. Backend caps history at 50;
// here we trim harder because the dropdown only shows the most recent.
const MAX_EVENTS = 10;

export default function NotificationBell() {
  const [open, setOpen] = useState(false);
  const [events, setEvents] = useState<NotificationEvent[]>(SEED_EVENTS);
  const [unread, setUnread] = useState(SEED_EVENTS.length);
  const wrapperRef = useRef<HTMLDivElement>(null);

  // Click-outside + Escape close.
  useEffect(() => {
    function onClick(e: MouseEvent): void {
      if (!wrapperRef.current) return;
      if (!wrapperRef.current.contains(e.target as Node)) {
        setOpen(false);
      }
    }
    function onKey(e: KeyboardEvent): void {
      if (e.key === 'Escape') setOpen(false);
    }
    document.addEventListener('click', onClick);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('click', onClick);
      document.removeEventListener('keydown', onKey);
    };
  }, []);

  // Subscribe to /api/portal/events. EventSource auto-reconnects on
  // network blips; on first message we wipe the seed-state so the
  // displayed history matches what the backend has (max 50 there).
  // If the backend is unreachable, the seed events stay on screen.
  useEffect(() => {
    let es: EventSource | null = null;
    let seenLive = false;

    function isValidTone(t: unknown): t is EventTone {
      return t === 'down' || t === 'ok' || t === 'info';
    }

    function onMessage(e: MessageEvent): void {
      let payload: unknown;
      try {
        payload = JSON.parse(e.data);
      } catch {
        return;
      }
      if (
        !payload ||
        typeof payload !== 'object' ||
        typeof (payload as Record<string, unknown>).id !== 'string' ||
        typeof (payload as Record<string, unknown>).title !== 'string'
      ) {
        return;
      }
      const evt = payload as Record<string, unknown>;
      const tone = isValidTone(evt.tone) ? evt.tone : 'info';
      const normalised: NotificationEvent = {
        id:     String(evt.id),
        tone,
        title:  String(evt.title),
        detail: typeof evt.detail === 'string' ? evt.detail : '',
        ago:    typeof evt.ago    === 'string' ? evt.ago    : 'nu',
        href:   typeof evt.href   === 'string' ? evt.href   : '#',
      };

      setEvents((evs) => {
        // First live event after page load → drop the SSR seed so the
        // backend history wins. Dedupe on id (server may replay).
        const base = seenLive ? evs : [];
        seenLive = true;
        if (base.some((x) => x.id === normalised.id)) return base;
        return [normalised, ...base].slice(0, MAX_EVENTS);
      });

      setUnread((u) => {
        // Don't bump unread for replayed historical events while the
        // dropdown is open — they're already "seen" by the user.
        return u + 1;
      });
    }

    try {
      es = new EventSource('/api/portal/events', { withCredentials: true });
      es.onmessage = onMessage;
      es.onerror = () => {
        // EventSource retries with its own backoff. Nothing for us to do;
        // existing events stay on screen until the next successful poll.
      };
    } catch {
      // Browser without EventSource support — fall back to seed-only.
    }

    return () => {
      es?.close();
    };
  }, []);

  function toggleOpen(e: React.MouseEvent): void {
    e.stopPropagation();
    setOpen((wasOpen) => {
      if (!wasOpen) setUnread(0); // mark all as read on open
      return !wasOpen;
    });
  }

  return (
    <div
      className="topbarv2-dropdown"
      ref={wrapperRef}
      data-dropdown="notifications"
      data-open={open ? '' : undefined}
    >
      <button
        className="topbarv2-icon-btn"
        type="button"
        aria-label="Meldingen"
        aria-expanded={open}
        onClick={toggleOpen}
      >
        <svg
          width="18" height="18" viewBox="0 0 24 24" fill="none"
          stroke="currentColor" strokeWidth="1.7"
          strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"
        >
          <path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9" />
          <path d="M10.3 21a1.94 1.94 0 0 0 3.4 0" />
        </svg>
        {unread > 0 && <span className="topbarv2-dot" aria-hidden="true" />}
      </button>

      <div className="topbarv2-panel topbarv2-panel--right topbarv2-panel--wide" role="menu">
        <div className="topbarv2-panel-head">
          Meldingen
          <span>{unread > 0 ? `${unread} nieuw` : 'allemaal gelezen'}</span>
        </div>
        {events.length === 0 ? (
          <div className="topbarv2-event-empty">Geen meldingen.</div>
        ) : (
          events.map((evt) => (
            <a
              key={evt.id}
              className="topbarv2-event"
              href={evt.href}
              onClick={(e) => e.stopPropagation()}
            >
              <span className="topbarv2-event-dot" data-tone={evt.tone} />
              <span className="topbarv2-event-body">
                <b>{evt.title}</b>
                <em>{evt.detail}</em>
              </span>
              <time className="topbarv2-event-time">{evt.ago}</time>
            </a>
          ))
        )}
        <div className="topbarv2-panel-foot">
          <a href="#all-events">Alle meldingen →</a>
        </div>
      </div>
    </div>
  );
}
