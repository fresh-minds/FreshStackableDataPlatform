// Live Prometheus status dots.
//
// Queries every [data-status-job] on the page, fetches
// /api/status/up?job=<job> via the nginx proxy, and toggles
// .ok / .warn / .bad classes on the dot. Used by home,
// architecture, and me — extracted to dry up triplicated
// implementations.

const REFRESH_MS = 30_000;

interface UpResponse {
  status?: 'success' | 'unavailable' | string;
  data?: { result?: Array<{ value?: [number, string] }> };
  // The nginx proxy returns either Prometheus's own response
  // (with `data.result`) or a small {status:"unavailable"} fallback.
  up?: number;
}

async function checkOne(el: HTMLElement): Promise<void> {
  const job = el.dataset.statusJob!;
  try {
    const r = await fetch(`/api/status/up?job=${encodeURIComponent(job)}`, {
      credentials: 'include',
    });
    if (!r.ok) {
      el.classList.add('warn');
      return;
    }
    const j = (await r.json()) as UpResponse;

    // Older inline scripts assumed nginx already mapped the response to
    // {up: 0|1}. The current nginx config forwards Prometheus's raw
    // response, so prefer the prometheus result shape; fall back to the
    // legacy {up} field for compatibility.
    let up: number | undefined = j.up;
    if (up === undefined && j.data?.result?.length) {
      const v = j.data.result[0]?.value?.[1];
      if (typeof v === 'string') up = Number(v);
    }

    el.classList.remove('ok', 'warn', 'bad');
    if (up === 1) {
      el.classList.add('ok');
      el.title = `up{job="${job}"} = 1`;
    } else if (up === 0) {
      el.classList.add('bad');
      el.title = `up{job="${job}"} = 0`;
    } else {
      el.classList.add('warn');
      el.title = `Geen data voor up{job="${job}"}`;
    }
  } catch {
    el.classList.add('warn');
  }
}

export async function refreshStatus(root: ParentNode = document): Promise<void> {
  const els = root.querySelectorAll<HTMLElement>('[data-status-job]');
  await Promise.all(Array.from(els).map(checkOne));
}

let interval: ReturnType<typeof setInterval> | null = null;

export function startStatusRefresh(): void {
  refreshStatus();
  if (interval) clearInterval(interval);
  interval = setInterval(() => { void refreshStatus(); }, REFRESH_MS);
}
