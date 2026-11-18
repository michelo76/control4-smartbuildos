
/* ══════════════════════════ shell ══════════════════════════ */
try { if ('scrollRestoration' in history) history.scrollRestoration = 'manual'; } catch (e) { /* ignore */ }
const CHAPTERS = $$('.chapter');
let currentChapter = null;
const progressState = store.get('progress', {});
function setDot(id, state) {
  const prev = progressState[id];
  if (prev === 'done' || prev === state) return;
  progressState[id] = state;
  store.set('progress', progressState);
  paintDots();
}
function paintDots() {
  $$('#chapterList a.chap').forEach((a) => {
    const st = progressState[a.dataset.ch];
    const dot = a.querySelector('.dot');
    if (st) dot.dataset.state = st; else delete dot.dataset.state;
    const word = st === 'done' ? 'read to the end' : st === 'visited' ? 'opened' : 'not opened';
    let sr = a.querySelector('.sr-state');
    if (!sr) { sr = document.createElement('span'); sr.className = 'sr-only sr-state'; a.appendChild(sr); }
    sr.textContent = ' (' + word + ')';
  });
}
function buildChapterNav() {
  CHAPTERS.forEach((ch, i) => {
    const nav = document.createElement('nav');
    nav.className = 'chapter-nav';
    nav.setAttribute('aria-label', 'Chapter pages');
    const prev = CHAPTERS[i - 1], next = CHAPTERS[i + 1];
    nav.innerHTML = (prev ? '<a href="#' + prev.id + '" rel="prev"><small>Previous</small>' + esc(prev.dataset.title) + '</a>' : '<span></span>') +
      (next ? '<a href="#' + next.id + '" rel="next" style="text-align:right"><small>Next</small>' + esc(next.dataset.title) + '</a>' : '<span></span>');
    ch.appendChild(nav);
  });
}
function buildSubnav(ch) {
  $$('#chapterList .subnav').forEach((n) => n.remove());
  const link = $('#chapterList a[data-ch="' + ch.id + '"]');
  const heads = $$(':scope > h2[id], :scope > div > h2[id]', ch).filter((h) => h.id);
  if (!link || !heads.length) return;
  const sub = document.createElement('div');
  sub.className = 'subnav';
  sub.innerHTML = heads.map((h) => '<a href="#' + h.id + '">' + esc(h.textContent) + '</a>').join('');
  link.parentElement.appendChild(sub);
}
function route(opts) {
  opts = opts || {};
  let hash = decodeURIComponent(location.hash.replace(/^#/, ''));
  if (!hash) hash = store.get('lastChapter', 'ch1');
  let target = hash ? document.getElementById(hash) : null;
  let ch = target ? target.closest('.chapter') : null;
  if (target && !ch && currentChapter) { target.focus(); return; } // e.g. the skip link to #main
  if (!ch) { ch = document.getElementById(store.get('lastChapter', 'ch1')) || $('#ch1'); if (!ch.classList.contains('chapter')) ch = $('#ch1'); target = ch; }
  if (currentChapter !== ch) {
    CHAPTERS.forEach((c) => { c.hidden = c !== ch; });
    currentChapter = ch;
    $$('#chapterList a.chap').forEach((a) => { if (a.dataset.ch === ch.id) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current'); });
    buildSubnav(ch);
    document.title = ch.dataset.title + ' · SmartBuildOS AI Core Guide';
    store.set('lastChapter', ch.id);
    setDot(ch.id, 'visited');
  }
  closeNav();
  requestAnimationFrame(() => {
    if (target && target !== ch) {
      if (target.tagName === 'DETAILS') target.open = true;
      target.scrollIntoView({ block: 'start' });
    } else window.scrollTo(0, 0);
    if (opts.focus) {
      const focusEl = target && target !== ch ? target : ch.querySelector('h1');
      if (focusEl) { if (!focusEl.hasAttribute('tabindex')) focusEl.setAttribute('tabindex', '-1'); focusEl.focus({ preventScroll: true }); }
    }
    onScroll();
  });
}
function onScroll() {
  const doc = document.documentElement;
  const max = doc.scrollHeight - window.innerHeight;
  const pct = max > 0 ? Math.min(100, Math.round((window.scrollY / max) * 100)) : 100;
  const bar = $('#readProgress');
  bar.style.width = pct + '%';
  bar.setAttribute('aria-valuenow', String(pct));
  if (currentChapter && pct >= 97) setDot(currentChapter.id, 'done');
}
window.addEventListener('scroll', onScroll, { passive: true });
window.addEventListener('resize', onScroll);
window.addEventListener('hashchange', () => route({ focus: true }));
document.addEventListener('click', (e) => {
  const a = e.target.closest('a[href^="#"]');
  if (!a || e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey) return;
  if (a.getAttribute('href') === location.hash) { e.preventDefault(); route({ focus: true }); }
});

/* theme */
function effectiveTheme() {
  const t = document.documentElement.dataset.theme;
  if (t === 'light' || t === 'dark') return t;
  return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}
function paintThemeButton() {
  const next = effectiveTheme() === 'dark' ? 'light' : 'dark';
  const b = $('#themeBtn');
  b.setAttribute('aria-label', 'Switch to ' + next + ' theme');
  b.innerHTML = next === 'light'
    ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>'
    : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>';
}
(function initTheme() {
  const saved = store.get('theme', null);
  if (saved === 'light' || saved === 'dark') document.documentElement.dataset.theme = saved;
  paintThemeButton();
  $('#themeBtn').addEventListener('click', () => {
    const next = effectiveTheme() === 'dark' ? 'light' : 'dark';
    document.documentElement.dataset.theme = next;
    store.set('theme', next);
    paintThemeButton();
    announce(next + ' theme');
  });
  if (window.matchMedia) window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', paintThemeButton);
})();

/* mobile drawer */
function openNav() { document.body.classList.add('nav-open'); $('#menuBtn').setAttribute('aria-expanded', 'true'); $('#menuBtn').setAttribute('aria-label', 'Close chapter navigation'); const a = $('#chapterList a[aria-current]') || $('#chapterList a'); if (a) a.focus(); }
function closeNav() { if (!document.body.classList.contains('nav-open')) return; document.body.classList.remove('nav-open'); $('#menuBtn').setAttribute('aria-expanded', 'false'); $('#menuBtn').setAttribute('aria-label', 'Open chapter navigation'); }
$('#menuBtn').addEventListener('click', () => { if (document.body.classList.contains('nav-open')) { closeNav(); $('#menuBtn').focus(); } else openNav(); });
$('#scrim').addEventListener('click', closeNav);
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && document.body.classList.contains('nav-open')) { closeNav(); $('#menuBtn').focus(); } });

/* ── search ── */
let searchIndex = [];
function buildSearchIndex() {
  searchIndex = [];
  CHAPTERS.forEach((ch) => {
    let cur = { id: ch.id, chapter: ch.dataset.title, title: ch.dataset.title, parts: [] };
    const push = () => { const text = cur.parts.join(' ').replace(/\s+/g, ' ').trim(); if (text) searchIndex.push({ id: cur.id, chapter: cur.chapter, title: cur.title, text, lower: text.toLowerCase() }); };
    Array.from(ch.children).forEach((node) => {
      if (node.classList.contains('chapter-nav')) return;
      const h2 = node.matches('h2[id]') ? node : null;
      if (h2) { push(); cur = { id: h2.id, chapter: ch.dataset.title, title: h2.textContent, parts: [h2.textContent] }; return; }
      cur.parts.push(textOf(node));
    });
    push();
  });
}
function textOf(node) {
  const clone = node.cloneNode(true);
  $$('script, style, svg, select, .copy, .lang', clone).forEach((n) => n.remove());
  return clone.textContent;
}
function runSearch(q) {
  const res = $('#searchResults');
  const query = q.trim().toLowerCase();
  res.dataset.q = q.trim();
  $('#searchClear').hidden = q.length === 0;
  if (query.length < 2) { res.hidden = true; res.innerHTML = ''; return; }
  const hits = [];
  for (const s of searchIndex) {
    let at = s.lower.indexOf(query), n = 0;
    if (at < 0) continue;
    const first = at;
    while (at >= 0) { n++; at = s.lower.indexOf(query, at + query.length); }
    hits.push({ s, n, first });
  }
  hits.sort((a, b) => (b.s.title.toLowerCase().includes(query) - a.s.title.toLowerCase().includes(query)) || b.n - a.n);
  const total = hits.reduce((t, h) => t + h.n, 0);
  if (!hits.length) {
    res.innerHTML = '<p class="count" id="searchNone">No results for “' + esc(q.trim()) + '”. Try a property name, a command such as AI_ASK, or an error code.</p>';
  } else {
    res.innerHTML = '<p class="count">' + total + ' match' + (total === 1 ? '' : 'es') + ' in ' + hits.length + ' section' + (hits.length === 1 ? '' : 's') + '</p><ol>' + hits.slice(0, 40).map((h) => {
      const start = Math.max(0, h.first - 60), end = Math.min(h.s.text.length, h.first + query.length + 80);
      const snip = (start > 0 ? '…' : '') + h.s.text.slice(start, end) + (end < h.s.text.length ? '…' : '');
      const safe = esc(snip).replace(new RegExp(escapeRe(esc(q.trim())), 'ig'), (m) => '<mark>' + m + '</mark>');
      return '<li><a href="#' + h.s.id + '" data-q="' + esc(q.trim()) + '"><b>' + esc(h.s.title) + (h.s.title !== h.s.chapter ? ' <small style="display:inline">· ' + esc(h.s.chapter) + '</small>' : '') + '</b><small>' + safe + '</small></a></li>';
    }).join('') + '</ol>';
  }
  res.hidden = false;
}
function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
function clearHighlights() {
  $$('mark[data-hit]').forEach((m) => { const t = document.createTextNode(m.textContent); m.replaceWith(t); t.parentNode.normalize(); });
}
function highlightIn(sectionId, q) {
  clearHighlights();
  const start = document.getElementById(sectionId);
  if (!start) return 0;
  const ch = start.closest('.chapter');
  const nodes = [];
  if (start === ch) nodes.push(...Array.from(ch.children).filter((n) => !n.classList.contains('chapter-nav')));
  else { let n = start; do { nodes.push(n); n = n.nextElementSibling; } while (n && !n.matches('h2[id]') && !n.classList.contains('chapter-nav')); }
  const re = new RegExp(escapeRe(q), 'ig');
  const reTest = new RegExp(escapeRe(q), 'i');
  let count = 0, first = null;
  nodes.forEach((root) => {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, { acceptNode: (t) => (t.parentElement.closest('script, style, svg, select, option, textarea, .copy, mark') ? NodeFilter.FILTER_REJECT : (reTest.test(t.data) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP)) });
    const texts = [];
    while (walker.nextNode()) texts.push(walker.currentNode);
    texts.forEach((t) => {
      re.lastIndex = 0;
      const frag = document.createDocumentFragment();
      let last = 0, m;
      while ((m = re.exec(t.data))) {
        frag.appendChild(document.createTextNode(t.data.slice(last, m.index)));
        const mark = document.createElement('mark'); mark.dataset.hit = ''; mark.textContent = m[0];
        frag.appendChild(mark); count++; if (!first) first = mark;
        last = m.index + m[0].length;
      }
      frag.appendChild(document.createTextNode(t.data.slice(last)));
      t.replaceWith(frag);
    });
  });
  if (first) { const d = first.closest('details'); if (d) d.open = true; requestAnimationFrame(() => first.scrollIntoView({ block: 'center' })); }
  return count;
}
(function initSearch() {
  const input = $('#searchInput'), res = $('#searchResults');
  let timer = null;
  input.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(() => runSearch(input.value), 80); });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') { res.hidden = true; }
    if (e.key === 'ArrowDown') { const a = $('a', res); if (a) { e.preventDefault(); a.focus(); } }
    if (e.key === 'Enter') { const a = $('a', res); if (a) { e.preventDefault(); a.click(); } }
  });
  res.addEventListener('keydown', (e) => {
    const links = $$('a', res); const i = links.indexOf(document.activeElement);
    if (e.key === 'ArrowDown' && i < links.length - 1) { e.preventDefault(); links[i + 1].focus(); }
    if (e.key === 'ArrowUp') { e.preventDefault(); if (i > 0) links[i - 1].focus(); else input.focus(); }
    if (e.key === 'Escape') { res.hidden = true; input.focus(); }
  });
  res.addEventListener('click', (e) => {
    const a = e.target.closest('a[data-q]'); if (!a) return;
    e.preventDefault();
    const id = a.getAttribute('href').slice(1);
    res.hidden = true;
    if (location.hash !== '#' + id) history.pushState(null, '', '#' + id);
    route({ focus: false });
    setTimeout(() => { const n = highlightIn(id, a.dataset.q); announce(n + ' highlighted match' + (n === 1 ? '' : 'es')); const h = document.getElementById(id); if (h) { if (!h.hasAttribute('tabindex')) h.setAttribute('tabindex', '-1'); h.focus({ preventScroll: true }); } }, 60);
  });
  $('#searchClear').addEventListener('click', () => { input.value = ''; runSearch(''); clearHighlights(); input.focus(); announce('Search cleared'); });
  document.addEventListener('click', (e) => { if (!e.target.closest('.search')) res.hidden = true; });
})();

