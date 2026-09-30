/* =====================================================================
 * HV Tour — the shared guide-tour engine of all Home Vacation systems
 * (HR, Maintenance, CRM, HV Ops, HV Finance). Served from
 * https://hv-shared.pages.dev/hv-tour.js — one file, every system loads it,
 * so a fix here reaches all of them without redeploying the apps.
 *
 * Self-updating content:
 *   - written steps live in each app (next to its screens) and are passed to init()
 *   - every menu item marked data-tour-nav="<pageKey>" that has NO written step gets an
 *     automatic step ("Other pages"), so a new page is in the tour the day it ships
 *   - steps whose page is not in the person's menu (no access) are skipped
 *   - a step whose target element is missing still shows, just without the highlight
 *
 * App contract:
 *   HVTour.init({
 *     app, color,                      // storage namespace, brand colour
 *     userId(), lang(),                // current user id (null = logged out), 'ar' | 'en'
 *     getPage(), goPage(key),          // current page key, navigate to a page
 *     chapters: [[key, en, ar]], steps: [{ c, page, target, action, en: [title, body], ar: [title, body] }],
 *     bottomOffset: { mobile, desktop } (px), hidden(): true while the button should not show (login, print …)
 *   })
 *   targets = elements with data-tour="<name>"; menu items = data-tour-nav="<pageKey>"
 *   actions = window event 'hv-tour' { detail: { action } } — the app opens a form / tab; 'close' closes it
 * ===================================================================== */
