/* =====================================================================
 * HV saved copy (service worker) — source: hv-shared/kit/sw.js, the SAME
 * file in every Home Vacation system. Registered by hv-core.js.
 *
 * Keeps a copy of this system in the browser, so it still opens when its
 * web address cannot be reached (network trouble, blocked addresses, an
 * outage at the host or at a code website):
 *   the page (index.html)  fresh from the network when it answers within
 *                          4 s; otherwise the last copy that worked
 *   hv-core.js, vendor/*   from the copy (file names carry their version),
 *                          refreshed in the background
 * It touches NOTHING else: no data (Supabase), no other website, no other
 * system, only GET requests inside this system's own folder.
 *
 * Off-switch: open the system with ?nosw=1 (the page removes this worker
 * and its copies), or "Clear the saved copy" on the help panel.
 * ===================================================================== */
const VERSION = 'hv-sw-v1';
const SCOPE = self.registration.scope;            // https://home-vacation-hr.pages.dev/  ·  https://danielessam03.github.io/home-vacation-hr/
const CACHE = VERSION + '|' + SCOPE;               // one copy per system, even when systems share a website (github.io)
const PAGE_TIMEOUT_MS = 4000;
const SELF_PATH = new URL('sw.js', SCOPE).pathname;

const isHtml = (res) => (res.headers.get('content-type') || '').indexOf('text/html') >= 0;
const usable = (res) => !!res && (res.ok || res.type === 'opaqueredirect');

// everything index.html loads from this folder: hv-core.js, vendor/…
function localFiles(html) {
  const out = new Set();
  const re = /(?:src|href)\s*=\s*["']([^"'#?]+\.js)["']/g; let m;
  while ((m = re.exec(html))) { if (!/^(https?:)?\/\//.test(m[1]) && !/^data:/.test(m[1])) out.add(new URL(m[1], SCOPE).href); }
  return [...out];
}

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    try {
      const cache = await caches.open(CACHE);
      const res = await fetch(SCOPE, { cache: 'no-store' });
      if (res.ok && isHtml(res)) {
        const html = await res.clone().text();
        await cache.put(SCOPE, res);
        await Promise.all(localFiles(html).map((u) => cache.add(new Request(u, { cache: 'no-store' })).catch(() => null)));
      }
    } catch (e) { /* offline while installing: the copy is made on the next visit */ }
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();   // drop older versions of THIS system's copy only
    await Promise.all(keys.filter((k) => k.indexOf('hv-sw-') === 0 && k !== CACHE && k.slice(k.indexOf('|') + 1) === SCOPE).map((k) => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.href.indexOf(SCOPE) !== 0) return;                  // other websites, other systems, the database: not ours
  if (url.searchParams.has('nosw')) return;                    // off-switch
  if (req.mode === 'navigate') return pageRequest(event);
  if (/\.js$/.test(url.pathname) && !url.search && url.pathname !== SELF_PATH) return fileRequest(event);
});

// the page: network first (4 s), else the saved copy; the copy is refreshed whenever the network answers
function pageRequest(event) {
  let saving = null;
  const network = fetch(event.request).then((res) => {
    if (res.ok && isHtml(res)) { const copy = res.clone(); saving = caches.open(CACHE).then((c) => c.put(SCOPE, copy)).catch(() => null); }
    return res;
  });
  event.waitUntil(network.then(() => saving, () => null));
  event.respondWith((async () => {
    const saved = await caches.match(SCOPE, { cacheName: CACHE });
    if (!saved) return network;                                  // first visit: the network, as without this worker
    const timeout = new Promise((resolve) => setTimeout(() => resolve(null), PAGE_TIMEOUT_MS));
    try {
      const res = await Promise.race([network, timeout]);
      return usable(res) ? res : saved;                          // slow, unreachable or broken (5xx/404) → the saved copy
    } catch (e) { return saved; }
  })());
}

// hv-core.js and vendor/*: the saved copy at once, refreshed in the background
function fileRequest(event) {
  const req = event.request;
  let saving = null;
  const network = fetch(req).then((res) => {
    if (res.ok) { const copy = res.clone(); saving = caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => null); }
    return res;
  });
  event.waitUntil(network.then(() => saving, () => null));
  event.respondWith((async () => {
    const saved = await caches.match(req, { cacheName: CACHE });
    if (saved) return saved;
    return network;
  })());
}