/* ── glossary tooltips ── */
(function initGlossary() {
  const tip = $('#tip');
  let pinned = null, current = null;
  function show(el) {
    const g = GLOSSARY[el.dataset.term]; if (!g) return;
    current = el;
    tip.innerHTML = '<b>' + esc(g[0]) + '</b>' + esc(g[1]);
    tip.hidden = false;
    el.setAttribute('aria-describedby', 'tip');
    const r = el.getBoundingClientRect();
    const w = Math.min(340, window.innerWidth - 24);
    let left = r.left + window.scrollX;
    left = Math.max(12 + window.scrollX, Math.min(left, window.scrollX + window.innerWidth - w - 12));
    tip.style.left = left + 'px';
    tip.style.top = (r.bottom + window.scrollY + 8) + 'px';
  }
  function hide() { tip.hidden = true; if (current) current.removeAttribute('aria-describedby'); current = null; pinned = null; }
  $$('.term').forEach((el) => {
    el.setAttribute('aria-expanded', 'false');
    el.addEventListener('mouseenter', () => show(el));
    el.addEventListener('mouseleave', () => { if (pinned !== el) hide(); });
    el.addEventListener('focus', () => show(el));
    el.addEventListener('blur', () => { hide(); el.setAttribute('aria-expanded', 'false'); });
    el.addEventListener('click', () => { if (pinned === el) { hide(); el.setAttribute('aria-expanded', 'false'); } else { show(el); pinned = el; el.setAttribute('aria-expanded', 'true'); } });
  });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !tip.hidden) hide(); });
  window.addEventListener('scroll', () => { if (current && !tip.hidden) show(current); }, { passive: true });
})();

