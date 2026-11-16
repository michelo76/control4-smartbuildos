/* VenueFlow shared client: DOM helper, icons, the protocol transport, the state
   store, and the common dialogs. Used by the operator page and Installer Studio.
   Plain script (no modules, no build step), ES2020, no external resources. */
var VF = (function () {
  'use strict';
  var VF = {};

  /* ── small utilities ─────────────────────────────────────────────────── */
  /* The driver's JSON encoder writes an EMPTY Lua table as [] whether it was
     meant as a list or a map. Always read collections through these. */
  VF.asList = function (x) { return Array.isArray(x) ? x : (x && typeof x === 'object' ? Object.values(x) : []); };
  VF.asMap = function (x) { return (x && typeof x === 'object' && !Array.isArray(x)) ? x : {}; };
  VF.byId = function (list, id) { list = VF.asList(list); for (var i = 0; i < list.length; i++) { if (list[i] && list[i].id === id) return list[i]; } return null; };
  VF.clone = function (x) { return x === undefined ? undefined : JSON.parse(JSON.stringify(x)); };
  VF.clamp = function (n, lo, hi) { return Math.max(lo, Math.min(hi, n)); };
  VF.debounce = function (fn, ms) { var t = null; return function () { var a = arguments, self = this; clearTimeout(t); t = setTimeout(function () { fn.apply(self, a); }, ms); }; };
  VF.slug = function (text) { var s = String(text || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, ''); return (s || 'item').slice(0, 48); };
  /* A new id not used by any entry of `list` (ids are stable: never derive one from a name twice). */
  VF.freshId = function (base, list) {
    var taken = {}; VF.asList(list).forEach(function (x) { if (x && x.id) taken[x.id] = true; });
    var id = VF.slug(base); if (!taken[id]) return id;
    for (var n = 2; ; n++) { var c = id.slice(0, 48 - String(n).length - 1) + '-' + n; if (!taken[c]) return c; }
  };
  VF.fmtTime = function (epoch) { if (!epoch) return ''; var d = new Date(epoch * 1000); return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); };
  VF.fmtDateTime = function (epoch) { if (!epoch) return ''; var d = new Date(epoch * 1000); return d.toLocaleDateString([], { month: 'short', day: 'numeric' }) + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); };
  VF.ago = function (epoch) { if (!epoch) return ''; var s = Math.max(0, Math.round(Date.now() / 1000 - epoch)); if (s < 60) return s + ' s ago'; if (s < 3600) return Math.round(s / 60) + ' min ago'; if (s < 86400) return Math.round(s / 3600) + ' h ago'; return Math.round(s / 86400) + ' d ago'; };

  /* ── DOM ─────────────────────────────────────────────────────────────── */
  /* VF.h('div.card.sel#id', {onclick: fn, title: 'x', style: {...}, dataset: {...}}, child, 'text', [more]) */
  VF.h = function (spec, attrs) {
    var m = /^([a-z0-9]+)?((?:[.#][\w-]+)*)$/i.exec(spec) || [];
    var el = document.createElement(m[1] || 'div');
    (m[2] || '').replace(/([.#])([\w-]+)/g, function (_, k, v) { if (k === '.') el.classList.add(v); else el.id = v; return ''; });
    var start = 1;
    if (attrs && typeof attrs === 'object' && !(attrs instanceof Node) && !Array.isArray(attrs)) {
      start = 2;
      Object.keys(attrs).forEach(function (k) {
        var v = attrs[k];
        if (v === undefined || v === null || v === false) return;
        if (k === 'style' && typeof v === 'object') Object.assign(el.style, v);
        else if (k === 'dataset') Object.keys(v).forEach(function (d) { el.dataset[d] = v[d]; });
        else if (k === 'class') String(v).split(/\s+/).forEach(function (c) { if (c) el.classList.add(c); });
        else if (k.slice(0, 2) === 'on' && typeof v === 'function') el.addEventListener(k.slice(2), v);
        else if (k === 'value' || k === 'checked' || k === 'disabled' || k === 'selected' || k === 'textContent' || k === 'htmlFor') el[k] = v;
        else el.setAttribute(k, v === true ? '' : String(v));
      });
    }
    for (var i = start; i < arguments.length; i++) VF.append(el, arguments[i]);
    return el;
  };
  VF.append = function (el, child) {
    if (child === undefined || child === null || child === false) return el;
    if (Array.isArray(child)) { child.forEach(function (c) { VF.append(el, c); }); return el; }
    el.appendChild(child instanceof Node ? child : document.createTextNode(String(child)));
    return el;
  };
  VF.clear = function (el) { while (el.firstChild) el.removeChild(el.firstChild); return el; };
  VF.mount = function (el) { VF.clear(el); for (var i = 1; i < arguments.length; i++) VF.append(el, arguments[i]); return el; };

  /* ── icons (24x24, stroke) ───────────────────────────────────────────── */
  var IC = {
    home: 'M3 11l9-8 9 8M5 10v10h5v-6h4v6h5V10',
    monitor: 'M3 4h18v12H3zM8 20h8M12 16v4',
    tv: 'M2 6h20v12H2zM7 21h10',
    laptop: 'M4 5h16v10H4zM2 19h20',
    video: 'M3 6h12v12H3zM15 10l6-3v10l-6-3',
    volume: 'M4 9v6h4l5 4V5L8 9zM16 9a4 4 0 010 6M18.5 6.5a8 8 0 010 11',
    'volume-x': 'M4 9v6h4l5 4V5L8 9zM16 9l5 6M21 9l-5 6',
    music: 'M9 18V5l11-2v13M9 18a3 3 0 11-6 0 3 3 0 016 0zM20 16a3 3 0 11-6 0 3 3 0 016 0z',
    layers: 'M12 3l9 5-9 5-9-5zM3 13l9 5 9-5M3 17.5l9 5 9-5',
    calendar: 'M4 6h16v15H4zM4 10h16M8 3v5M16 3v5',
    clock: 'M12 21a9 9 0 100-18 9 9 0 000 18zM12 7v5l3 2',
    bars: 'M5 20V10M10 20V4M15 20v-8M20 20V7',
    power: 'M12 3v9M6.3 6.3a8 8 0 1011.4 0',
    sun: 'M12 16a4 4 0 100-8 4 4 0 000 8zM12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4',
    moon: 'M20 14.5A8.5 8.5 0 119.5 4a7 7 0 0010.5 10.5z',
    football: 'M4.5 19.5c-2-6 1-13 9-14.5 2.5-.4 4.5-.2 6 .5.7 1.5.9 3.500.5 6-1.500 8-8.500 11-14.500 9zM9 15l6-6M10.5 10.500l3 3M4.700 12.500l6.800 6.800M12.500 4.700l6.800 6.800',
    cocktail: 'M4 4h16l-8 9zM12 13v7M8 20h8M15 4l2-2',
    utensils: 'M5 3v7a2 2 0 004 0V3M7 10v11M17 3c-2 2-3 4-3 7h3v11',
    sparkles: 'M12 3l1.800 5.200L19 10l-5.200 1.800L12 17l-1.800-5.200L5 10l5.200-1.800zM19 16l.800 2.200L22 19l-2.200.800L19 22l-.800-2.200L16 19l2.200-.800z',
    play: 'M7 4l13 8-13 8z',
    stop: 'M6 6h12v12H6z',
    check: 'M4 12.500l5 5L20 6.500',
    'check-circle': 'M12 21a9 9 0 100-18 9 9 0 000 18zM8 12.500l3 3 5-6',
    x: 'M6 6l12 12M18 6L6 18',
    plus: 'M12 5v14M5 12h14',
    minus: 'M5 12h14',
    alert: 'M12 3l10 18H2zM12 10v5M12 18v.500',
    info: 'M12 21a9 9 0 100-18 9 9 0 000 18zM12 11v6M12 7.500v.500',
    settings: 'M12 15.500a3.500 3.500 0 100-7 3.500 3.500 0 000 7zM19 12a7 7 0 00-.100-1.200l2-1.600-2-3.400-2.400 1a7 7 0 00-2-1.200L14 3h-4l-.500 2.600a7 7 0 00-2 1.200l-2.400-1-2 3.400 2 1.600a7 7 0 000 2.400l-2 1.600 2 3.400 2.400-1a7 7 0 002 1.200L10 21h4l.500-2.600a7 7 0 002-1.200l2.400 1 2-3.400-2-1.600A7 7 0 0019 12z',
    sliders: 'M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0M14 4v4M8 10v4M16 16v4',
    'chevron-right': 'M9 5l7 7-7 7', 'chevron-left': 'M15 5l-7 7 7 7', 'chevron-down': 'M5 9l7 7 7-7', 'chevron-up': 'M5 15l7-7 7 7',
    'arrow-right': 'M4 12h16M14 6l6 6-6 6', 'arrow-left': 'M20 12H4M10 6l-6 6 6 6', 'arrow-up': 'M12 20V4M6 10l6-6 6 6', 'arrow-down': 'M12 4v16M6 14l6 6 6-6',
    route: 'M4 8h13M13 4l4 4-4 4M20 16H7M11 12l-4 4 4 4',
    trash: 'M4 7h16M9 7V4h6v3M6 7l1 14h10l1-14M10 11v6M14 11v6',
    copy: 'M9 9h11v12H9zM5 15H4V3h11v2',
    edit: 'M4 20h4L20 8l-4-4L4 16zM14 6l4 4',
    grip: 'M9 6h.010M15 6h.010M9 12h.010M15 12h.010M9 18h.010M15 18h.010',
    lock: 'M6 11h12v10H6zM8 11V7a4 4 0 018 0v4', unlock: 'M6 11h12v10H6zM8 11V7a4 4 0 017.500-2',
    undo: 'M4 9h10a5 5 0 010 10H9M4 9l4-4M4 9l4 4', redo: 'M20 9H10a5 5 0 000 10h5M20 9l-4-4M20 9l-4 4',
    'zoom-in': 'M11 18a7 7 0 100-14 7 7 0 000 14zM21 21l-5-5M11 8v6M8 11h6', 'zoom-out': 'M11 18a7 7 0 100-14 7 7 0 000 14zM21 21l-5-5M8 11h6',
    maximize: 'M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5',
    move: 'M12 2v20M2 12h20M12 2l-3 3M12 2l3 3M12 22l-3-3M12 22l3-3M2 12l3-3M2 12l3 3M22 12l-3-3M22 12l-3 3',
    cursor: 'M5 3l14 7-6 2-2 6z',
    grid: 'M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z',
    map: 'M3 6l6-3 6 3 6-3v15l-6 3-6-3-6 3zM9 3v15M15 6v15',
    users: 'M9 11a4 4 0 100-8 4 4 0 000 8zM2 21a7 7 0 0114 0M17 11a3 3 0 100-6M22 21a6 6 0 00-5-5.900',
    user: 'M12 12a4.500 4.500 0 100-9 4.500 4.500 0 000 9zM4 21a8 8 0 0116 0',
    shield: 'M12 3l8 3v6c0 5-3.500 8-8 9-4.500-1-8-4-8-9V6z',
    key: 'M15 9a4 4 0 11-3.900 5H9v3H6v3H3v-3l6.200-6.200A4 4 0 0115 9z',
    download: 'M12 3v12M7 10l5 5 5-5M4 20h16', upload: 'M12 15V3M7 8l5-5 5 5M4 20h16',
    refresh: 'M20 12a8 8 0 10-2.300 5.700M20 5v6h-6',
    search: 'M11 18a7 7 0 100-14 7 7 0 000 14zM21 21l-5-5',
    zap: 'M13 2L4 14h7l-1 8 9-12h-7z',
    bulb: 'M9 18h6M10 21h4M12 3a6 6 0 00-4 10.500c.700.700 1 1.500 1 2.500h6c0-1 .300-1.800 1-2.500A6 6 0 0012 3z',
    blinds: 'M3 4h18M5 4v16M19 4v16M5 8h14M5 12h14M5 16h14M3 20h18',
    eye: 'M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12zM12 15a3 3 0 100-6 3 3 0 000 6z',
    'eye-off': 'M3 3l18 18M10.600 6.200A9.500 9.500 0 0112 6c6 0 10 6 10 6a17 17 0 01-3.200 3.800M6.500 7.800A16 16 0 002 12s4 6 10 6a9 9 0 003.500-.700M9.900 9.900a3 3 0 004.200 4.200',
    wrench: 'M14.500 6.500a4 4 0 005 5L21 13l-8 8-3-3 8-8zM3 21l7-7M5 3l4 4-2 2-4-4z',
    link: 'M10 14a4 4 0 005.700 0l3-3a4 4 0 00-5.700-5.700l-1 1M14 10a4 4 0 00-5.700 0l-3 3a4 4 0 005.700 5.700l1-1',
    image: 'M3 5h18v14H3zM3 16l5-5 4 4 3-3 6 6M9 9.500a1.500 1.500 0 11-3 0 1.500 1.500 0 013 0z',
    list: 'M8 6h13M8 12h13M8 18h13M3 6h.010M3 12h.010M3 18h.010',
    'more': 'M5 12h.010M12 12h.010M19 12h.010',
    flag: 'M5 21V4M5 4h13l-2 4 2 4H5',
    code: 'M8 7l-5 5 5 5M16 7l5 5-5 5M14 4l-4 16',
    box: 'M12 3l9 5v8l-9 5-9-5V8zM3 8l9 5 9-5M12 13v8',
    activity: 'M3 12h4l3-8 4 16 3-8h4',
    save: 'M5 3h12l4 4v14H5zM8 3v6h8V3M8 21v-7h8v7',
    send: 'M21 3L3 10.500l7 3 3 7zM10 13.500L21 3',
    target: 'M12 21a9 9 0 100-18 9 9 0 000 18zM12 16a4 4 0 100-8 4 4 0 000 8zM12 12h.010',
    signage: 'M3 4h18v11H3zM7 8h6M7 11h10M9 19h6M12 15v4',
    cable: 'M4 7h16v10H4zM8 11h2M12 11h2M16 11h0M8 17v3M16 17v3',
    satellite: 'M5 14a5 5 0 005 5M5 10a9 9 0 009 9M13 7l4 4-5 5-4-4zM16 4l4 4-3 3-4-4zM5 19l3-3',
    globe: 'M12 21a9 9 0 100-18 9 9 0 000 18zM3 12h18M12 3a14 14 0 010 18M12 3a14 14 0 000 18',
    building: 'M4 21V4h10v17M14 9h6v12M8 8h2M8 12h2M8 16h2M17 13h0M17 17h0M2 21h20',
    'log-out': 'M9 4H4v16h5M15 8l4 4-4 4M19 12H9',
    'help': 'M12 21a9 9 0 100-18 9 9 0 000 18zM9.500 9.500a2.500 2.500 0 114 2c-.900.700-1.500 1.200-1.500 2.500M12 17v.500',
    spinner: 'M12 3a9 9 0 109 9',
    palette: 'M12 3a9 9 0 100 18c1.500 0 2-1 2-2 0-1.500-1-2-1-3s1-2 2.500-2H18a3 3 0 003-3c0-4.400-4-8-9-8zM7.500 11h.010M10 7.500h.010M14.500 7.500h.010',
    type: 'M5 6V4h14v2M12 4v16M9 20h6',
    square: 'M4 4h16v16H4z',
    history: 'M4 12a8 8 0 108-8 8 8 0 00-6.300 3.100M4 4v4h4M12 8v4l3 2',
    package: 'M12 3l9 5v8l-9 5-9-5V8zM3 8l9 5 9-5M12 13v8M7.500 5.500l9 5',
    star: 'M12 3l2.700 5.600 6.300.900-4.500 4.400 1 6.100L12 17l-5.500 3 1-6.100L3 9.500l6.300-.900z'
  };
  /* Paths above are written with "500"-style decimals (".5" -> ".500") so they survive
     minifiers; normalise is not needed, the browser parses them as numbers. */
  VF.ICONS = IC;
  VF.icon = function (name, cls) {
    var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 24 24'); svg.setAttribute('class', 'ic' + (cls ? ' ' + cls : '')); svg.setAttribute('aria-hidden', 'true');
    var p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    p.setAttribute('d', IC[name] || IC.square); svg.appendChild(p);
    return svg;
  };
  VF.SOURCE_ICON = { cable: 'cable', satellite: 'satellite', streaming: 'play', signage: 'signage', laptop: 'laptop', conference: 'video', music: 'music', camera: 'eye', other: 'monitor' };
  VF.SCENE_ICON = { sun: 'sun', moon: 'moon', football: 'football', cocktail: 'cocktail', utensils: 'utensils', laptop: 'laptop', video: 'video', sparkles: 'sparkles', tv: 'tv', power: 'power', music: 'music', star: 'star', zap: 'zap', bulb: 'bulb' };
  VF.sceneIcon = function (name, cls) { return VF.icon(VF.SCENE_ICON[name] || 'zap', cls); };

  /* ── events ──────────────────────────────────────────────────────────── */
  var listeners = {};
  VF.on = function (name, fn) { (listeners[name] = listeners[name] || []).push(fn); return function () { listeners[name] = (listeners[name] || []).filter(function (f) { return f !== fn; }); }; };
  VF.emit = function (name, a, b) { (listeners[name] || []).slice().forEach(function (fn) { try { fn(a, b); } catch (e) { console.error('VF listener ' + name, e); } }); };

  /* ── transport ───────────────────────────────────────────────────────── */
  var params = new URLSearchParams(location.search);
  var relay = params.get('relay') || '';
  if (!relay && /^https?:$/.test(location.protocol)) relay = location.origin;
  var tile = params.get('k') || '';
  var seq = 0;
  var sessionKey = 'vf.session';
  VF.transport = { relay: relay, tile: tile !== '', mode: relay ? 'relay' : (window.C4 ? 'bridge' : 'none') };
  VF.session = {
    use: function (kind) { sessionKey = 'vf.session.' + kind; },
    get: function () { try { return sessionStorage.getItem(sessionKey) || ''; } catch (e) { return VF.session._mem || ''; } },
    set: function (token) { VF.session._mem = token || ''; try { if (token) sessionStorage.setItem(sessionKey, token); else sessionStorage.removeItem(sessionKey); } catch (e) { /* private mode: memory only */ } },
    clear: function () { VF.session.set(''); }
  };

  /* Navigator bridge (documented WebView JS API). Used only when the relay cannot be
     reached; the reply comes back through onDataToUi. Unverified on hardware. */
  var bridgeWaiting = {};
  function findEnvelope(x, depth) {
    if (depth > 6 || x == null) return null;
    if (typeof x === 'string') {
      if (x.indexOf('"requestId"') >= 0) { try { var o = JSON.parse(x); if (o && o.requestId) return o; return findEnvelope(o, depth + 1); } catch (e) { return null; } }
      return null;
    }
    if (typeof x === 'object') {
      if (x.requestId && x.command) return x;
      for (var k in x) { var f = findEnvelope(x[k], depth + 1); if (f) return f; }
    }
    return null;
  }
  window.onDataToUi = function (response) {
    var env = findEnvelope(response, 0);
    if (!env) { try { env = findEnvelope(JSON.parse(response), 0); } catch (e) { env = null; } }
    if (env && env.push === 'state') { VF.emit('push'); return; }
    if (env && bridgeWaiting[env.requestId]) { var w = bridgeWaiting[env.requestId]; delete bridgeWaiting[env.requestId]; clearTimeout(w.timer); w.resolve(env); }
  };
  var bridgeReady = false;
  function viaBridge(request) {
    return new Promise(function (resolve) {
      if (!window.C4 || typeof window.C4.sendCommand !== 'function') { resolve(null); return; }
      try {
        if (!bridgeReady && typeof window.C4.subscribeToDataToUi === 'function') { window.C4.subscribeToDataToUi(true); bridgeReady = true; }
        bridgeWaiting[request.requestId] = { resolve: resolve, timer: setTimeout(function () { delete bridgeWaiting[request.requestId]; resolve(null); }, 6000) };
        window.C4.sendCommand('VF_COMMAND', JSON.stringify({ ENVELOPE: JSON.stringify(request) }), true, true);
      } catch (e) { resolve(null); }
    });
  }
  function viaRelay(request) {
    if (!relay) return Promise.resolve(null);
    var url = relay + '/api' + (tile ? '?k=' + encodeURIComponent(tile) : '');
    var ctrl = typeof AbortController === 'function' ? new AbortController() : null;
    var timer = setTimeout(function () { if (ctrl) ctrl.abort(); }, 15000);
    return fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(request), signal: ctrl ? ctrl.signal : undefined, cache: 'no-store' })
      .then(function (r) { return r.json(); })
      .catch(function () { return null; })
      .then(function (reply) { clearTimeout(timer); return reply; });
  }
  var online = true;
  /* VF.api(command, payload, {since:false}) -> Promise(reply). Never rejects: a transport
     failure is a reply with ok:false and errorCode 'VF_NETWORK'. */
  VF.api = function (command, payload, opts) {
    opts = opts || {};
    var request = { requestId: 'r' + Date.now().toString(36) + '-' + (++seq), command: command, payload: payload || {}, ts: Math.floor(Date.now() / 1000) };
    var session = VF.session.get(); if (session) request.session = session;
    if (opts.since !== false && VF.state.version) request.since = VF.state.version;
    var attempt = VF.transport.mode === 'bridge' ? viaBridge(request) : viaRelay(request).then(function (reply) { return reply || (window.C4 ? viaBridge(request) : null); });
    return attempt.then(function (reply) {
      if (!reply || typeof reply !== 'object') {
        if (online) { online = false; VF.emit('online', false); }
        return { requestId: request.requestId, command: command, ok: false, status: 'failed', errorCode: 'VF_NETWORK', message: 'Cannot reach the controller. Check that this device is on the venue network.' };
      }
      if (!online) { online = true; VF.emit('online', true); }
      if (reply.state) VF.state.set(reply.state);
      if (reply.errorCode === 'VF_UNAUTHENTICATED' && session) { VF.session.clear(); VF.emit('signedout'); }
      return reply;
    });
  };

  /* Stores a floor-plan picture (a data: URL). It goes to the relay's /image route as raw
     text with the session in a header, NOT inside a JSON request: the driver's JSON decoder
     is very slow on long strings. Returns Promise(reply) with data.key; never rejects. */
  VF.upload = function (dataUrl) {
    var failed = { ok: false, status: 'failed', errorCode: 'VF_NETWORK', message: 'Cannot reach the controller. Check that this device is on the venue network.' };
    if (!relay) return Promise.resolve(failed);
    var ctrl = typeof AbortController === 'function' ? new AbortController() : null;
    var timer = setTimeout(function () { if (ctrl) ctrl.abort(); }, 60000);
    return fetch(relay + '/image', { method: 'POST', headers: { 'Content-Type': 'text/plain', 'X-VF-Session': VF.session.get() }, body: dataUrl, signal: ctrl ? ctrl.signal : undefined, cache: 'no-store' })
      .then(function (r) { return r.json(); })
      .catch(function () { return null; })
      .then(function (reply) { clearTimeout(timer); return (reply && typeof reply === 'object') ? reply : failed; });
  };

  /* ── operator state store ────────────────────────────────────────────── */
  VF.state = {
    version: 0, doc: null,
    set: function (doc) { if (!doc) return; VF.state.doc = doc; VF.state.version = doc.version || 0; VF.emit('state', doc); },
    cell: function (kind, id, field) { var d = VF.state.doc; if (!d) return { status: 'unknown' }; var e = VF.asMap(d[kind])[id]; return (e && e[field]) || { status: 'unknown' }; }
  };
  var pollTimer = null;
  VF.poll = {
    start: function (ms) {
      VF.poll.stop();
      var busy = false;
      pollTimer = setInterval(function () {
        if (busy || document.hidden) return;
        busy = true;
        VF.api('GET_STATE', {}).then(function (r) { busy = false; if (r.ok && r.data && r.data.state) VF.state.set(r.data.state); });
      }, ms || 1500);
    },
    stop: function () { if (pollTimer) clearInterval(pollTimer); pollTimer = null; }
  };

  /* ── status vocabulary ───────────────────────────────────────────────── */
  VF.STATUS_LABEL = { confirmed: 'Confirmed', pending: 'Working', commanded: 'Sent', unknown: 'Unknown', failed: 'Not confirmed' };
  VF.STATUS_CHIP = { confirmed: 'ok', pending: 'teal', commanded: 'info', unknown: '', failed: 'warn' };
  VF.statusChip = function (cell, label) {
    var st = (cell && cell.status) || 'unknown';
    return VF.h('span.chip.' + (VF.STATUS_CHIP[st] || 'x'), { title: VF.STATUS_LABEL[st] }, VF.h('span.dot' + (st === 'pending' ? '.pulse' : '')), label || VF.STATUS_LABEL[st]);
  };
  VF.OUTCOME_LABEL = { pending: 'Working', planned: 'Would run', confirmed: 'Confirmed', commanded: 'Sent (no feedback)', failed: 'Failed', unknown: 'Not confirmed', superseded: 'Replaced', read: 'Read', ok: 'Done', sent: 'Sent', partial: 'Partly done', skipped: 'Skipped', incomplete: 'Not set up', cancelled: 'Stopped', waiting: 'Waiting', running: 'Running' };
  VF.OUTCOME_CHIP = { pending: 'teal', planned: 'info', confirmed: 'ok', commanded: 'info', failed: 'bad', unknown: 'warn', superseded: '', read: 'ok', ok: 'ok', sent: 'teal', partial: 'warn', skipped: '', incomplete: 'warn', cancelled: 'warn', waiting: 'teal', running: 'teal' };
  VF.outcomeChip = function (status) { return VF.h('span.chip.' + (VF.OUTCOME_CHIP[status] || 'x'), VF.OUTCOME_LABEL[status] || status); };

  /* ── toasts ──────────────────────────────────────────────────────────── */
  var toastHost = null;
  VF.toast = function (message, kind, ms) {
    if (!toastHost) { toastHost = VF.h('div.vf-toasts', { role: 'status', 'aria-live': 'polite' }); document.body.appendChild(toastHost); }
    var icon = kind === 'ok' ? 'check-circle' : (kind === 'bad' || kind === 'warn' ? 'alert' : 'info');
    var el = VF.h('div.vf-toast' + (kind ? '.' + kind : ''), VF.icon(icon), VF.h('span', message));
    toastHost.appendChild(el);
    while (toastHost.children.length > 3) toastHost.removeChild(toastHost.firstChild);
    setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el); }, ms || (kind === 'bad' || kind === 'warn' ? 6000 : 3200));
  };
  /* Says what a reply means in one line. Never says "done" for a partial or failed reply. */
  VF.toastReply = function (reply, okText) {
    if (!reply) return;
    var s = reply.summary;
    if (reply.ok && reply.status === 'partial' && s) { VF.toast((s.accepted || 0) + ' sent, ' + (s.rejected || 0) + ' could not be done', 'warn'); return; }
    if (reply.ok) { if (okText) VF.toast(okText, 'ok'); return; }
    VF.toast(reply.message || 'That did not work.', reply.errorCode === 'VF_FORBIDDEN' || reply.errorCode === 'VF_CONFIRM_REQUIRED' ? 'warn' : 'bad');
  };

  /* ── modal ───────────────────────────────────────────────────────────── */
  /* VF.modal({title, icon, body: Node|string, wide, actions: [{label, kind:'primary|danger|warn|ghost', value, disabled}], dismiss:true})
     -> Promise(value of the pressed action, or null when dismissed). `close(value)` is also given to opts.onOpen. */
  VF.modal = function (opts) {
    return new Promise(function (resolve) {
      var done = false;
      function close(value) { if (done) return; done = true; document.removeEventListener('keydown', onKey); if (back.parentNode) back.parentNode.removeChild(back); resolve(value === undefined ? null : value); }
      function onKey(e) { if (e.key === 'Escape' && opts.dismiss !== false) close(null); }
      var footer = VF.h('footer');
      (opts.actions || [{ label: 'Close', value: null }]).forEach(function (a) {
        footer.appendChild(VF.h('button.btn' + (a.kind ? '.' + a.kind : ''), { type: 'button', disabled: a.disabled, onclick: function () {
          /* A value FUNCTION may return false to keep the dialog open (a form that is not valid yet).
             A plain value, including false (Cancel), always closes. */
          if (typeof a.value === 'function') { var v = a.value(); if (v !== false) close(v === undefined ? a.label : v); }
          else close(a.value === undefined ? a.label : a.value);
        } }, a.icon ? VF.icon(a.icon) : null, a.label));
      });
      var body = VF.h('div.body', typeof opts.body === 'string' ? VF.h('p.muted', opts.body) : opts.body);
      var box = VF.h('div.vf-modal' + (opts.wide ? '.wide' : ''), { role: 'dialog', 'aria-modal': 'true', 'aria-label': opts.title || 'Dialog' },
        VF.h('header', opts.icon ? VF.icon(opts.icon, 'lg') : null, VF.h('h2.grow', opts.title || ''), opts.dismiss === false ? null : VF.h('button.btn.ghost.icon.sm', { type: 'button', 'aria-label': 'Close', onclick: function () { close(null); } }, VF.icon('x'))),
        body, footer);
      var back = VF.h('div.vf-backdrop', { onclick: function (e) { if (e.target === back && opts.dismiss !== false) close(null); } }, box);
      document.body.appendChild(back);
      document.addEventListener('keydown', onKey);
      if (opts.onOpen) opts.onOpen(close, body);
      var first = box.querySelector('input, select, textarea, footer .btn.primary, footer .btn'); if (first) { try { first.focus(); } catch (e) { /* ignore */ } }
    });
  };
  VF.confirm = function (title, text, okLabel, kind) {
    return VF.modal({ title: title, icon: kind === 'danger' ? 'alert' : 'help', body: text, actions: [{ label: 'Cancel', kind: 'ghost', value: false }, { label: okLabel || 'Confirm', kind: kind || 'primary', value: true }] }).then(function (v) { return v === true; });
  };
  VF.prompt = function (title, label, value, okLabel) {
    var input = VF.h('input.field', { type: 'text', value: value || '', maxlength: 80 });
    return VF.modal({ title: title, body: VF.h('label.lbl', label, input),
      actions: [{ label: 'Cancel', kind: 'ghost', value: null }, { label: okLabel || 'Save', kind: 'primary', value: function () { return input.value.trim() || false; } }],
      onOpen: function (close) { input.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); if (input.value.trim()) close(input.value.trim()); } }); } });
  };

  /* PIN pad -> Promise(pin string | null). Digits only, 4 to 8. */
  VF.pinPad = function (title, subtitle) {
    return new Promise(function (resolve) {
      var pin = '';
      var dots = VF.h('div.pindots');
      function paint() { VF.clear(dots); for (var i = 0; i < Math.max(4, pin.length); i++) dots.appendChild(VF.h('i' + (i < pin.length ? '.on' : ''))); ok.disabled = pin.length < 4; }
      var ok = VF.h('button.btn.primary', { type: 'button', disabled: true }, VF.icon('check'), 'OK');
      var pad = VF.h('div.pinpad');
      '1 2 3 4 5 6 7 8 9'.split(' ').forEach(function (d) { pad.appendChild(VF.h('button.btn', { type: 'button', onclick: function () { if (pin.length < 8) { pin += d; paint(); } } }, d)); });
      pad.appendChild(VF.h('button.btn.ghost', { type: 'button', 'aria-label': 'Delete', onclick: function () { pin = pin.slice(0, -1); paint(); } }, VF.icon('arrow-left')));
      pad.appendChild(VF.h('button.btn', { type: 'button', onclick: function () { if (pin.length < 8) { pin += '0'; paint(); } } }, '0'));
      pad.appendChild(ok);
      var closer = null;
      ok.addEventListener('click', function () { if (closer) closer(pin); });
      /* Capture phase + preventDefault: a digit or Enter must never reach a focused button
         (Enter on the focused Cancel would close the pad, or the dialog opened after it). */
      function onKey(e) {
        if (/^\d$/.test(e.key)) { e.preventDefault(); e.stopPropagation(); if (pin.length < 8) { pin += e.key; paint(); } }
        else if (e.key === 'Backspace') { e.preventDefault(); e.stopPropagation(); pin = pin.slice(0, -1); paint(); }
        else if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); if (pin.length >= 4 && closer) closer(pin); }
      }
      document.addEventListener('keydown', onKey, true);
      paint();
      VF.modal({ title: title || 'Enter PIN', icon: 'lock', body: VF.h('div', subtitle ? VF.h('p.muted.small', { style: { textAlign: 'center', marginBottom: '8px' } }, subtitle) : null, dots, pad), actions: [{ label: 'Cancel', kind: 'ghost', value: null }], onOpen: function (close) { closer = close; } })
        .then(function (v) { document.removeEventListener('keydown', onKey, true); resolve(typeof v === 'string' && /^\d{4,8}$/.test(v) ? v : null); });
    });
  };

  /* Per-device outcome list for a reply or an operation ({results|targets}). */
  VF.outcomeList = function (items) {
    var list = VF.h('div.list');
    VF.asList(items).forEach(function (r) {
      list.appendChild(VF.h('div.item', VF.h('div.grow', VF.h('div', r.name || r.label || r.id), r.message ? VF.h('div.small.muted', r.message) : null, r.detail ? VF.h('div.tiny.mono.muted', r.detail) : null), VF.outcomeChip(r.status)));
    });
    return list;
  };

  /* A range input wired for touch: oninput paints, onchange commits. */
  VF.slider = function (value, min, max, onCommit, onInput) {
    var el = VF.h('input.slider', { type: 'range', min: min, max: max, step: 1, value: value });
    function fill() { el.style.setProperty('--fill', ((el.value - min) / Math.max(1, max - min) * 100) + '%'); }
    el.addEventListener('input', function () { fill(); if (onInput) onInput(Number(el.value)); });
    el.addEventListener('change', function () { if (onCommit) onCommit(Number(el.value)); });
    el.setValue = function (v) { el.value = v; fill(); };
    fill();
    return el;
  };

  return VF;
})();
