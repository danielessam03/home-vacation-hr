/* =====================================================================
 * HV Core — keeps every Home Vacation system reachable.
 * Source: hv-shared/kit/hv-core.js — the SAME file ships inside every system
 * (HR, Maintenance, CRM, HV Ops, HV Finance); kit/sync.sh copies it there.
 * Load it FIRST in <head>, same folder as index.html:
 *     <script src="hv-core.js" data-app="hr"></script>
 *
 *  1. SAVED COPY — registers sw.js, which keeps a copy of the system in the
 *     browser. If the system's address cannot be reached (the office network
 *     could not reach some Cloudflare addresses on 2026-09-30), the system
 *     still opens from that copy; the data still comes live from Supabase.
 *  2. EVERY ADDRESS — each system has several addresses (company domain,
 *     pages.dev, GitHub Pages). Any link to another system is intercepted:
 *     all its addresses are tried at once and the first one that answers,
 *     in the order below, is opened. No change is needed in the links.
 *  3. NEVER A BLANK PAGE — if the system has not started after 12 s (or a
 *     code file failed), a help panel offers Try again / another address /
 *     clear the saved copy, instead of an empty white screen.
 *
 * Off-switch for the saved copy: open the system with ?nosw=1
 * ===================================================================== */
(function () {
  'use strict';
  if (window.HVCore) return;

  // Order = preference. The company address first (same network path as home-vacation.com).
  var SYSTEMS = {
    hr:    { en: 'HR & Payroll', ar: 'الموارد البشرية والرواتب', urls: ['https://hr.home-vacation.com/', 'https://home-vacation-hr.pages.dev/', 'https://danielessam03.github.io/home-vacation-hr/', 'https://hr-home-vacation.pages.dev/'] },
    maint: { en: 'Maintenance', ar: 'إدارة الصيانة', urls: ['https://maintenance.home-vacation.com/', 'https://hv-maintenance-system.pages.dev/', 'https://danielessam03.github.io/hv-maintenance-system/'] },
    crm:   { en: 'Property management (CRM)', ar: 'إدارة العقارات (CRM)', urls: ['https://crm.home-vacation.com/', 'https://property-management-crm.pages.dev/'] },
    ops:   { en: 'HV Ops', ar: 'HV Ops', urls: ['https://ops.home-vacation.com/', 'https://home-vacation-ops.pages.dev/', 'https://danielessam03.github.io/home-vacation-ops/', 'https://hvops-home-vacation.pages.dev/'] },
    fin:   { en: 'HV Finance', ar: 'الحسابات والمالية', urls: ['https://finance.home-vacation.com/', 'https://home-vacation-finance.pages.dev/'] }
  };
  var PROBE_MS = 3500, START_MS = 12000;
  var me = document.currentScript;
  var APP = (me && me.getAttribute('data-app')) || null;
  var ar = function () { return (document.documentElement.lang || '').indexOf('ar') === 0 || document.documentElement.dir === 'rtl'; };
  var failed = [];   // code files that could not load

  // ---------------------------------------------------------------- which system / address is a link?
  function norm(u) { return u.replace(/\/+$/, ''); }
  function match(href) {
    var u; try { u = new URL(href, location.href); } catch (e) { return null; }
    var full = u.origin + u.pathname;
    for (var k in SYSTEMS) {
      for (var i = 0; i < SYSTEMS[k].urls.length; i++) {
        var base = norm(SYSTEMS[k].urls[i]);
        if (full === base || full.indexOf(base + '/') === 0) {
          var rest = full.slice(base.length).replace(/^\//, '');
          if (rest === 'index.html') rest = '';
          return { key: k, rest: rest + u.search + u.hash };
        }
      }
    }
    return null;
  }

  // ---------------------------------------------------------------- is an address answering?
  function probe(base) {
    return new Promise(function (resolve) {
      var done = false; var finish = function (v) { if (!done) { done = true; resolve(v); } };
      setTimeout(function () { finish(false); }, PROBE_MS);
      try {
        // the answer must come from a Home Vacation system: hv-ping.txt (shipped by the kit, readable from any site)
        // says "hv-ping-ok". Anything else — no answer, a timeout, an internet provider's "not found" page for a
        // name that does not exist, a login page of a hotel Wi-Fi — does not count.
        fetch(base + 'hv-ping.txt?t=' + Date.now(), { mode: 'cors', cache: 'no-store', credentials: 'omit' })
          .then(function (res) { return res.ok ? res.text() : ''; })
          .then(function (txt) { finish(String(txt).trim() === 'hv-ping-ok'); }, function () { finish(false); });
      } catch (e) { finish(false); }
    });
  }
  var memo = {};
  function best(key) {
    var s = SYSTEMS[key]; if (!s) return Promise.resolve(null);
    var hit = memo[key]; if (hit && Date.now() - hit.at < 120000) return Promise.resolve(hit.url);
    var checks = s.urls.map(probe);   // all at once
    var i = 0;
    return new Promise(function (resolve) {
      (function next() {
        if (i >= s.urls.length) { resolve(s.urls[0]); return; }   // none answered: try the main one anyway
        var n = i++;
        checks[n].then(function (ok) { if (ok) { memo[key] = { url: s.urls[n], at: Date.now() }; resolve(s.urls[n]); } else next(); });
      })();
    });
  }
  // open a system: the new tab opens immediately (popup blockers), then goes to the first address that answers
  function open(key, rest, sameTab) {
    var w = sameTab ? null : window.open('', '_blank');
    if (w) { try { w.opener = null; w.document.write('<meta charset="utf-8"><body style="font:16px system-ui;padding:32px;color:#334155">' + (ar() ? 'جارٍ الفتح…' : 'Opening…') + '</body>'); } catch (e) {} }
    return best(key).then(function (base) {
      var target = base + (rest || '');
      if (w) { try { w.location.replace(target); } catch (e) { w.location = target; } } else location.href = target;
      return target;
    });
  }

  // every link to a Home Vacation system goes through open() — the apps' links need no change
  document.addEventListener('click', function (e) {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    var a = e.target && e.target.closest ? e.target.closest('a[href]') : null; if (!a || a.hasAttribute('download')) return;
    var m = match(a.href); if (!m) return;
    e.preventDefault();
    open(m.key, m.rest, a.getAttribute('target') !== '_blank');
  }, false);

  // ---------------------------------------------------------------- saved copy (service worker)
  var OFF = /[?&]nosw(=|&|$)/.test(location.search);
  function clearSaved() {
    var jobs = [];
    if ('serviceWorker' in navigator) jobs.push(navigator.serviceWorker.getRegistrations().then(function (rs) { return Promise.all(rs.map(function (r) { return r.scope.indexOf(location.origin + location.pathname.replace(/[^/]*$/, '')) === 0 ? r.unregister() : null; })); }));
    if (window.caches) jobs.push(caches.keys().then(function (ks) { return Promise.all(ks.filter(function (k) { return k.indexOf('hv-sw-') === 0; }).map(function (k) { return caches.delete(k); })); }));
    return Promise.all(jobs).catch(function () {});
  }
  if (OFF) {
    clearSaved().then(function () { try { history.replaceState(null, '', location.pathname + location.hash); } catch (e) {} });
  } else if ('serviceWorker' in navigator && (location.protocol === 'https:' || location.hostname === 'localhost')) {
    window.addEventListener('load', function () { navigator.serviceWorker.register('sw.js').catch(function () {}); });
  }

  // ---------------------------------------------------------------- never a blank page
  window.addEventListener('error', function (e) {
    var t = e.target;
    if (t && t !== window && t.tagName === 'SCRIPT' && t.src) { failed.push(t.src.replace(/^https?:\/\/[^/]+\//, '').split('?')[0]); setTimeout(check, 4000); }
  }, true);
  function started() {
    var r = document.getElementById('root'); if (!r) return true;   // an app without #root: nothing to watch
    if (r.querySelector('#boot')) return false;
    return r.childElementCount > 0 && ((r.innerText || '').trim().length > 0 || !!r.querySelector('input,button,img,svg'));
  }
  var panel = null;
  function check() {
    if (started()) { if (panel) { panel.remove(); panel = null; } return; }
    if (!panel) show();
  }
  function show() {
    var A = ar(), me_ = APP && SYSTEMS[APP], here = location.origin + location.pathname.replace(/[^/]*$/, '');
    var others = me_ ? me_.urls.filter(function (u) { return norm(u) !== norm(here); }) : [];
    var missing = []; if (!window.React) missing.push('React'); if (!window.ReactDOM) missing.push('ReactDOM'); if (!window.Babel) missing.push('Babel'); if (!window.supabase) missing.push('Supabase');
    panel = document.createElement('div');
    panel.setAttribute('dir', A ? 'rtl' : 'ltr');
    panel.style.cssText = 'position:fixed;inset:0;z-index:2147483000;display:flex;align-items:center;justify-content:center;padding:16px;background:rgba(241,245,249,.97);font:15px/1.6 system-ui,-apple-system,"Segoe UI",Tahoma,Arial,sans-serif;color:#0f172a';
    var btn = 'display:block;width:100%;margin-top:10px;padding:12px;border-radius:12px;border:1px solid #cbd5e1;background:#fff;color:#0f172a;font:600 15px system-ui,Tahoma,Arial,sans-serif;cursor:pointer;text-decoration:none;text-align:center';
    panel.innerHTML = '<div style="max-width:440px;width:100%;background:#fff;border-radius:18px;padding:22px;box-shadow:0 20px 50px rgba(15,23,42,.18)">'
      + '<div style="font-size:18px;font-weight:700">' + (A ? 'النظام لم يفتح بعد' : 'The system has not opened yet') + '</div>'
      + '<p style="margin:8px 0 0;color:#475569">' + (A ? 'قد يكون الإنترنت بطيئاً، أو هذا العنوان لا يعمل على شبكتك الآن.' : 'The connection may be slow, or this address may not be working on your network right now.') + '</p>'
      + '<p style="margin:6px 0 0;color:#94a3b8;font-size:13px">' + (A ? 'تُغلق هذه الرسالة وحدها إذا اكتمل الفتح.' : 'This message closes by itself when the system finishes opening.') + '</p>'
      + '<button data-hv="retry" style="' + btn + ';background:#0f3d4c;color:#fff;border-color:#0f3d4c">' + (A ? 'إعادة المحاولة' : 'Try again') + '</button>'
      + (others.length ? '<button data-hv="other" style="' + btn + '">' + (A ? 'افتح من عنوان آخر' : 'Open from another address') + '</button>' : '')
      + '<button data-hv="clear" style="' + btn + ';border:0;background:none;color:#64748b;font-weight:500;font-size:13px">' + (A ? 'مسح النسخة المحفوظة ثم إعادة التحميل' : 'Clear the saved copy and reload') + '</button>'
      + ((missing.length || failed.length) ? '<p style="margin:10px 0 0;font-size:12px;color:#94a3b8" dir="ltr">' + (missing.length ? 'missing: ' + missing.join(', ') + ' ' : '') + (failed.length ? 'failed: ' + failed.slice(0, 4).join(', ') : '') + '</p>' : '')
      + '</div>';
    panel.addEventListener('click', function (e) {
      var b = e.target.closest ? e.target.closest('[data-hv]') : null; if (!b) return;
      var k = b.getAttribute('data-hv');
      if (k === 'retry') location.reload();
      if (k === 'clear') clearSaved().then(function () { location.reload(); });
      if (k === 'other' && others.length) {
        b.textContent = A ? 'جارٍ البحث عن عنوان يعمل…' : 'Looking for an address that works…';
        Promise.all(others.map(probe)).then(function (oks) { var i = oks.indexOf(true); location.href = (i >= 0 ? others[i] : others[0]) + location.hash; });
      }
    });
    (document.body || document.documentElement).appendChild(panel);
  }
  setTimeout(function () { check(); setInterval(check, 2000); }, START_MS);

  // ---------------------------------------------------------------- on-demand code files: this address first, the public CDN as fallback
  function loadScript(local, cdn) {
    return new Promise(function (resolve, reject) {
      var add = function (src, onFail) { var s = document.createElement('script'); s.src = src; s.onload = function () { resolve(); }; s.onerror = function () { s.remove(); onFail(); }; document.head.appendChild(s); };
      add(local, function () { if (cdn) add(cdn, function () { reject(new Error('could not load ' + cdn)); }); else reject(new Error('could not load ' + local)); });
    });
  }

  window.HVCore = { version: 1, app: APP, systems: SYSTEMS, match: match, probe: probe, best: best, open: open, clearSaved: clearSaved, loadScript: loadScript };
})();