/* ── copy buttons ── */
function copyText(text, btn) {
  const done = (state, label) => { btn.dataset.state = state; btn.textContent = label; announce(state === 'ok' ? 'Copied to the clipboard' : 'Text selected. Press Control or Command and C to copy.'); setTimeout(() => { btn.textContent = 'Copy'; delete btn.dataset.state; }, 4000); };
  const fallback = () => {
    let ok = false;
    try {
      const ta = document.createElement('textarea');
      ta.value = text; ta.setAttribute('readonly', ''); ta.style.position = 'fixed'; ta.style.top = '-1000px';
      document.body.appendChild(ta); ta.select(); ok = document.execCommand && document.execCommand('copy'); ta.remove();
    } catch (e) { ok = false; }
    if (ok) { done('ok', 'Copied'); return; }
    const code = btn.parentElement.querySelector('code');
    const range = document.createRange(); range.selectNodeContents(code);
    const sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(range);
    done('manual', 'Press Ctrl/⌘+C');
  };
  try {
    if (navigator.clipboard && navigator.clipboard.writeText && window.isSecureContext) navigator.clipboard.writeText(text).then(() => done('ok', 'Copied'), fallback);
    else fallback();
  } catch (e) { fallback(); }
}
function decorateCode(root) {
  $$('pre.code', root).forEach((pre) => {
    if (pre.querySelector('.copy')) return;
    const lang = document.createElement('span'); lang.className = 'lang'; lang.textContent = pre.dataset.lang || 'text'; lang.setAttribute('aria-hidden', 'true');
    const b = document.createElement('button'); b.type = 'button'; b.className = 'copy'; b.textContent = 'Copy';
    b.setAttribute('aria-label', 'Copy ' + (pre.dataset.lang || 'text') + ' example');
    b.addEventListener('click', () => copyText(pre.querySelector('code').textContent, b));
    pre.prepend(lang); pre.appendChild(b);
    pre.setAttribute('tabindex', '0');
    pre.setAttribute('role', 'region');
    pre.setAttribute('aria-label', (pre.dataset.lang || 'text') + ' example');
  });
}