(function () {
  if (window.HVTour && window.HVTour.__v >= 2) return;
  const VERSION = 3;
  const T = {
    en: { tour: 'Tour', page: 'Explain this page', full: 'Full tour', manual: 'Guide (all chapters)', next: 'Next', back: 'Back', skip: 'Skip', finish: 'Finish', step: 'Step', of: 'of', show: 'Show me', close: 'Close', welcome: 'Welcome', welcomeBody: 'A short guided tour shows you every screen of this system. You can restart it any time from the “Tour” button.', start: 'Start the tour', later: 'Later', other: 'Other pages', otherBody: (l) => `This is “${l}”. Open it from the menu; everything on this page follows the same rules as the rest of the system.` },
    ar: { tour: 'جولة', page: 'اشرح هذه الصفحة', full: 'الجولة الكاملة', manual: 'الدليل (كل الفصول)', next: 'التالي', back: 'السابق', skip: 'تخطّي', finish: 'إنهاء', step: 'خطوة', of: 'من', show: 'أرني', close: 'إغلاق', welcome: 'مرحباً بك', welcomeBody: 'جولة قصيرة تعرّفك على كل شاشة في هذا النظام. يمكنك إعادتها في أي وقت من زر «جولة».', start: 'ابدأ الجولة', later: 'لاحقاً', other: 'صفحات أخرى', otherBody: (l) => `هذه صفحة «${l}». افتحها من القائمة؛ كل ما فيها يتبع نفس قواعد باقي النظام.` },
  };
  let cfg = null, steps = [], idx = -1, root = null, btn = null, pop = null, lastUser = null, timer = null, target = null;
  const $ = (sel) => { try { return document.querySelector(sel); } catch (e) { return null; } };
  const L = () => (cfg && cfg.lang && cfg.lang() === 'ar') ? 'ar' : 'en';
  const t = () => T[L()];
  const store = { get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }, set(k, v) { try { localStorage.setItem(k, v); } catch (e) {} } };
  const seenKey = () => `hvtour_seen_${cfg.app}_${cfg.userId ? cfg.userId() : ''}`;
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const isMobile = () => window.innerWidth < 768;
  // visible = has a box on screen and is not hidden (works for position:fixed elements too, whose offsetParent is null)
  const visible = (e) => { const r = e.getBoundingClientRect(); if (r.width <= 0 || r.height <= 0) return false; const cs = getComputedStyle(e); return cs.display !== 'none' && cs.visibility !== 'hidden' && Number(cs.opacity) > 0; };

  function css() {
    if (document.getElementById('hvt-css')) return;
    const c = cfg.color || '#0f3d4c';
    const s = document.createElement('style'); s.id = 'hvt-css';
    s.textContent = `
      .hvt-btn{position:fixed;z-index:2147482000;display:flex;align-items:center;gap:6px;border:0;border-radius:999px;background:${c};color:#fff;padding:10px 14px;font:600 14px/1 system-ui,-apple-system,"Segoe UI",Roboto,"Noto Sans Arabic",Arial,sans-serif;box-shadow:0 6px 18px rgba(0,0,0,.25);cursor:pointer}
      .hvt-btn:hover{filter:brightness(1.1)} .hvt-btn svg{width:18px;height:18px}
      .hvt-pop{position:fixed;z-index:2147482001;background:#fff;border-radius:14px;box-shadow:0 10px 30px rgba(0,0,0,.25);padding:6px;min-width:210px;font:14px/1.3 system-ui,-apple-system,"Segoe UI",Roboto,"Noto Sans Arabic",Arial,sans-serif}
      .hvt-pop button{display:block;width:100%;text-align:start;border:0;background:none;padding:10px 12px;border-radius:10px;cursor:pointer;color:#0f172a;font:inherit}
      .hvt-pop button:hover{background:#f1f5f9}
      .hvt-root{position:fixed;inset:0;z-index:2147483000}
      .hvt-block{position:absolute;inset:0}
      .hvt-spot{position:absolute;border:2px solid #fbbf24;border-radius:10px;box-shadow:0 0 0 9999px rgba(15,23,42,.6);pointer-events:none}
      .hvt-dim{position:absolute;inset:0;background:rgba(15,23,42,.6)}
      .hvt-card{position:absolute;background:#fff;border-radius:16px;padding:16px;box-shadow:0 20px 50px rgba(0,0,0,.35);font:14px/1.55 system-ui,-apple-system,"Segoe UI",Roboto,"Noto Sans Arabic",Arial,sans-serif;color:#334155;max-width:420px}
      .hvt-card h3{margin:0 0 6px;font-size:16px;color:#0f172a}
      .hvt-meta{display:flex;justify-content:space-between;font-size:11px;letter-spacing:.03em;text-transform:uppercase;color:${c};margin-bottom:4px}
      .hvt-body{max-height:200px;overflow:auto}
      .hvt-row{display:flex;align-items:center;gap:8px;margin-top:12px}
      .hvt-row .sp{flex:1} .hvt-skip{border:0;background:none;color:#64748b;font:12px system-ui;cursor:pointer;text-decoration:underline}
      .hvt-b{border:1px solid #cbd5e1;background:#fff;color:#334155;border-radius:10px;padding:7px 14px;font:600 13px system-ui,"Noto Sans Arabic";cursor:pointer}
      .hvt-b.p{background:${c};border-color:${c};color:#fff} .hvt-b:disabled{opacity:.4;cursor:default}
      .hvt-bar{height:4px;border-radius:4px;background:#f1f5f9;margin-top:10px;overflow:hidden} .hvt-bar i{display:block;height:100%;background:${c}}
      .hvt-modal{position:absolute;inset:0;background:rgba(15,23,42,.55);display:flex;align-items:center;justify-content:center;padding:16px}
      .hvt-sheet{background:#fff;border-radius:18px;width:100%;max-width:760px;max-height:88vh;overflow:auto;padding:18px;font:14px/1.55 system-ui,-apple-system,"Segoe UI",Roboto,"Noto Sans Arabic",Arial,sans-serif;color:#334155}
      .hvt-sheet h2{margin:0 0 10px;font-size:18px;color:#0f172a}
      .hvt-ch{border:1px solid #e2e8f0;border-radius:12px;margin:8px 0;overflow:hidden}
      .hvt-ch>button{display:flex;justify-content:space-between;width:100%;border:0;background:#f8fafc;padding:10px 12px;font:600 14px system-ui,"Noto Sans Arabic";cursor:pointer;color:#0f172a}
      .hvt-st{display:flex;gap:10px;padding:10px 12px;border-top:1px solid #f1f5f9}
      .hvt-st .n{flex:0 0 22px;height:22px;border-radius:50%;background:#e0f2f1;color:${c};font:700 11px/22px system-ui;text-align:center}
      .hvt-st .x{flex:1} .hvt-st b{display:block;color:#0f172a}
      @media print{.hvt-btn,.hvt-pop,.hvt-root{display:none!important}}`;
    document.head.appendChild(s);
  }

  // written steps (filtered by access) + an automatic step for every menu page that has none
  function buildSteps() {
    const navEls = Array.from(document.querySelectorAll('[data-tour-nav]'));
    const navKeys = new Set(navEls.map((e) => e.getAttribute('data-tour-nav')));
    const hasNav = navEls.length > 0;
    const written = (cfg.steps || []).filter((s) => !s.page || !hasNav || navKeys.has(s.page) || s.always);
    const covered = new Set((cfg.steps || []).map((s) => s.page).filter(Boolean));
    const seen = new Set(); const auto = [];
    for (const el of navEls) {
      const k = el.getAttribute('data-tour-nav'); if (!k || covered.has(k) || seen.has(k)) continue; seen.add(k);
      const label = (el.getAttribute('data-tour-label') || el.textContent || k).replace(/\s+/g, ' ').trim();
      auto.push({ c: '__other', page: k, target: null, navTarget: k, en: [label, T.en.otherBody(label)], ar: [label, T.ar.otherBody(label)], auto: true });
    }
    return written.concat(auto);
  }
  const chapters = () => (cfg.chapters || []).concat([['__other', T.en.other, T.ar.other]]);

  function button() {
    if (btn) return;
    btn = document.createElement('button'); btn.type = 'button'; btn.className = 'hvt-btn';
    btn.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.7.3-1 .9-1 1.7M12 17h.01"/></svg><span></span>';
    btn.onclick = (e) => { e.stopPropagation(); togglePop(); };
    document.body.appendChild(btn);
    document.addEventListener('click', () => closePop());
  }
  function placeButton() {
    if (!btn) return;
    const off = cfg.bottomOffset || {}; const rtl = L() === 'ar';
    btn.style.bottom = (isMobile() ? (off.mobile != null ? off.mobile : 76) : (off.desktop != null ? off.desktop : 24)) + 'px';
    btn.style.left = rtl ? '16px' : 'auto'; btn.style.right = rtl ? 'auto' : '16px';
    btn.querySelector('span').textContent = t().tour; btn.title = t().page;
    const hide = !cfg.userId || !cfg.userId() || (cfg.hidden && cfg.hidden()) || idx >= 0 || document.querySelector('.hvt-modal');
    btn.style.display = hide ? 'none' : 'flex';
  }
  function togglePop() {
    if (pop) return closePop();
    pop = document.createElement('div'); pop.className = 'hvt-pop'; pop.dir = L() === 'ar' ? 'rtl' : 'ltr';
    const r = btn.getBoundingClientRect(); pop.style.bottom = (window.innerHeight - r.top + 8) + 'px';
    if (L() === 'ar') pop.style.left = r.left + 'px'; else pop.style.right = (window.innerWidth - r.right) + 'px';
    [[t().page, () => startForPage()], [t().full, () => start(0)], [t().manual, () => manual()]].forEach(([label, fn]) => { const b = document.createElement('button'); b.textContent = label; b.onclick = (e) => { e.stopPropagation(); closePop(); fn(); }; pop.appendChild(b); });
    pop.onclick = (e) => e.stopPropagation();
    document.body.appendChild(pop);
  }
  function closePop() { if (pop) { pop.remove(); pop = null; } }

  function ensureRoot() { if (!root) { root = document.createElement('div'); root.className = 'hvt-root'; document.body.appendChild(root); } root.dir = L() === 'ar' ? 'rtl' : 'ltr'; return root; }
  function removeRoot() { if (root) { root.remove(); root = null; } }
  const fire = (action) => window.dispatchEvent(new CustomEvent('hv-tour', { detail: { action } }));

  function start(i) {
    steps = buildSteps(); if (!steps.length) return;
    idx = Math.max(0, Math.min(i || 0, steps.length - 1)); store.set(seenKey(), '1'); show();
  }
  function startForPage() {
    steps = buildSteps(); const p = cfg.getPage ? cfg.getPage() : null;
    const i = steps.findIndex((s) => s.page === p); start(i < 0 ? 0 : i);
  }
  function stop() { fire('close'); idx = -1; removeRoot(); placeButton(); }

  function show() {
    const s = steps[idx]; if (!s) return stop();
    const r = ensureRoot(); r.innerHTML = '<div class="hvt-block"></div>';
    const cur = cfg.getPage ? cfg.getPage() : null;
    if (s.page && cur !== s.page && cfg.goPage) { try { cfg.goPage(s.page); } catch (e) {} }
    if (s.action) setTimeout(() => fire(s.action), 150);
    const sel = s.target ? `[data-tour="${s.target}"]` : (s.navTarget ? `[data-tour-nav="${s.navTarget}"]` : null);
    let tries = 0;
    const find = () => {
      if (idx < 0 || steps[idx] !== s) return;
      const els = sel ? Array.from(document.querySelectorAll(sel)) : [];
      const el = els.find(visible);
      if (el) { el.scrollIntoView({ block: 'center', behavior: 'smooth' }); settle(el, () => render(s, el)); }
      else if (sel && tries++ < 14) setTimeout(find, 150);
      else render(s, null);
    };
    setTimeout(find, s.action ? 450 : 150);
    placeButton();
  }

  // wait until a (smooth) scroll has finished: the element's position is the same twice in a row
  function settle(el, done) {
    let last = null; let n = 0;
    const check = () => {
      const b = el.getBoundingClientRect(); const k = Math.round(b.top) + ',' + Math.round(b.left);
      if ((k === last && n >= 2) || n++ > 20) return done(); last = k; setTimeout(check, 90);
    };
    setTimeout(check, 120);
  }

  function render(s, el) {
    if (idx < 0 || steps[idx] !== s) return;
    const r = ensureRoot(); const text = s[L()] || s.en; const ch = chapters().find((c) => c[0] === s.c);
    target = el;
    const rect = el ? el.getBoundingClientRect() : null;
    r.innerHTML = '<div class="hvt-block"></div>' + (rect ? '<div class="hvt-spot"></div>' : '<div class="hvt-dim"></div>');
    const card = document.createElement('div'); card.className = 'hvt-card';
    card.innerHTML = `<div class="hvt-meta"><span>${esc(ch ? (L() === 'ar' ? ch[2] : ch[1]) : '')}</span><span>${t().step} ${idx + 1} ${t().of} ${steps.length}</span></div><h3>${esc(text[0])}</h3><div class="hvt-body">${esc(text[1])}</div>
      <div class="hvt-row"><button class="hvt-skip">${t().skip}</button><span class="sp"></span><button class="hvt-b" ${idx === 0 ? 'disabled' : ''}>${t().back}</button><button class="hvt-b p">${idx + 1 >= steps.length ? t().finish : t().next}</button></div>
      <div class="hvt-bar"><i style="width:${((idx + 1) / steps.length) * 100}%"></i></div>`;
    const [skipB, backB, nextB] = card.querySelectorAll('button');
    skipB.onclick = stop; backB.onclick = () => { if (idx > 0) { fire('close'); idx--; show(); } }; nextB.onclick = next;
    r.appendChild(card); position();
  }

  // (re)place the highlight and the card around the current target — also on scroll/resize, so they follow it
  function position() {
    if (!root || idx < 0) return;
    const card = root.querySelector('.hvt-card'); if (!card) return;
    const el = target && target.isConnected && visible(target) ? target : null;
    const rect = el ? el.getBoundingClientRect() : null;
    const spot = root.querySelector('.hvt-spot');
    if (spot && rect) Object.assign(spot.style, { top: (rect.top - 6) + 'px', left: (rect.left - 6) + 'px', width: (rect.width + 12) + 'px', height: (rect.height + 12) + 'px' });
    card.style.top = card.style.bottom = card.style.left = card.style.right = ''; card.style.margin = ''; card.style.width = '';
    const off = cfg.bottomOffset || {}; const H = window.innerHeight;
    if (!rect || isMobile()) {
      // phones: a sheet at the bottom — or at the top when the bottom one would cover the highlighted element
      card.style.left = '12px'; card.style.right = '12px'; card.style.margin = '0 auto';
      const bottom = isMobile() ? (off.mobile != null ? off.mobile : 76) : 24;
      const ch = card.offsetHeight || 220;
      const overlap = (top, bot) => rect ? Math.max(0, Math.min(bot, rect.bottom + 6) - Math.max(top, rect.top - 6)) : 0;
      const atBottom = overlap(H - bottom - ch, H - bottom); const atTop = overlap(12, 12 + ch);
      if (rect && atBottom > 0 && atTop < atBottom) card.style.top = '12px'; else card.style.bottom = bottom + 'px';
    } else {
      const ch = card.offsetHeight || 220; card.style.width = '380px';
      if (rect.bottom + ch + 24 < H) card.style.top = (rect.bottom + 14) + 'px';
      else if (rect.top - ch - 24 > 0) card.style.bottom = (H - rect.top + 14) + 'px';
      else card.style.bottom = '16px'; // tall element: keep the card on screen
      const x = L() === 'ar' ? Math.max(12, Math.min(window.innerWidth - rect.right, window.innerWidth - 400)) : Math.max(12, Math.min(rect.left, window.innerWidth - 400));
      if (L() === 'ar') card.style.right = x + 'px'; else card.style.left = x + 'px';
    }
  }
  function next() { if (idx + 1 >= steps.length) return stop(); fire('close'); idx++; show(); }

  function manual() {
    steps = buildSteps(); const r = ensureRoot(); const tt = t(); const lang = L();
    const chs = chapters().filter((c) => steps.some((s) => s.c === c[0]));
    r.innerHTML = `<div class="hvt-modal"><div class="hvt-sheet"><div style="display:flex;justify-content:space-between;align-items:center;gap:8px"><h2>${esc(tt.manual)}</h2><span><button class="hvt-b p" data-full>${esc(tt.full)}</button> <button class="hvt-b" data-close>${esc(tt.close)}</button></span></div>
      ${chs.map((c, ci) => `<div class="hvt-ch"><button data-ch="${ci}"><span>${esc(lang === 'ar' ? c[2] : c[1])}</span><span>${steps.filter((s) => s.c === c[0]).length} ▾</span></button><div data-body="${ci}" style="display:${ci === 0 ? 'block' : 'none'}">
        ${steps.map((s, i) => s.c === c[0] ? `<div class="hvt-st"><span class="n">${i + 1}</span><div class="x"><b>${esc((s[lang] || s.en)[0])}</b>${esc((s[lang] || s.en)[1])}</div><button class="hvt-b" data-go="${i}">${esc(tt.show)}</button></div>` : '').join('')}</div></div>`).join('')}</div></div>`;
    r.querySelector('[data-close]').onclick = () => { removeRoot(); placeButton(); };
    r.querySelector('[data-full]').onclick = () => { removeRoot(); start(0); };
    r.querySelectorAll('[data-ch]').forEach((b) => b.onclick = () => { const body = r.querySelector(`[data-body="${b.getAttribute('data-ch')}"]`); body.style.display = body.style.display === 'none' ? 'block' : 'none'; });
    r.querySelectorAll('[data-go]').forEach((b) => b.onclick = () => { removeRoot(); start(Number(b.getAttribute('data-go'))); });
    r.querySelector('.hvt-modal').onclick = (e) => { if (e.target.classList.contains('hvt-modal')) { removeRoot(); placeButton(); } };
    placeButton();
  }

  function welcome() {
    const r = ensureRoot(); const tt = t();
    r.innerHTML = `<div class="hvt-modal"><div class="hvt-sheet" style="max-width:420px;text-align:center"><h2>${esc(tt.welcome)}</h2><p>${esc(tt.welcomeBody)}</p><div style="display:flex;gap:8px;justify-content:center;margin-top:14px"><button class="hvt-b" data-later>${esc(tt.later)}</button><button class="hvt-b p" data-start>${esc(tt.start)}</button></div></div></div>`;
    r.querySelector('[data-later]').onclick = () => { store.set(seenKey(), '1'); removeRoot(); placeButton(); };
    r.querySelector('[data-start]').onclick = () => { removeRoot(); start(0); };
  }

  function tick() {
    if (!cfg) return;
    const u = cfg.userId ? cfg.userId() : null;
    if (u && u !== lastUser) { lastUser = u; if (!store.get(seenKey()) && idx < 0 && !root && !(cfg.hidden && cfg.hidden())) setTimeout(() => { if (!store.get(seenKey()) && !root) welcome(); }, 1500); }
    if (!u) lastUser = null;
    placeButton();
  }

  window.addEventListener('keydown', (e) => { if (idx < 0) return; if (e.key === 'Escape') stop(); if (e.key === (L() === 'ar' ? 'ArrowLeft' : 'ArrowRight')) next(); if (e.key === (L() === 'ar' ? 'ArrowRight' : 'ArrowLeft') && idx > 0) { fire('close'); idx--; show(); } });
  window.addEventListener('resize', () => { if (idx >= 0) position(); placeButton(); });
  let raf = 0; // any scroll (page or inside a modal) moves the highlight with the element
  window.addEventListener('scroll', () => { if (idx < 0 || raf) return; raf = requestAnimationFrame(() => { raf = 0; position(); }); }, true);

  window.HVTour = {
    __v: VERSION,
    init(options) { cfg = options; css(); button(); tick(); if (!timer) timer = setInterval(tick, 1000); },
    start, startForPage, manual, stop,
    update(options) { cfg = Object.assign({}, cfg, options); tick(); },
  };
})();
