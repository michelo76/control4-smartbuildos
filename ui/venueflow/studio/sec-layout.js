/* Installer Studio section: Layout Designer (the venue floor-plan editor).

   What this file may change in the draft: floors, an object's `layout`
   (x, y, w, h, rot, locked, hidden), a display's or zone's `floorId`, a
   display's `areaId`, names, area colours, labels and scene buttons.
   It never writes c4RoomId, c4DeviceId, route, sources, power or feedback:
   the mapping is shown read-only and edited in the Devices section.

   The shell re-renders a section on every non-silent update, which would reset
   the canvas, so every change here is a silent Studio.update followed by our
   own repaint; zoom, pan, selection, tool and the undo stack live in module
   variables and survive a re-render. */
(function () {
  'use strict';
  var h = VF.h, icon = VF.icon;
  var NS = 'http://www.w3.org/2000/svg';
  var RULER = 22, STATUS = 30, MINK = 0.08, MAXK = 8, UNDO_MAX = 50;
  var DEF = { display: { w: 76, h: 44 }, zone: { w: 140, h: 60 }, area: { w: 240, h: 160 }, button: { w: 130, h: 44 } };
  var PALETTE = ['#2dd4bf', '#60a5fa', '#34d399', '#a78bfa', '#f59e0b', '#f472b6', '#f87171', '#94a3b8'];
  var FIELD = { area: 'areas', display: 'displays', zone: 'audioZones' };
  var NOUN = { area: 'Area', display: 'Display', zone: 'Audio zone', label: 'Label', button: 'Scene button' };
  var LAYER = { area: 'areas', display: 'displays', zone: 'zones', label: 'labels', button: 'buttons' };
  var KIND_ICON = { area: 'square', display: 'tv', zone: 'volume', label: 'type', button: 'zap' };
  var ROUTE_LABEL = { room: 'Control4 room selects the source', command: 'Custom command', none: 'No routing' };
  var POWER_LABEL = { room: 'Through the room', device: 'Device on / off', none: 'None' };
  var FEEDBACK_LABEL = { room: 'From the room', none: 'None' };
  var HINT = {
    select: 'Click to select, drag to move. Drag on empty space to select several. Arrow keys nudge.',
    pan: 'Drag to move the view. Wheel or pinch zooms.',
    area: 'Drag on the canvas to draw a room or area.'
  };

  /* View state: kept in memory only, never saved. */
  var st = {
    mode: 'design', tool: 'select', floorId: null, sel: [], views: {},
    layers: { image: true, areas: true, displays: true, zones: true, labels: true, buttons: true },
    grid: true, snap: true, showLeft: null, showRight: null,
    undo: [], redo: [], expect: null,
    previewProfile: '', previewSel: {},
    images: {}, upload: null, temp: {}, band: null, cascade: 0, lastParams: null
  };
  var ui = null, drag = null, pinch = null, pointers = {}, guides = [];
  var mine = false, spaceDown = false, inspTimer = null, lastCommit = { key: null, at: 0 }, libClickGuard = false;

  /* ── small helpers ───────────────────────────────────────────────────── */
  function sv(tag, attrs) {
    var el = document.createElementNS(NS, tag);
    if (attrs) Object.keys(attrs).forEach(function (k) { var v = attrs[k]; if (v === undefined || v === null || v === false) return; el.setAttribute(k, String(v)); });
    for (var i = 2; i < arguments.length; i++) svAdd(el, arguments[i]);
    return el;
  }
  function svAdd(el, c) {
    if (c === undefined || c === null || c === false) return;
    if (Array.isArray(c)) { c.forEach(function (x) { svAdd(el, x); }); return; }
    el.appendChild(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  function num(v, d) { return typeof v === 'number' && isFinite(v) ? v : d; }
  function r1(n) { return Math.round(n * 10) / 10; }
  function clamp(n, lo, hi) { return Math.max(lo, Math.min(hi, n)); }
  function normRot(r) { r = Math.round(num(r, 0)) % 360; return r < 0 ? r + 360 : r; }
  function rotPt(x, y, cx, cy, deg) {
    if (!deg) return { x: x, y: y };
    var a = deg * Math.PI / 180, c = Math.cos(a), s = Math.sin(a), dx = x - cx, dy = y - cy;
    return { x: cx + dx * c - dy * s, y: cy + dx * s + dy * c };
  }
  function aabb(g) {
    var r = normRot(g.rot); if (!r) return { x: g.x, y: g.y, w: g.w, h: g.h };
    var a = r * Math.PI / 180, c = Math.abs(Math.cos(a)), s = Math.abs(Math.sin(a));
    var w = g.w * c + g.h * s, hh = g.w * s + g.h * c;
    return { x: g.x + g.w / 2 - w / 2, y: g.y + g.h / 2 - hh / 2, w: w, h: hh };
  }
  function union(boxes) {
    var x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    boxes.forEach(function (b) { x0 = Math.min(x0, b.x); y0 = Math.min(y0, b.y); x1 = Math.max(x1, b.x + b.w); y1 = Math.max(y1, b.y + b.h); });
    return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
  }
  /* The delta that keeps [pos, pos + size] inside [0, limit] (something larger than the floor sits at 0). */
  function clampDelta(d, pos, size, limit) { var lo = -pos, hi = limit - pos - size; if (lo > hi) return lo; return clamp(d, lo, hi); }
  function fitIn(g, f) { if (!f) return g; var b = aabb(g); g.x += clampDelta(0, b.x, b.w, f.width); g.y += clampDelta(0, b.y, b.h, f.height); return g; }
  function tf(g) { var r = normRot(g.rot); return 'translate(' + r1(g.x) + ' ' + r1(g.y) + ')' + (r ? ' rotate(' + r + ' ' + r1(g.w / 2) + ' ' + r1(g.h / 2) + ')' : ''); }
  function safeColor(c) { return typeof c === 'string' && /^#[0-9a-f]{6}$/i.test(c) ? c : (typeof c === 'string' && /^#[0-9a-f]{3}$/i.test(c) ? '#' + c[1] + c[1] + c[2] + c[2] + c[3] + c[3] : '#60a5fa'); }
  function key(kind, id) { return kind + ':' + id; }
  function limit(name, fallback) { var l = VF.asMap(VF.asMap(VF.asMap(Studio.boot).schema).limits)[name]; return typeof l === 'number' ? l : fallback; }

  var mctx = null;
  function textWidth(text, size, weight) {
    if (mctx === null) { try { mctx = document.createElement('canvas').getContext('2d') || false; } catch (e) { mctx = false; } }
    if (!mctx) return String(text).length * size * 0.58;
    mctx.font = (weight || 600) + ' ' + size + 'px system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif';
    return mctx.measureText(String(text)).width;
  }
  function clip(text, maxW, fs) {
    text = String(text);
    if (textWidth(text, fs) <= maxW) return text;
    while (text.length > 1 && textWidth(text + '…', fs) > maxW) text = text.slice(0, -1);
    return text + '…';
  }
  /* A name fitted into a box: one line, or two when that reads larger. */
  function fitText(text, maxW, maxFs, maxH) {
    text = String(text || '');
    var unit = (textWidth(text, 100) / 100) || 0.5, fs = Math.min(maxFs, maxW / unit);
    if (fs < 9.5 && text.indexOf(' ') > 0 && maxH >= 22) {
      var mid = text.length / 2, at = -1;
      for (var i = 0; i < text.length; i++) { if (text[i] === ' ' && (at < 0 || Math.abs(i - mid) < Math.abs(at - mid))) at = i; }
      var a = text.slice(0, at), b = text.slice(at + 1);
      var fs2 = Math.min(maxFs, maxW / (Math.max(textWidth(a, 100), textWidth(b, 100)) / 100), maxH * 0.36);
      if (fs2 > fs) return { fs: Math.max(fs2, 5), lines: fs2 < 5 ? [clip(a, maxW, 5), clip(b, maxW, 5)] : [a, b] };
    }
    return { fs: Math.max(fs, 5), lines: [fs < 5 ? clip(text, maxW, 5) : text] };
  }

  /* ── the draft, as this section reads it ─────────────────────────────── */
  function C() { return Studio.config(); }
  function listOf(c, kind) {
    if (kind === 'label') return VF.asList(VF.asMap(c.layout).labels);
    if (kind === 'button') return VF.asList(VF.asMap(c.layout).sceneButtons);
    return VF.asList(c[FIELD[kind]]);
  }
  function getObj(c, kind, id) { return VF.byId(listOf(c, kind), id); }
  function hasLayout(o) { var L = o && o.layout; return !!L && typeof L === 'object' && !Array.isArray(L) && typeof L.x === 'number' && typeof L.y === 'number'; }
  function isPlaced(kind, o) { return kind === 'label' || kind === 'button' ? true : hasLayout(o); }
  /* A zone's floor is its own floorId, else its area's floor, else the first floor. */
  function floorOf(c, kind, o) {
    if (kind !== 'zone' || o.floorId) return o.floorId;
    var a = o.areaId ? VF.byId(c.areas, o.areaId) : null; if (a && a.floorId) return a.floorId;
    var fl = VF.asList(c.floors); return fl.length ? fl[0].id : undefined;
  }
  function labelSize(o) { var s = clamp(num(o.size, 16), 6, 200); return { w: Math.max(textWidth(o.text || ' ', s), s * 0.6), h: s * 1.25, size: s }; }
  function geom(kind, o) {
    if (kind === 'label') { var s = labelSize(o); return { x: num(o.x, 0), y: num(o.y, 0), w: s.w, h: s.h, rot: 0 }; }
    if (kind === 'button') return { x: num(o.x, 0), y: num(o.y, 0), w: num(o.w, DEF.button.w), h: num(o.h, DEF.button.h), rot: 0 };
    var L = o.layout, d = DEF[kind];
    return { x: L.x, y: L.y, w: Math.max(1, num(L.w, d.w)), h: Math.max(1, num(L.h, d.h)), rot: kind === 'display' ? normRot(L.rot) : 0 };
  }
  /* Writes position and size only. Nothing else of the entity is touched. */
  function writeGeom(kind, o, g) {
    if (kind === 'label') { o.x = r1(g.x); o.y = r1(g.y); return; }
    if (kind === 'button') { o.x = r1(g.x); o.y = r1(g.y); o.w = r1(g.w); o.h = r1(g.h); return; }
    var L = hasLayout(o) ? o.layout : (o.layout = {});
    L.x = r1(g.x); L.y = r1(g.y); L.w = r1(g.w); L.h = r1(g.h);
    if (kind === 'display') L.rot = normRot(g.rot);
  }
  function isLocked(kind, o) { return kind === 'label' || kind === 'button' ? o.locked === true : !!(o.layout && o.layout.locked === true); }
  function setLocked(kind, o, on) {
    if (kind === 'display') { if (hasLayout(o)) o.layout.locked = !!on; }
    else if (kind === 'label') o.locked = !!on;
    else if (kind === 'button') { if (on) o.locked = true; else delete o.locked; }
    else if (hasLayout(o)) { if (on) o.layout.locked = true; else delete o.layout.locked; }
  }
  function floors() { return Studio.list('floors'); }
  function floor() { return st.floorId ? Studio.find('floors', st.floorId) : null; }
  function gridOf(f) { return Math.max(1, num(f && f.grid, 20)); }
  function placedOn(fid) {
    var c = C(), out = [];
    ['area', 'zone', 'display', 'button', 'label'].forEach(function (kind) {
      listOf(c, kind).forEach(function (o) {
        if (o && o.id && isPlaced(kind, o) && floorOf(c, kind, o) === fid) out.push({ kind: kind, id: o.id, o: o, g: geom(kind, o), locked: isLocked(kind, o) });
      });
    });
    return out;
  }
  function selItems() {
    var c = C(); if (!c || !st.floorId) return [];
    var out = [];
    st.sel.forEach(function (s) {
      var o = getObj(c, s.kind, s.id);
      if (o && isPlaced(s.kind, o) && floorOf(c, s.kind, o) === st.floorId && st.layers[LAYER[s.kind]]) out.push({ kind: s.kind, id: s.id, o: o, g: geom(s.kind, o), locked: isLocked(s.kind, o) });
    });
    return out;
  }
  function isSel(kind, id) { return st.sel.some(function (s) { return s.kind === kind && s.id === id; }); }
  function nameOfItem(kind, o) { return kind === 'label' ? (o.text || 'Label') : kind === 'button' ? Studio.nameOf('scenes', o.sceneId, 'Scene button') : (o.name || o.id); }
  function mapping(d) {
    var route = VF.asMap(d.route), s = route.strategy || 'room', missing = [];
    if ((s === 'room' || d.power === 'room' || d.feedback === 'room') && !d.c4RoomId) missing.push('Control4 room');
    if (d.power === 'device' && !d.c4DeviceId) missing.push('Control4 device');
    if (s === 'command') { var cmd = VF.asMap(route.command); if (!cmd.deviceId || !cmd.name) missing.push('route command'); }
    return { mapped: !missing.length, missing: missing, strategy: s };
  }
  /* The smallest area rectangle of this floor that holds the point. */
  function areaAt(c, fid, x, y) {
    var best = null;
    VF.asList(c.areas).forEach(function (a) {
      if (a.floorId !== fid || !hasLayout(a)) return;
      var g = geom('area', a);
      if (x >= g.x && x <= g.x + g.w && y >= g.y && y <= g.y + g.h && (!best || g.w * g.h < best.size)) best = { area: a, size: g.w * g.h };
    });
    return best ? best.area : null;
  }
  function uniqueName(base, list, start) {
    var names = {}; VF.asList(list).forEach(function (x) { if (x && x.name) names[String(x.name).toLowerCase()] = true; });
    for (var n = start || list.length + 1; ; n++) { var name = base + ' ' + (n < 10 && base === 'TV' ? '0' + n : n); if (!names[name.toLowerCase()]) return name; }
  }

  /* ── changes, undo, redo ─────────────────────────────────────────────── */
  /* One call is one undo step: a snapshot of the whole draft is taken first. */
  function commit(label, fn, opts) {
    opts = opts || {};
    var before = VF.clone(C());
    mine = true;
    try { Studio.update(label, fn, { silent: true, immediate: !!opts.immediate }); } finally { mine = false; }
    var now = Date.now();
    var merge = opts.coalesce && lastCommit.key === opts.coalesce && now - lastCommit.at < 1200 && st.undo.length > 0;
    if (!merge) pushUndo(before);
    st.redo = [];
    lastCommit = { key: opts.coalesce || null, at: now };
    repaint();
  }
  function pushUndo(snapshot) { st.undo.push(snapshot); while (st.undo.length > UNDO_MAX) st.undo.shift(); }
  function restore(label, snapshot) {
    mine = true;
    try { Studio.replace(label, snapshot, { silent: true }); } finally { mine = false; }
    lastCommit = { key: null, at: 0 };
    repaint();
  }
  function undo() { if (!st.undo.length || drag) return; var snap = st.undo.pop(); st.redo.push(VF.clone(C())); restore('Undo', snap); }
  function redo() { if (!st.redo.length || drag) return; var snap = st.redo.pop(); pushUndo(VF.clone(C())); restore('Redo', snap); }
  /* A change made anywhere else (another section, a reload) makes our snapshots stale: drop them.
     The exception is a delete we asked the shell for, which becomes one undo step. */
  if (typeof Studio.on === 'function') {
    Studio.on('config', function () {
      if (mine) return;
      if (st.expect) { pushUndo(st.expect); st.redo = []; st.expect = null; } else { st.undo = []; st.redo = []; }
    });
    Studio.on('boot', function () { st.undo = []; st.redo = []; st.expect = null; });
  }
  function edit(it, label, fn, opts) { commit(label, function (c) { var o = getObj(c, it.kind, it.id); if (o) fn(o, c); }, opts); }
  function editGeom(it, label, fn) {
    commit(label, function (c) {
      var o = getObj(c, it.kind, it.id); if (!o || !isPlaced(it.kind, o)) return;
      var g = geom(it.kind, o); fn(g);
      writeGeom(it.kind, o, fitIn(g, VF.byId(c.floors, st.floorId)));
    });
  }

  /* ── view: zoom, pan, fit ────────────────────────────────────────────── */
  function view() { return st.views[st.floorId] || (st.views[st.floorId] = { k: 1, x: 60, y: 60, auto: true }); }
  function stageSize() { return ui ? { w: ui.stage.clientWidth, h: ui.stage.clientHeight } : { w: 0, h: 0 }; }
  function fit() {
    var f = floor(), s = stageSize(); if (!f || s.w < 80 || s.h < 80) return false;
    var r = st.mode === 'design' ? RULER : 0, pad = 26, v = view();
    var k = clamp(Math.min((s.w - r - pad * 2) / f.width, (s.h - r - STATUS - pad * 2) / f.height), MINK, MAXK);
    v.k = k; v.x = r + (s.w - r - f.width * k) / 2; v.y = r + (s.h - r - STATUS - f.height * k) / 2; v.auto = true;
    return true;
  }
  function zoomAt(sx, sy, k) {
    var v = view(); k = clamp(k, MINK, MAXK);
    var wx = (sx - v.x) / v.k, wy = (sy - v.y) / v.k;
    v.k = k; v.x = sx - wx * k; v.y = sy - wy * k; v.auto = false;
    applyView();
  }
  function zoomBy(factor) { var s = stageSize(); zoomAt(s.w / 2, s.h / 2, view().k * factor); }
  function toWorld(e) {
    var r = ui.svg.getBoundingClientRect(), v = view();
    return { x: (e.clientX - r.left - v.x) / v.k, y: (e.clientY - r.top - v.y) / v.k, sx: e.clientX - r.left, sy: e.clientY - r.top };
  }
  function viewCentre() {
    var s = stageSize(), v = view(), f = floor();
    var x = (s.w / 2 - v.x) / v.k, y = ((s.h - STATUS) / 2 - v.y) / v.k;
    if (f) { x = clamp(x, 0, f.width); y = clamp(y, 0, f.height); }
    return { x: x, y: y };
  }
  function applyView() {
    if (!ui) return;
    var v = view(), f = floor();
    ui.world.setAttribute('transform', 'translate(' + r1(v.x) + ' ' + r1(v.y) + ') scale(' + v.k + ')');
    if (f) {
      var g = gridOf(f);
      setPattern(ui.patA, g, v.k); setPattern(ui.patB, g * 5, v.k);
      if (ui.gridA) ui.gridA.setAttribute('visibility', g * v.k >= 7 ? 'visible' : 'hidden');
      if (ui.gridB) ui.gridB.setAttribute('visibility', g * 5 * v.k >= 7 ? 'visible' : 'hidden');
    }
    if (ui.zoomLabel) ui.zoomLabel.textContent = Math.round(v.k * 100) + '%';
    paintRulers(); paintOverlay();
  }
  function setPattern(pat, size, k) {
    pat.setAttribute('width', size); pat.setAttribute('height', size);
    pat.firstChild.setAttribute('d', 'M ' + size + ' 0 H 0 V ' + size);
    pat.firstChild.setAttribute('stroke-width', 1 / k);
  }

  /* ── drawing the floor ───────────────────────────────────────────────── */
  function previewAccess() {
    var p = st.previewProfile ? Studio.find('profiles', st.previewProfile) : null;
    if (!p) return { all: true, floor: function () { return true; }, area: function () { return true; }, zone: function () { return true; }, scene: function () { return true; } };
    var perms = VF.asMap(p.permissions);
    function allows(scope, id) { return scope === 'all' || (Array.isArray(scope) && scope.indexOf(id) >= 0); }
    var acc = { profile: p };
    acc.floor = function (id) { return allows(perms.floors, id); };
    acc.area = function (id) { return id === undefined || id === null || allows(perms.areas, id); };
    acc.zone = function (z) { return allows(perms.zones, z.id) && acc.area(z.areaId); };
    acc.scene = function (id) { return perms.scenes === true && allows(perms.sceneIds, id); };
    return acc;
  }
  function sampleSource(d) {
    var c = C(), src = d.defaultSourceId ? VF.byId(c.sources, d.defaultSourceId) : null;
    if (!src && Array.isArray(d.sources) && d.sources.length) src = VF.byId(c.sources, d.sources[0]);
    if (!src) src = VF.asList(c.sources).filter(function (s) { return s.video !== false; })[0];
    return src ? src.name : 'No source';
  }
  function centredText(cls, x, y, fs, text) { return sv('text', { class: cls, x: r1(x), y: r1(y), 'font-size': r1(fs), 'text-anchor': 'middle' }, text); }
  function drawDisplay(d, g, pv) {
    var kind = d.kind === 'projector' || d.kind === 'videowall' ? d.kind : 'tv';
    var hidden = !!(d.layout && d.layout.hidden === true), m = mapping(d);
    var node = sv('g', { class: 'ld-obj ld-display ld-' + kind + (hidden ? ' is-hidden' : '') + (pv && st.previewSel[d.id] ? ' on' : ''), 'data-kind': 'display', 'data-id': d.id, transform: tf(g) });
    node.appendChild(sv('rect', { class: 'ld-body', x: 0, y: 0, width: g.w, height: g.h, rx: Math.min(7, g.h / 5, g.w / 5) }));
    var padL = 0;
    if (kind === 'tv') { var sh = Math.min(3, g.h * 0.08); node.appendChild(sv('rect', { class: 'ld-mark', x: g.w * 0.34, y: g.h - sh - 2, width: g.w * 0.32, height: sh, rx: sh / 2 })); }
    if (kind === 'projector') { var lr = Math.min(g.h * 0.22, g.w * 0.12, 10); padL = lr * 2 + 6; node.appendChild(sv('circle', { class: 'ld-lens', cx: lr + 6, cy: g.h / 2, r: lr })); node.appendChild(sv('circle', { class: 'ld-mark', cx: lr + 6, cy: g.h / 2, r: lr * 0.4 })); }
    if (kind === 'videowall') node.appendChild(sv('path', { class: 'ld-split', d: 'M ' + r1(g.w / 2) + ' 2 V ' + r1(g.h - 2) + ' M 2 ' + r1(g.h / 2) + ' H ' + r1(g.w - 2) }));
    var flip = g.rot > 90 && g.rot <= 270;
    var tg = sv('g', flip ? { transform: 'rotate(180 ' + r1(g.w / 2) + ' ' + r1(g.h / 2) + ')' } : null);
    var cx = flip ? (g.w - padL) / 2 : padL + (g.w - padL) / 2, availW = Math.max(8, g.w - padL - 10);
    if (pv) {
      var nf = Math.min(13, g.h * 0.3, availW / ((textWidth(d.name || d.id, 100, 700) / 100) || 0.5));
      var cf = Math.max(4, Math.min(9.5, g.h * 0.22));
      tg.appendChild(centredText('ld-name', cx, g.h * 0.44, Math.max(nf, 5), nf < 5 ? clip(d.name || d.id, availW, 5) : (d.name || d.id)));
      tg.appendChild(centredText('ld-cap', cx, g.h * 0.44 + cf * 1.45, cf, clip(sampleSource(d), availW, cf)));
    } else {
      var ft = fitText(d.name || d.id, availW, Math.min(20, g.h * 0.44), g.h);
      var lh = ft.fs * 1.15, y0 = g.h / 2 - (ft.lines.length - 1) * lh / 2 + ft.fs * 0.34 - (kind === 'tv' ? 1 : 0);
      ft.lines.forEach(function (line, i) { tg.appendChild(centredText('ld-name', cx, y0 + i * lh, ft.fs, line)); });
    }
    node.appendChild(tg);
    if (!pv) {
      if (!m.mapped) node.appendChild(sv('circle', { class: 'ld-badge', cx: g.w - 6, cy: 6, r: Math.min(4, g.h / 6) }, sv('title', null, 'Not mapped to Control4 yet')));
      if (isLocked('display', d)) node.appendChild(sv('path', { class: 'ld-ico', d: VF.ICONS.lock, transform: 'translate(3 2.5) scale(' + r1(Math.min(0.42, g.h / 60)) + ')' }));
      node.appendChild(sv('title', null, (d.name || d.id) + (hidden ? ' (hidden from operators)' : '') + (m.mapped ? '' : ' (not mapped yet)')));
    }
    return node;
  }
  function drawZone(z, g, pv) {
    var node = sv('g', { class: 'ld-obj ld-zone', 'data-kind': 'zone', 'data-id': z.id, transform: tf(g) });
    node.appendChild(sv('rect', { class: 'ld-body', x: 0, y: 0, width: g.w, height: g.h, rx: Math.min(g.h / 2, g.w / 2) }));
    var is = clamp(g.h * 0.5, 8, 24), ix = Math.min(g.h * 0.3, 16);
    node.appendChild(sv('path', { class: 'ld-ico', d: VF.ICONS.volume, transform: 'translate(' + r1(ix) + ' ' + r1((g.h - is) / 2) + ') scale(' + (is / 24) + ')' }));
    var tx = ix + is + 6, availW = Math.max(8, g.w - tx - Math.min(g.h * 0.3, 14));
    var fs = Math.min(15, g.h * 0.36, availW / ((textWidth(z.name || z.id, 100) / 100) || 0.5));
    node.appendChild(sv('text', { class: 'ld-name', x: r1(tx), y: r1(g.h / 2 + Math.max(fs, 5) * 0.34), 'font-size': r1(Math.max(fs, 5)) }, fs < 5 ? clip(z.name || z.id, availW, 5) : (z.name || z.id)));
    if (!pv && isLocked('zone', z)) node.appendChild(sv('path', { class: 'ld-ico', d: VF.ICONS.lock, transform: 'translate(' + r1(g.w - 16) + ' 2) scale(0.42)' }));
    return node;
  }
  function drawArea(a, g, pv) {
    var color = safeColor(a.color), fs = 13, name = a.name || a.id;
    var node = sv('g', { class: 'ld-obj ld-area', 'data-kind': 'area', 'data-id': a.id, transform: tf(g) });
    node.appendChild(sv('rect', { class: 'ld-body', x: 0, y: 0, width: g.w, height: g.h, rx: 6, fill: color, stroke: color }));
    var tw = Math.min(g.w, textWidth(name, fs, 650) + 16 + (!pv && isLocked('area', a) ? 14 : 0));
    var tag = sv('g', { class: 'ld-tag', 'data-grip': '1' });
    if (!pv) tag.appendChild(sv('rect', { x: 0, y: 0, width: r1(tw), height: 22, rx: 6, fill: color }));
    tag.appendChild(sv('text', { class: 'ld-name', x: 8, y: 15.5, 'font-size': fs, fill: color }, clip(name, Math.max(10, g.w - 16), fs)));
    if (!pv && isLocked('area', a)) tag.appendChild(sv('path', { class: 'ld-ico', d: VF.ICONS.lock, stroke: color, transform: 'translate(' + r1(tw - 16) + ' 5) scale(0.5)' }));
    node.appendChild(tag);
    return node;
  }
  function drawLabel(l, g) {
    var s = labelSize(l);
    var node = sv('g', { class: 'ld-obj ld-label', 'data-kind': 'label', 'data-id': l.id, transform: tf(g) });
    node.appendChild(sv('rect', { class: 'ld-hit', x: -3, y: -2, width: r1(g.w + 6), height: r1(g.h + 4), rx: 3 }));
    node.appendChild(sv('text', { class: 'ld-name', x: 0, y: r1(s.size * 0.98), 'font-size': s.size }, l.text || ''));
    return node;
  }
  function drawButton(b, g) {
    var scene = Studio.find('scenes', b.sceneId), name = scene ? scene.name : 'Scene missing';
    var node = sv('g', { class: 'ld-obj ld-sb' + (scene ? '' : ' is-missing'), 'data-kind': 'button', 'data-id': b.id, transform: tf(g) });
    node.appendChild(sv('rect', { class: 'ld-body', x: 0, y: 0, width: g.w, height: g.h, rx: Math.min(10, g.h / 3) }));
    var is = clamp(g.h * 0.42, 8, 20), ix = Math.min(10, g.h * 0.25);
    node.appendChild(sv('path', { class: 'ld-ico', d: VF.ICONS[VF.SCENE_ICON[scene && scene.icon] || 'zap'], transform: 'translate(' + r1(ix) + ' ' + r1((g.h - is) / 2) + ') scale(' + (is / 24) + ')' }));
    var tx = ix + is + 6, availW = Math.max(8, g.w - tx - 8);
    var fs = Math.min(14, g.h * 0.36, availW / ((textWidth(name, 100) / 100) || 0.5));
    node.appendChild(sv('text', { class: 'ld-name', x: r1(tx), y: r1(g.h / 2 + Math.max(fs, 5) * 0.34), 'font-size': r1(Math.max(fs, 5)) }, fs < 5 ? clip(name, availW, 5) : name));
    return node;
  }
  function drawObject(kind, o, g, pv) {
    if (kind === 'display') return drawDisplay(o, g, pv);
    if (kind === 'zone') return drawZone(o, g, pv);
    if (kind === 'area') return drawArea(o, g, pv);
    if (kind === 'label') return drawLabel(o, g);
    return drawButton(o, g);
  }
  function imageFor(k) {
    var v = st.images[k];
    if (typeof v === 'string') return v;
    if (!v) {
      st.images[k] = { loading: true };
      VF.api('IMAGE_GET', { key: k }, { since: false }).then(function (r) {
        var url = r.ok && r.data ? r.data.dataUrl : null;
        if (typeof url === 'string' && /^data:image\/(png|jpeg|webp);base64,/.test(url)) {
          st.images[k] = url;
          if (ui && ui.imgNode && ui.imgNode.getAttribute('data-key') === k) ui.imgNode.setAttribute('href', url);
        } else st.images[k] = { missing: true, message: r.message || 'The picture could not be loaded.' };
        paintInspectorSoon();
      });
    }
    return null;
  }
  function paintScene() {
    if (!ui) return;
    VF.clear(ui.world); ui.nodes = {}; ui.imgNode = null; ui.gridA = null; ui.gridB = null;
    var f = floor(), pv = st.mode === 'preview', acc = pv ? previewAccess() : null;
    ui.svg.setAttribute('class', 'ld-svg ' + (pv ? 'ld-pv' : 'ld-design tool-' + st.tool));
    var blocked = !f ? 'nofloor' : (pv && !acc.floor(f.id) ? 'noaccess' : null);
    paintMessage(blocked, acc);
    ui.pvCounts = { shown: 0, total: 0, hidden: 0 };
    if (!f || blocked) return;
    ui.world.appendChild(sv('rect', { class: 'ld-floor', x: 0, y: 0, width: f.width, height: f.height }));
    var img = VF.asMap(f.image);
    if (img.key && st.layers.image) {
      ui.imgNode = sv('image', { class: 'ld-img', x: 0, y: 0, width: f.width, height: f.height, preserveAspectRatio: 'xMidYMid meet', 'data-key': img.key });
      var data = imageFor(img.key); if (data) ui.imgNode.setAttribute('href', data);
      ui.world.appendChild(ui.imgNode);
    }
    if (!pv && st.grid) {
      ui.gridA = sv('rect', { class: 'ld-gridrect', x: 0, y: 0, width: f.width, height: f.height, fill: 'url(#ld-grid-a)' });
      ui.gridB = sv('rect', { class: 'ld-gridrect', x: 0, y: 0, width: f.width, height: f.height, fill: 'url(#ld-grid-b)' });
      ui.world.appendChild(ui.gridA); ui.world.appendChild(ui.gridB);
    }
    ui.world.appendChild(sv('rect', { class: 'ld-edge', x: 0, y: 0, width: f.width, height: f.height }));
    placedOn(f.id).forEach(function (it) {
      if (!st.layers[LAYER[it.kind]]) return;
      if (pv) {
        if (it.kind === 'display') {
          ui.pvCounts.total++;
          if (it.o.layout.hidden === true) { ui.pvCounts.hidden++; return; }
          if (!acc.area(it.o.areaId)) return;
          ui.pvCounts.shown++;
        }
        if (it.kind === 'area' && !acc.area(it.id)) return;
        if (it.kind === 'zone' && !acc.zone(it.o)) return;
        if (it.kind === 'button' && (!acc.scene(it.o.sceneId) || !Studio.find('scenes', it.o.sceneId))) return;
      }
      var node = drawObject(it.kind, it.o, st.temp[key(it.kind, it.id)] || it.g, pv);
      ui.nodes[key(it.kind, it.id)] = node;
      ui.world.appendChild(node);
    });
  }
  function paintMessage(blocked, acc) {
    if (!blocked) { ui.msg.classList.add('hidden'); return; }
    ui.msg.classList.remove('hidden');
    if (blocked === 'nofloor') VF.mount(ui.msg, h('p', 'This venue has no floor yet.'), h('button.btn.primary', { type: 'button', onclick: addFloor }, icon('plus'), 'Add a floor'));
    else VF.mount(ui.msg, icon('eye-off', 'lg'), h('p', 'The ' + acc.profile.name + ' profile cannot see this floor.'), h('p.small.muted', 'Its visible floors are set in Staff Profiles.'));
  }
  function niceStep(raw) { var p = Math.pow(10, Math.floor(Math.log(raw) / Math.LN10)), n = raw / p; return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10) * p; }
  function paintRulers() {
    if (!ui) return; VF.clear(ui.rul);
    if (st.mode !== 'design' || !floor()) return;
    var s = stageSize(), v = view(), step = niceStep(70 / v.k), minor = step / 5, d = '', i, u, p;
    ui.rul.appendChild(sv('rect', { class: 'ld-rbg', x: 0, y: 0, width: s.w, height: RULER }));
    ui.rul.appendChild(sv('rect', { class: 'ld-rbg', x: 0, y: 0, width: RULER, height: s.h }));
    for (i = Math.ceil((RULER - v.x) / v.k / minor); (p = v.x + (u = i * minor) * v.k) < s.w; i++) {
      var major = i % 5 === 0;
      d += 'M' + r1(p) + ' ' + RULER + 'V' + (major ? 9 : 16);
      if (major) ui.rul.appendChild(sv('text', { class: 'ld-rt', x: r1(p + 3), y: 10 }, String(Math.round(u))));
    }
    for (i = Math.ceil((RULER - v.y) / v.k / minor); (p = v.y + (u = i * minor) * v.k) < s.h; i++) {
      var maj = i % 5 === 0;
      d += 'M' + RULER + ' ' + r1(p) + 'H' + (maj ? 9 : 16);
      if (maj) ui.rul.appendChild(sv('text', { class: 'ld-rt', x: 10, y: r1(p + 3), transform: 'rotate(-90 10 ' + r1(p + 3) + ')', 'text-anchor': 'end' }, String(Math.round(u))));
    }
    ui.rul.appendChild(sv('path', { class: 'ld-rk', d: d }));
    ui.rul.appendChild(sv('rect', { class: 'ld-rbg corner', x: 0, y: 0, width: RULER, height: RULER }));
  }
  function corners(g) {
    var cx = g.x + g.w / 2, cy = g.y + g.h / 2;
    return [[g.x, g.y], [g.x + g.w, g.y], [g.x + g.w, g.y + g.h], [g.x, g.y + g.h]].map(function (p) { return rotPt(p[0], p[1], cx, cy, g.rot); });
  }
  function paintOverlay() {
    if (!ui) return; VF.clear(ui.over);
    var f = floor(); if (st.mode !== 'design' || !f) return;
    var v = view();
    function sx(x) { return r1(v.x + x * v.k); } function sy(y) { return r1(v.y + y * v.k); }
    guides.forEach(function (gd) {
      ui.over.appendChild(gd.axis === 'x' ? sv('line', { class: 'ld-guide', x1: sx(gd.at), y1: sy(0), x2: sx(gd.at), y2: sy(f.height) }) : sv('line', { class: 'ld-guide', x1: sx(0), y1: sy(gd.at), x2: sx(f.width), y2: sy(gd.at) }));
    });
    var items = selItems();
    items.forEach(function (it) {
      var g = st.temp[key(it.kind, it.id)] || it.g;
      ui.over.appendChild(sv('polygon', { class: 'ld-selbox' + (it.locked ? ' locked' : ''), points: corners(g).map(function (p) { return sx(p.x) + ',' + sy(p.y); }).join(' ') }));
    });
    if (items.length === 1 && !items[0].locked && items[0].kind !== 'label' && !(drag && drag.type === 'move' && drag.moved)) {
      var it = items[0], g = st.temp[key(it.kind, it.id)] || it.g, cx = g.x + g.w / 2, cy = g.y + g.h / 2, sw = g.w * v.k, shh = g.h * v.k;
      var hit = clamp(Math.min(sw, shh) / 3.2, 6, 16);
      [[-1, -1], [0, -1], [1, -1], [1, 0], [1, 1], [0, 1], [-1, 1], [-1, 0]].forEach(function (hd) {
        if (hd[0] === 0 && sw < 40) return; if (hd[1] === 0 && shh < 40) return;
        var w = rotPt(cx + hd[0] * g.w / 2, cy + hd[1] * g.h / 2, cx, cy, g.rot), px = v.x + w.x * v.k, py = v.y + w.y * v.k;
        ui.over.appendChild(sv('g', { class: 'ld-h', 'data-handle': hd[0] + ',' + hd[1] },
          sv('circle', { class: 'ld-hhit', cx: r1(px), cy: r1(py), r: hit }), sv('rect', { class: 'ld-hbox', x: r1(px - 4.5), y: r1(py - 4.5), width: 9, height: 9, rx: 2 })));
      });
      if (it.kind === 'display') {
        var a = rotPt(cx, g.y, cx, cy, g.rot), b = rotPt(cx, g.y - 28 / v.k, cx, cy, g.rot);
        ui.over.appendChild(sv('line', { class: 'ld-rotline', x1: sx(a.x), y1: sy(a.y), x2: sx(b.x), y2: sy(b.y) }));
        ui.over.appendChild(sv('g', { class: 'ld-h rot', 'data-handle': 'rot' }, sv('circle', { class: 'ld-hhit', cx: sx(b.x), cy: sy(b.y), r: 16 }), sv('circle', { class: 'ld-hrot', cx: sx(b.x), cy: sy(b.y), r: 6 }), sv('title', null, 'Rotate')));
      }
    }
    if (st.band) ui.over.appendChild(sv('rect', { class: 'ld-band ' + st.band.kind, x: sx(st.band.x), y: sy(st.band.y), width: r1(st.band.w * v.k), height: r1(st.band.h * v.k) }));
  }

  /* ── selection ───────────────────────────────────────────────────────── */
  function setSel(list) { st.sel = list; paintOverlay(); paintLeftSel(); paintInspectorSoon(); paintStatus(); }
  function toggleSel(kind, id) { setSel(isSel(kind, id) ? st.sel.filter(function (s) { return !(s.kind === kind && s.id === id); }) : st.sel.concat([{ kind: kind, id: id }])); }
  function pruneState() {
    var fl = floors();
    if (!VF.byId(fl, st.floorId)) st.floorId = fl.length ? fl[0].id : null;
    var keep = selItems().map(function (it) { return key(it.kind, it.id); });
    st.sel = st.sel.filter(function (s) { return keep.indexOf(key(s.kind, s.id)) >= 0; });
    if (st.previewProfile && !Studio.find('profiles', st.previewProfile)) st.previewProfile = '';
  }

  /* ── pointer work on the canvas ──────────────────────────────────────── */
  function touchIds() { return Object.keys(pointers).filter(function (id) { return pointers[id].type === 'touch'; }); }
  function blurField() { var a = document.activeElement; if (a && ui && ui.root.contains(a) && a !== ui.svg && /^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName)) { try { a.blur(); } catch (e) { /* ignore */ } } }
  function snapTo(n, f) { var g = gridOf(f); return Math.round(n / g) * g; }
  function guideLines(exclude) {
    var f = floor(), xs = [0, f.width / 2, f.width], ys = [0, f.height / 2, f.height];
    placedOn(f.id).forEach(function (it) {
      if (it.kind === 'label' || !st.layers[LAYER[it.kind]] || exclude[key(it.kind, it.id)]) return;
      var b = aabb(it.g); xs.push(b.x, b.x + b.w / 2, b.x + b.w); ys.push(b.y, b.y + b.h / 2, b.y + b.h);
    });
    return { x: xs, y: ys };
  }
  function nearest(lines, edges, d, tol) {
    var best = null;
    edges.forEach(function (e) { lines.forEach(function (l) { var diff = l - (e + d); if (Math.abs(diff) <= tol && (!best || Math.abs(diff) < Math.abs(best.diff))) best = { diff: diff, at: l }; }); });
    return best;
  }
  function startPinch(ids) {
    var a = pointers[ids[0]], b = pointers[ids[1]], r = ui.svg.getBoundingClientRect(), v = view();
    pinch = { ids: ids, d0: Math.hypot(a.x - b.x, a.y - b.y) || 1, mx0: (a.x + b.x) / 2 - r.left, my0: (a.y + b.y) / 2 - r.top, v0: { k: v.k, x: v.x, y: v.y } };
  }
  function doPinch() {
    var a = pointers[pinch.ids[0]], b = pointers[pinch.ids[1]]; if (!a || !b) return;
    var r = ui.svg.getBoundingClientRect(), v = view(), v0 = pinch.v0;
    var k = clamp(v0.k * (Math.hypot(a.x - b.x, a.y - b.y) || 1) / pinch.d0, MINK, MAXK);
    var mx = (a.x + b.x) / 2 - r.left, my = (a.y + b.y) / 2 - r.top;
    v.k = k; v.x = mx - (pinch.mx0 - v0.x) / v0.k * k; v.y = my - (pinch.my0 - v0.y) / v0.k * k; v.auto = false;
    applyView();
  }
  function cancelDrag() {
    if (!drag) return;
    drag = null; st.temp = {}; st.band = null; guides = [];
    if (ui) { ui.svg.classList.remove('panning'); paintScene(); paintOverlay(); }
  }
  function onDown(e) {
    if (!ui) return;
    pointers[e.pointerId] = { x: e.clientX, y: e.clientY, type: e.pointerType };
    var touches = touchIds();
    if (touches.length === 2) { cancelDrag(); startPinch(touches); return; }
    if (drag || pinch) return;
    if (e.pointerType === 'mouse' && e.button !== 0 && e.button !== 1) return;
    if (e.button === 1) e.preventDefault();
    blurField();
    try { ui.svg.setPointerCapture(e.pointerId); } catch (err) { /* ignore */ }
    try { ui.svg.focus({ preventScroll: true }); } catch (err) { /* ignore */ }
    var f = floor(); if (!f) return;
    var p = toWorld(e), t = e.target, v = view();
    var objEl = t.closest ? t.closest('[data-kind]') : null;
    var base = { pid: e.pointerId, cx: e.clientX, cy: e.clientY, p0: p, moved: false };
    if (st.mode === 'preview') { drag = Object.assign(base, { type: 'pan', v0: { x: v.x, y: v.y }, tap: objEl && objEl.getAttribute('data-kind') === 'display' ? objEl.getAttribute('data-id') : null }); return; }
    if (st.tool === 'pan' || e.button === 1 || spaceDown) { drag = Object.assign(base, { type: 'pan', v0: { x: v.x, y: v.y } }); ui.svg.classList.add('panning'); return; }
    if (st.tool === 'area') {
      var ax = clamp(st.snap ? snapTo(p.x, f) : p.x, 0, f.width), ay = clamp(st.snap ? snapTo(p.y, f) : p.y, 0, f.height);
      drag = Object.assign(base, { type: 'draw', ax: ax, ay: ay }); return;
    }
    var hEl = t.closest ? t.closest('[data-handle]') : null;
    if (hEl) {
      var one = selItems()[0]; if (!one || one.locked) return;
      var hd = hEl.getAttribute('data-handle');
      if (hd === 'rot') drag = Object.assign(base, { type: 'rotate', it: one, g0: one.g });
      else { var parts = hd.split(','); drag = Object.assign(base, { type: 'resize', it: one, g0: one.g, hx: Number(parts[0]), hy: Number(parts[1]) }); }
      return;
    }
    if (objEl) {
      var kind = objEl.getAttribute('data-kind'), id = objEl.getAttribute('data-id'), was = isSel(kind, id);
      if (e.shiftKey) { toggleSel(kind, id); return; }
      /* An area fills most of a floor: dragging across one that is not selected draws a marquee;
         a click selects it, and its name tag (or a second drag) moves it. */
      if (kind === 'area' && !was && !(t.closest && t.closest('[data-grip]'))) { drag = Object.assign(base, { type: 'marquee', click: { kind: kind, id: id } }); return; }
      if (!was) setSel([{ kind: kind, id: id }]);
      var all = selItems(), prim = all.filter(function (x) { return x.kind === kind && x.id === id; })[0];
      if (!prim || prim.locked) { drag = Object.assign(base, { type: 'none' }); return; }
      var items = all.filter(function (x) { return !x.locked; }), ex = {};
      items.forEach(function (x) { ex[key(x.kind, x.id)] = true; });
      drag = Object.assign(base, { type: 'move', items: items.map(function (x) { return { kind: x.kind, id: x.id, g0: x.g }; }), prim: aabb(prim.g), box: union(items.map(function (x) { return aabb(x.g); })), lines: guideLines(ex), single: was && st.sel.length > 1 ? { kind: kind, id: id } : null, dx: 0, dy: 0 });
      return;
    }
    drag = Object.assign(base, { type: 'marquee', add: e.shiftKey });
  }
  function onMove(e) {
    if (!ui) return;
    if (pointers[e.pointerId]) { pointers[e.pointerId].x = e.clientX; pointers[e.pointerId].y = e.clientY; }
    if (pinch) { doPinch(); return; }
    var p = toWorld(e), f = floor();
    if (ui.coords && f) ui.coords.textContent = 'X ' + Math.round(p.x) + '   Y ' + Math.round(p.y);
    if (!drag || drag.pid !== e.pointerId || !f) return;
    if (!drag.moved) { if (Math.hypot(e.clientX - drag.cx, e.clientY - drag.cy) < 4) return; drag.moved = true; }
    var v = view(), d = drag;
    if (d.type === 'pan') { v.x = d.v0.x + (e.clientX - d.cx); v.y = d.v0.y + (e.clientY - d.cy); v.auto = false; applyView(); return; }
    if (d.type === 'move') {
      var dx = (e.clientX - d.cx) / v.k, dy = (e.clientY - d.cy) / v.k, tol = 5 / v.k, b = d.prim;
      if (st.snap && !e.altKey) {
        /* Snap on: the grid decides. */
        dx = snapTo(b.x + dx, f) - b.x; dy = snapTo(b.y + dy, f) - b.y;
      } else if (!e.altKey) {
        /* Snap off: free, but an edge or centre close to another object's lines up with it (Alt: fully free). */
        var gx = Math.abs(dx) * v.k > 3 ? nearest(d.lines.x, [b.x, b.x + b.w / 2, b.x + b.w], dx, tol) : null;
        var gy = Math.abs(dy) * v.k > 3 ? nearest(d.lines.y, [b.y, b.y + b.h / 2, b.y + b.h], dy, tol) : null;
        if (gx) dx += gx.diff; if (gy) dy += gy.diff;
      }
      dx = clampDelta(dx, d.box.x, d.box.w, f.width); dy = clampDelta(dy, d.box.y, d.box.h, f.height);
      d.dx = dx; d.dy = dy; guides = [];
      var ax = nearest(d.lines.x, [b.x, b.x + b.w / 2, b.x + b.w], dx, 0.05), ay = nearest(d.lines.y, [b.y, b.y + b.h / 2, b.y + b.h], dy, 0.05);
      if (ax) guides.push({ axis: 'x', at: ax.at }); if (ay) guides.push({ axis: 'y', at: ay.at });
      d.items.forEach(function (it) {
        var g = Object.assign({}, it.g0, { x: it.g0.x + dx, y: it.g0.y + dy }), k = key(it.kind, it.id);
        st.temp[k] = g; if (ui.nodes[k]) ui.nodes[k].setAttribute('transform', tf(g));
      });
      paintOverlay(); return;
    }
    if (d.type === 'resize' || d.type === 'rotate') {
      var g2 = d.type === 'resize' ? resizeGeom(d.g0, d.hx, d.hy, p, st.snap && !e.altKey, f) : rotateGeom(d.g0, p, st.snap && !e.shiftKey, f);
      if (!g2) return;
      var k2 = key(d.it.kind, d.it.id), old = ui.nodes[k2];
      st.temp[k2] = g2;
      if (old && d.type === 'rotate') old.setAttribute('transform', tf(g2));
      else if (old) { var fresh = drawObject(d.it.kind, d.it.o, g2, false); old.parentNode.replaceChild(fresh, old); ui.nodes[k2] = fresh; }
      if (ui.coords) ui.coords.textContent = d.type === 'rotate' ? g2.rot + '°' : Math.round(g2.w) + ' x ' + Math.round(g2.h);
      paintOverlay(); return;
    }
    if (d.type === 'marquee' || d.type === 'draw') {
      var x0 = d.type === 'draw' ? d.ax : d.p0.x, y0 = d.type === 'draw' ? d.ay : d.p0.y, x1 = p.x, y1 = p.y;
      if (d.type === 'draw') { x1 = clamp(st.snap ? snapTo(x1, f) : x1, 0, f.width); y1 = clamp(st.snap ? snapTo(y1, f) : y1, 0, f.height); }
      st.band = { kind: d.type, x: Math.min(x0, x1), y: Math.min(y0, y1), w: Math.abs(x1 - x0), h: Math.abs(y1 - y0) };
      paintOverlay();
    }
  }
  function resizeGeom(g0, hx, hy, p, snap, f) {
    var rot = normRot(g0.rot), cx = g0.x + g0.w / 2, cy = g0.y + g0.h / 2, grid = gridOf(f);
    var q = rotPt(p.x, p.y, cx, cy, -rot), min = snap ? Math.max(4, Math.min(grid, 20)) : 4;
    var l = g0.x, t = g0.y, r = g0.x + g0.w, b = g0.y + g0.h;
    function sn(n) { return snap && !rot ? Math.round(n / grid) * grid : n; }
    if (hx < 0) l = Math.min(sn(q.x), r - min); if (hx > 0) r = Math.max(sn(q.x), l + min);
    if (hy < 0) t = Math.min(sn(q.y), b - min); if (hy > 0) b = Math.max(sn(q.y), t + min);
    if (snap && rot) {
      var w2 = Math.max(min, Math.round((r - l) / grid) * grid), h2 = Math.max(min, Math.round((b - t) / grid) * grid);
      if (hx < 0) l = r - w2; else if (hx > 0) r = l + w2;
      if (hy < 0) t = b - h2; else if (hy > 0) b = t + h2;
    }
    if (!rot) { l = Math.max(0, l); t = Math.max(0, t); r = Math.min(f.width, r); b = Math.min(f.height, b); }
    var w = r - l, hh = b - t, c = rotPt((l + r) / 2, (t + b) / 2, cx, cy, rot);
    var g = { x: c.x - w / 2, y: c.y - hh / 2, w: w, h: hh, rot: g0.rot };
    if (rot) { var box = aabb(g); if (box.x < -0.01 || box.y < -0.01 || box.x + box.w > f.width + 0.01 || box.y + box.h > f.height + 0.01) return null; }
    return g;
  }
  function rotateGeom(g0, p, snap, f) {
    var cx = g0.x + g0.w / 2, cy = g0.y + g0.h / 2;
    var deg = Math.atan2(p.y - cy, p.x - cx) * 180 / Math.PI + 90;
    if (snap) deg = Math.round(deg / 15) * 15;
    return fitIn({ x: g0.x, y: g0.y, w: g0.w, h: g0.h, rot: normRot(deg) }, f);
  }
  function onUp(e) {
    delete pointers[e.pointerId];
    if (!ui) return;
    try { ui.svg.releasePointerCapture(e.pointerId); } catch (err) { /* ignore */ }
    if (pinch) { if (touchIds().length < 2) pinch = null; return; }
    var d = drag; if (!d || d.pid !== e.pointerId) return;
    drag = null; ui.svg.classList.remove('panning');
    var temp = st.temp, f = floor(); st.temp = {}; guides = []; var band = st.band; st.band = null;
    if (e.type === 'pointercancel' || !f) { paintScene(); paintOverlay(); return; }
    if (d.type === 'pan') {
      if (!d.moved && d.tap) { if (st.previewSel[d.tap]) delete st.previewSel[d.tap]; else st.previewSel[d.tap] = true; paintScene(); paintPreviewBar(); }
      return;
    }
    if (d.type === 'move') {
      if (!d.moved || (!d.dx && !d.dy)) { if (!d.moved && d.single) setSel([d.single]); else { paintScene(); paintOverlay(); } return; }
      var placedIn = [];
      commit(d.items.length > 1 ? 'Move ' + d.items.length + ' objects' : 'Move', function (c) {
        d.items.forEach(function (it) {
          var o = getObj(c, it.kind, it.id); if (!o) return;
          var g = Object.assign({}, it.g0, { x: it.g0.x + d.dx, y: it.g0.y + d.dy });
          writeGeom(it.kind, o, g);
          if (it.kind === 'display' && !o.areaId) { var a = areaAt(c, st.floorId, g.x + g.w / 2, g.y + g.h / 2); if (a) { o.areaId = a.id; placedIn.push((o.name || o.id) + ' is now in ' + a.name); } }
        });
      });
      if (placedIn.length) VF.toast(placedIn.length === 1 ? placedIn[0] + '.' : placedIn.length + ' displays were given the area they sit in.', 'ok');
      return;
    }
    if (d.type === 'resize' || d.type === 'rotate') {
      var g2 = temp[key(d.it.kind, d.it.id)];
      if (!d.moved || !g2) { paintScene(); paintOverlay(); return; }
      commit(d.type === 'resize' ? 'Resize' : 'Rotate', function (c) { var o = getObj(c, d.it.kind, d.it.id); if (o) writeGeom(d.it.kind, o, g2); });
      return;
    }
    if (d.type === 'marquee') {
      if (!d.moved || !band) { if (d.click) setSel([d.click]); else if (!d.add) setSel([]); else paintOverlay(); return; }
      var hits = placedOn(f.id).filter(function (it) {
        if (!st.layers[LAYER[it.kind]]) return false;
        var b = aabb(it.g);
        if (it.kind === 'area') return b.x >= band.x && b.y >= band.y && b.x + b.w <= band.x + band.w && b.y + b.h <= band.y + band.h;
        return b.x < band.x + band.w && b.x + b.w > band.x && b.y < band.y + band.h && b.y + b.h > band.y;
      }).map(function (it) { return { kind: it.kind, id: it.id }; });
      if (d.add) hits = st.sel.concat(hits.filter(function (x) { return !isSel(x.kind, x.id); }));
      setSel(hits); return;
    }
    if (d.type === 'draw') {
      var box = d.moved && band && band.w >= 8 && band.h >= 8 ? band : fitIn({ x: d.ax, y: d.ay, w: Math.min(DEF.area.w, f.width), h: Math.min(DEF.area.h, f.height), rot: 0 }, f);
      newArea(box); return;
    }
    paintOverlay();
  }
  function onWheel(e) {
    if (!ui || !floor()) return;
    e.preventDefault();
    var r = ui.svg.getBoundingClientRect(), dy = e.deltaMode === 1 ? e.deltaY * 16 : e.deltaY;
    zoomAt(e.clientX - r.left, e.clientY - r.top, view().k * Math.exp(-dy * (e.ctrlKey ? 0.01 : 0.0015)));
  }

  /* ── actions ─────────────────────────────────────────────────────────── */
  function setMode(m) { if (st.mode === m) return; cancelDrag(); st.mode = m; st.previewSel = {}; repaint(); onResize(); }
  function setTool(t) { cancelDrag(); st.tool = t; repaint(); }
  function setFloor(id) { cancelDrag(); st.floorId = id; st.sel = []; st.previewSel = {}; st.upload = null; var fresh = !st.views[id]; repaint(); if (fresh && fit()) applyView(); }
  function addFloor() {
    if (floors().length >= limit('floors', 12)) { VF.toast('A venue can have up to ' + limit('floors', 12) + ' floors.', 'warn'); return; }
    VF.prompt('Add floor', 'Floor name', uniqueName('Floor', floors()), 'Add floor').then(function (name) {
      if (!name) return;
      var id = Studio.freshId('floors', name);
      st.floorId = id; st.sel = [];
      commit('Add floor', function (c) { c.floors.push({ id: id, name: String(name).slice(0, 80), width: 1200, height: 800, grid: 20 }); });
      if (fit()) applyView();
    });
  }
  function deleteFloor() {
    var f = floor(); if (!f) return;
    askShellDelete('floor', f.id, 'floor');
  }
  /* The real delete: the shell asks, lists what else changes, and removes the entity and its references. */
  function askShellDelete(kind, id, noun) {
    st.expect = VF.clone(C());
    Studio.confirmRemove(kind, id, noun).then(function () { st.expect = null; });
  }
  function newDisplay() {
    var c = C(), f = floor(); if (!f) return;
    if (VF.asList(c.displays).length >= limit('displays', 200)) { VF.toast('This configuration already has the most displays it can hold.', 'warn'); return; }
    var top = 0; VF.asList(c.displays).forEach(function (d) { var m = /^TV (\d+)$/i.exec(d.name || ''), n = /^tv-(\d+)$/.exec(d.id || ''); if (m) top = Math.max(top, Number(m[1])); if (n) top = Math.max(top, Number(n[1])); });
    var name = uniqueName('TV', c.displays, top + 1), id = Studio.freshId('displays', name), at = dropPoint(DEF.display);
    st.sel = [{ kind: 'display', id: id }];
    commit('New display', function (cc) {
      var d = { id: id, name: name, kind: 'tv', floorId: f.id, route: { strategy: 'room' }, sources: 'all', power: 'room', feedback: 'room', layout: { x: at.x, y: at.y, w: DEF.display.w, h: DEF.display.h, rot: 0, locked: false, hidden: false } };
      var a = areaAt(cc, f.id, at.x + DEF.display.w / 2, at.y + DEF.display.h / 2); if (a) d.areaId = a.id;
      cc.displays.push(d);
    });
    VF.toast(name + ' added. It is not mapped yet: map it to a Control4 room in Devices.', 'warn');
  }
  /* Top-left corner for something of this size dropped in the middle of the view (each one a little further along). */
  function dropPoint(size, at) {
    var f = floor(), c = at || viewCentre(), g = gridOf(f);
    if (!at) { var off = (st.cascade++ % 6) * g; c = { x: c.x + off, y: c.y + off }; }
    var x = c.x - size.w / 2, y = c.y - size.h / 2;
    if (st.snap) { x = snapTo(x, f); y = snapTo(y, f); }
    var box = fitIn({ x: x, y: y, w: size.w, h: size.h, rot: 0 }, f);
    return { x: r1(box.x), y: r1(box.y) };
  }
  function newArea(box) {
    var c = C(), f = floor();
    if (VF.asList(c.areas).length >= limit('areas', 64)) { VF.toast('This configuration already has the most areas it can hold.', 'warn'); return; }
    var name = uniqueName('Area', c.areas), id = Studio.freshId('areas', name);
    st.tool = 'select'; st.sel = [{ kind: 'area', id: id }];
    commit('New area', function (cc) { cc.areas.push({ id: id, name: name, floorId: f.id, color: PALETTE[cc.areas.length % PALETTE.length], layout: { x: r1(box.x), y: r1(box.y), w: r1(box.w), h: r1(box.h) } }); });
  }
  function newLabel() {
    var c = C(), f = floor(); if (!f) return;
    if (listOf(c, 'label').length >= limit('labels', 200)) { VF.toast('This floor plan already has the most labels it can hold.', 'warn'); return; }
    var id = Studio.freshId('labels', 'lbl-' + (listOf(c, 'label').length + 1)), text = 'Label', size = 18, at = dropPoint({ w: textWidth(text, size), h: size * 1.25 });
    st.layers.labels = true; st.sel = [{ kind: 'label', id: id }];
    commit('New label', function (cc) { cc.layout.labels.push({ id: id, floorId: f.id, text: text, x: at.x, y: at.y, size: size, locked: false }); });
    setTimeout(function () { var n = ui && ui.right.querySelector('[data-f="text"]'); if (n) { try { n.focus(); n.select(); } catch (e) { /* ignore */ } } }, 30);
  }
  function newSceneButton() {
    var c = C(), f = floor(); if (!f) return;
    var scenes = Studio.list('scenes');
    if (!scenes.length) { VF.toast('There is no scene yet. Add one in Scenes, then put its button on the floor plan.', 'warn'); return; }
    if (listOf(c, 'button').length >= limit('sceneButtons', 64)) { VF.toast('This floor plan already has the most scene buttons it can hold.', 'warn'); return; }
    var sel = h('select.field'); scenes.forEach(function (s) { sel.appendChild(h('option', { value: s.id }, s.name)); });
    VF.modal({ title: 'New scene button', icon: 'zap', body: h('div.col', h('label.lbl', 'Scene the button runs', sel), h('p.small.muted', 'Operators see this button on the floor plan when their profile may run the scene.')), actions: [{ label: 'Cancel', kind: 'ghost', value: null }, { label: 'Add button', kind: 'primary', value: function () { return sel.value || false; } }] }).then(function (sceneId) {
      if (!sceneId || !Studio.find('scenes', sceneId)) return;
      var id = Studio.freshId('sceneButtons', 'sb-' + sceneId), at = dropPoint(DEF.button);
      st.layers.buttons = true; st.sel = [{ kind: 'button', id: id }];
      commit('New scene button', function (cc) { cc.layout.sceneButtons.push({ id: id, floorId: f.id, sceneId: sceneId, x: at.x, y: at.y, w: DEF.button.w, h: DEF.button.h }); });
    });
  }
  /* Puts an existing, unplaced display, zone or area on this floor. Only floorId, layout (and an empty areaId) change. */
  function place(kind, id, at) {
    var f = floor(); if (!f) return;
    var pt = dropPoint(DEF[kind], at), note = null;
    st.layers[LAYER[kind]] = true; st.sel = [{ kind: kind, id: id }];
    commit('Place on floor plan', function (c) {
      var o = getObj(c, kind, id); if (!o) return;
      if (kind !== 'area') o.floorId = f.id;
      o.layout = kind === 'display' ? { x: pt.x, y: pt.y, w: DEF.display.w, h: DEF.display.h, rot: 0, locked: false, hidden: false } : { x: pt.x, y: pt.y, w: DEF[kind].w, h: DEF[kind].h };
      if (kind === 'display' && !o.areaId) { var a = areaAt(c, f.id, pt.x + DEF.display.w / 2, pt.y + DEF.display.h / 2); if (a) { o.areaId = a.id; note = ' It is now in ' + a.name + '.'; } }
    });
    var o2 = getObj(C(), kind, id);
    VF.toast((o2 ? o2.name : NOUN[kind]) + ' placed on ' + f.name + '.' + (note || ''), 'ok');
  }
  /* "Remove from floor plan": deletes the layout only. Displays, zones and areas stay in the
     configuration with their Control4 mapping. Labels and scene buttons exist only on the plan,
     so for them this is a delete, and it asks first. */
  function removeFromPlan(items) {
    items = items || selItems(); if (!items.length) return;
    var soft = items.filter(function (it) { return FIELD[it.kind]; }), hard = items.filter(function (it) { return !FIELD[it.kind]; });
    function run() {
      st.sel = [];
      commit(hard.length && !soft.length ? 'Delete from floor plan' : 'Remove from floor plan', function (c) {
        soft.forEach(function (it) { var o = getObj(c, it.kind, it.id); if (o) delete o.layout; });
        if (hard.length) {
          var gone = {}; hard.forEach(function (it) { gone[key(it.kind, it.id)] = true; });
          c.layout.labels = c.layout.labels.filter(function (l) { return !gone[key('label', l.id)]; });
          c.layout.sceneButtons = c.layout.sceneButtons.filter(function (b) { return !gone[key('button', b.id)]; });
        }
      });
      if (soft.length) VF.toast(soft.length === 1 ? nameOfItem(soft[0].kind, soft[0].o) + ' was removed from the floor plan. It is kept, with its Control4 mapping: find it in the Library.' : soft.length + ' objects were removed from the floor plan. They are kept, with their Control4 mapping: find them in the Library.', 'ok', 5000);
    }
    if (!hard.length) { run(); return; }
    var what = hard.length === 1 ? (hard[0].kind === 'label' ? 'the label "' + (hard[0].o.text || '') + '"' : 'the scene button "' + nameOfItem('button', hard[0].o) + '"') : hard.length + (anyLabel(hard) && anyBtn(hard) ? ' labels and scene buttons' : anyBtn(hard) ? ' scene buttons' : ' labels');
    var anyButton = anyBtn(hard);
    VF.confirm('Delete from the floor plan', 'Delete ' + what + '? ' + (hard.length === 1 ? (anyButton ? 'A scene button exists only on the floor plan.' : 'A label exists only on the floor plan.') : 'They exist only on the floor plan.') + (anyButton ? ' The scene itself is kept.' : '') + ' No Control4 device is changed.' + (soft.length ? ' The other selected objects are only taken off the plan and stay in the Library.' : ''), 'Delete', 'danger').then(function (ok) { if (ok) run(); });
  }
  function anyLabel(list) { return list.some(function (it) { return it.kind === 'label'; }); }
  function anyBtn(list) { return list.some(function (it) { return it.kind === 'button'; }); }
  function nudge(dx, dy) {
    var items = selItems().filter(function (it) { return !it.locked; }), f = floor(); if (!items.length || !f) return;
    var box = union(items.map(function (it) { return aabb(it.g); }));
    dx = clampDelta(dx, box.x, box.w, f.width); dy = clampDelta(dy, box.y, box.h, f.height);
    if (!dx && !dy) return;
    commit('Nudge', function (c) { items.forEach(function (it) { var o = getObj(c, it.kind, it.id); if (!o) return; var g = geom(it.kind, o); g.x += dx; g.y += dy; writeGeom(it.kind, o, g); }); }, { coalesce: 'nudge' });
  }
  function align(how) {
    var items = selItems().filter(function (it) { return !it.locked; }); if (items.length < 2) return;
    var box = union(items.map(function (it) { return aabb(it.g); }));
    commit('Align', function (c) {
      items.forEach(function (it) {
        var o = getObj(c, it.kind, it.id); if (!o) return;
        var g = geom(it.kind, o), b = aabb(g);
        if (how === 'left') g.x += box.x - b.x; if (how === 'right') g.x += box.x + box.w - (b.x + b.w); if (how === 'centre') g.x += box.x + box.w / 2 - (b.x + b.w / 2);
        if (how === 'top') g.y += box.y - b.y; if (how === 'bottom') g.y += box.y + box.h - (b.y + b.h); if (how === 'middle') g.y += box.y + box.h / 2 - (b.y + b.h / 2);
        writeGeom(it.kind, o, g);
      });
    });
  }
  function editMapping(id) {
    Studio.flush().then(function () {
      Studio.go('devices', { displayId: id });
      if (Studio.currentSection() !== 'devices') VF.toast('The Devices section is not available in this build.', 'warn');
    });
  }

  /* ── floor plan picture ──────────────────────────────────────────────── */
  function loadPicture(file) {
    return new Promise(function (resolve, reject) {
      var im = new Image(), url = null, triedReader = false;
      im.onload = function () { if (url) URL.revokeObjectURL(url); resolve(im); };
      im.onerror = function () {
        if (url) { URL.revokeObjectURL(url); url = null; }
        if (triedReader) { reject(new Error('decode')); return; }
        triedReader = true;
        var fr = new FileReader(); fr.onload = function () { im.src = String(fr.result); }; fr.onerror = function () { reject(new Error('read')); }; fr.readAsDataURL(file);
      };
      try { url = URL.createObjectURL(file); im.src = url; } catch (e) { im.onerror(); }
    });
  }
  /* At most 1600 px on the long side, JPEG, quality lowered (then size) until the data URL is under
     560 kB. Lowering goes on a little further when that gets the picture under 240 kB: the
     controller keeps it in its own storage, and a large request is slow to send. */
  function encodePicture(im) {
    var w0 = im.naturalWidth || im.width, h0 = im.naturalHeight || im.height;
    if (!w0 || !h0) throw new Error('empty');
    var scale = Math.min(1, 1600 / Math.max(w0, h0)), max = 560 * 1024, light = 240 * 1024;
    for (var pass = 0; pass < 8; pass++) {
      var cw = Math.max(1, Math.round(w0 * scale)), ch = Math.max(1, Math.round(h0 * scale));
      var cv = document.createElement('canvas'); cv.width = cw; cv.height = ch;
      var ctx = cv.getContext('2d'); ctx.fillStyle = '#ffffff'; ctx.fillRect(0, 0, cw, ch); ctx.drawImage(im, 0, 0, cw, ch);
      var fallback = null;
      for (var q = 0.86; q >= 0.39; q -= 0.1) {
        var url = cv.toDataURL('image/jpeg', q);
        if (url.indexOf('data:image/jpeg;base64,') !== 0) throw new Error('encode');
        if (url.length <= light) return { dataUrl: url, width: cw, height: ch };
        if (url.length <= max) { fallback = { dataUrl: url, width: cw, height: ch }; if (q < 0.6) break; }
      }
      if (fallback) return fallback;
      scale *= 0.8;
    }
    throw new Error('size');
  }
  function setUpload(kind, text) { st.upload = kind ? { kind: kind, text: text, floorId: st.floorId } : null; paintInspectorSoon(); }
  function onFile() {
    var file = ui.file.files && ui.file.files[0], fid = st.floorId; if (!file || !fid) return;
    if (!/^image\/(png|jpeg|webp)$/.test(file.type)) { setUpload('bad', 'That file is not a PNG, JPEG or WebP picture.'); return; }
    setUpload('info', 'Preparing the picture…');
    loadPicture(file).then(encodePicture).then(function (enc) {
      setUpload('info', 'Sending the picture to the driver…');
      /* Raw upload (VF.upload), never inside a JSON request: see shared/vf.js. */
      return VF.upload(enc.dataUrl).then(function (r) {
        var k = r.ok && r.data ? r.data.key : null;
        if (!k) {
          if (r.errorCode === 'VF_NETWORK') setUpload('bad', 'No answer from the controller while sending the picture, so it was not attached to the floor. Try again.');
          else setUpload('bad', 'The driver refused the picture. ' + (r.message || 'It was not saved.') + (r.detail ? ' (' + r.detail + ')' : '') + (r.errorCode ? ' [' + r.errorCode + ']' : ''));
          return;
        }
        st.images[k] = enc.dataUrl;
        commit('Floor plan picture', function (c) { var f = VF.byId(c.floors, fid); if (f) f.image = { key: k, width: enc.width, height: enc.height }; }, { immediate: true });
        setUpload('ok', 'Picture stored by the driver (' + Math.round(enc.dataUrl.length / 1024) + ' kB, ' + enc.width + ' x ' + enc.height + ').');
      });
    }).catch(function (err) {
      setUpload('bad', err && err.message === 'size' ? 'That picture could not be made small enough to store (the limit is 600 kB). Try a simpler drawing.' : 'That picture could not be read.');
    });
  }
  function matchFloorToPicture() {
    var f = floor(), img = VF.asMap(f && f.image); if (!img.width || !img.height) return;
    var hgt = clamp(Math.round(f.width * img.height / img.width), 100, 20000);
    commit('Match floor to picture', function (c) { var ff = VF.byId(c.floors, st.floorId); if (ff) { ff.height = hgt; keepInside(c, ff); } });
    if (fit()) applyView();
  }
  function keepInside(c, f) {
    ['area', 'zone', 'display', 'button', 'label'].forEach(function (kind) {
      listOf(c, kind).forEach(function (o) { if (o && isPlaced(kind, o) && floorOf(c, kind, o) === f.id) writeGeom(kind, o, fitIn(geom(kind, o), f)); });
    });
  }

  /* ── panels ──────────────────────────────────────────────────────────── */
  function tb(iconName, label, onClick, opts) {
    opts = opts || {};
    return h('button.btn.ld-tb' + (opts.text ? '.txt' : '.icon'), { type: 'button', title: label, 'aria-label': label, 'aria-pressed': opts.on === undefined ? null : String(!!opts.on), disabled: opts.disabled, onclick: onClick }, iconName ? icon(iconName) : null, opts.text ? h('span', opts.text) : null);
  }
  function leftShown() { return st.mode === 'design' && (st.showLeft !== null ? st.showLeft : (!ui || !ui.root.clientWidth || ui.root.clientWidth >= 940)); }
  function rightShown() { return st.mode === 'design' && (st.showRight !== null ? st.showRight : (!ui || !ui.root.clientWidth || ui.root.clientWidth >= 640)); }
  function paintChrome() {
    var design = st.mode === 'design';
    ui.body.classList.toggle('noleft', !leftShown()); ui.body.classList.toggle('noright', !rightShown());
    ui.root.classList.toggle('is-preview', !design);
    var fl = floors();
    var modeSeg = h('div.seg', { role: 'tablist', 'aria-label': 'Mode' },
      h('button' + (design ? '.on' : ''), { type: 'button', role: 'tab', 'aria-selected': String(design), onclick: function () { setMode('design'); } }, 'Design'),
      h('button' + (design ? '' : '.on'), { type: 'button', role: 'tab', 'aria-selected': String(!design), onclick: function () { setMode('preview'); } }, 'Preview'));
    var floorSel = Studio.select(null, fl.map(function (f) { return { value: f.id, label: f.name }; }), st.floorId, function (v) { if (v) setFloor(v); });
    floorSel.setAttribute('aria-label', 'Floor'); floorSel.classList.add('ld-floorsel');
    ui.zoomLabel = h('span', Math.round(view().k * 100) + '%');
    VF.mount(ui.top,
      modeSeg,
      h('div.ld-grp', fl.length ? floorSel : null, design ? tb('plus', 'Add floor', addFloor) : null),
      design ? h('div.ld-grp', tb('cursor', 'Select and move objects', function () { setTool('select'); }, { on: st.tool === 'select', text: 'Select' }), tb('move', 'Move the view (or hold Space and drag)', function () { setTool('pan'); }, { on: st.tool === 'pan', text: 'Move' }), tb('square', 'Draw a room or area', function () { setTool('area'); }, { on: st.tool === 'area', text: 'Area' })) : null,
      design ? h('div.ld-grp', tb('target', 'Snap to grid', function () { st.snap = !st.snap; repaint(); }, { on: st.snap, text: 'Snap' }), tb('grid', 'Show the grid', function () { st.grid = !st.grid; repaint(); }, { on: st.grid, text: 'Grid' })) : null,
      design ? h('div.ld-grp', tb('undo', 'Undo (Ctrl+Z)', undo, { disabled: !st.undo.length }), tb('redo', 'Redo (Shift+Ctrl+Z)', redo, { disabled: !st.redo.length })) : null,
      h('span.grow'),
      design ? h('div.ld-grp', tb('layers', 'Library and layers', function () { st.showLeft = !leftShown(); repaint(); onResize(); }, { on: leftShown() }), tb('sliders', 'Inspector', function () { st.showRight = !rightShown(); repaint(); onResize(); }, { on: rightShown() })) : null);
    VF.mount(ui.zoom,
      tb('minus', 'Zoom out', function () { zoomBy(1 / 1.25); }),
      h('button.btn.ld-tb.ld-zoom', { type: 'button', title: 'Zoom to 100%', 'aria-label': 'Zoom to 100%', onclick: function () { var s = stageSize(); zoomAt(s.w / 2, s.h / 2, 1); } }, ui.zoomLabel),
      tb('plus', 'Zoom in', function () { zoomBy(1.25); }),
      tb('maximize', 'Fit the floor in view', function () { if (fit()) applyView(); }, { text: 'Fit' }));
  }
  function libRow(kind, o, sub) {
    var row = h('div.ld-lib', { role: 'button', tabindex: '0', title: 'Drag onto the canvas, or tap to place it in the middle of the view' },
      h('span.ld-grip', { 'aria-hidden': 'true' }, icon('grip', 'sm')),
      h('div.grow.col.tight', h('span.ellipsis', o.name || o.id), sub ? h('span.tiny.muted.ellipsis', sub) : null), icon('plus', 'sm'));
    row.addEventListener('pointerdown', function (e) {
      if (e.button) return;
      if (e.pointerType !== 'mouse' && !(e.target.closest && e.target.closest('.ld-grip'))) return;
      startLibDrag(e, kind, o.id, o.name || o.id);
    });
    row.addEventListener('click', function () { if (libClickGuard) { libClickGuard = false; return; } place(kind, o.id); });
    row.addEventListener('keydown', function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); place(kind, o.id); } });
    return row;
  }
  function startLibDrag(e, kind, id, name) {
    var sx = e.clientX, sy = e.clientY, ghost = null, moved = false, pid = e.pointerId;
    function over(ev) { var r = ui && ui.svg.getBoundingClientRect(); return !!r && ev.clientX >= r.left && ev.clientX <= r.right && ev.clientY >= r.top && ev.clientY <= r.bottom; }
    function move(ev) {
      if (ev.pointerId !== pid) return;
      if (!moved) { if (Math.hypot(ev.clientX - sx, ev.clientY - sy) < 6) return; moved = true; ghost = h('div.ld-ghost', icon(KIND_ICON[kind], 'sm'), h('span', name)); document.body.appendChild(ghost); }
      ghost.style.left = (ev.clientX + 10) + 'px'; ghost.style.top = (ev.clientY + 10) + 'px';
      ghost.classList.toggle('ok', over(ev));
      ev.preventDefault();
    }
    function end(ev) {
      if (ev.pointerId !== pid) return;
      window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', end); window.removeEventListener('pointercancel', end);
      if (ghost && ghost.parentNode) ghost.parentNode.removeChild(ghost);
      if (!moved || !ui) return;
      libClickGuard = true; setTimeout(function () { libClickGuard = false; }, 0);
      if (ev.type === 'pointerup' && over(ev)) { var p = toWorld(ev); place(kind, id, { x: p.x, y: p.y }); }
    }
    window.addEventListener('pointermove', move); window.addEventListener('pointerup', end); window.addEventListener('pointercancel', end);
  }
  function sec(title) {
    var s = h('section.ld-sec', title ? h('h4', title) : null);
    for (var i = 1; i < arguments.length; i++) VF.append(s, arguments[i]);
    return s;
  }
  function paintLeft() {
    if (!ui) return;
    if (st.mode !== 'design') { VF.clear(ui.left); return; }
    var c = C(), f = floor(), keep = ui.left.scrollTop;
    var unD = VF.asList(c.displays).filter(function (d) { return !hasLayout(d); });
    var unZ = VF.asList(c.audioZones).filter(function (z) { return !hasLayout(z); });
    var unA = VF.asList(c.areas).filter(function (a) { return !hasLayout(a) && f && a.floorId === f.id; });
    function unplaced(title, kind, list, empty) {
      return h('div.col.tight', h('div.ld-sub', title, h('span.chip', String(list.length))),
        list.length ? list.map(function (o) { var other = kind === 'display' && f && o.floorId && o.floorId !== f.id ? 'Was on ' + Studio.nameOf('floors', o.floorId, 'another floor') : null; return libRow(kind, o, other); }) : h('p.hint', empty));
    }
    var library = sec('Library',
      h('div.ld-new',
        h('button.btn.sm', { type: 'button', disabled: !f, onclick: newDisplay, title: 'Creates a display on this floor. It is unmapped until you map it in Devices.' }, icon('tv', 'sm'), 'New display'),
        h('button.btn.sm' + (st.tool === 'area' ? '.on' : ''), { type: 'button', disabled: !f, onclick: function () { setTool('area'); VF.toast('Drag on the canvas to draw the area.', 'info'); } }, icon('square', 'sm'), 'New area'),
        h('button.btn.sm', { type: 'button', disabled: !f, onclick: newLabel }, icon('type', 'sm'), 'New label'),
        h('button.btn.sm', { type: 'button', disabled: !f, onclick: newSceneButton }, icon('zap', 'sm'), 'New scene button')),
      h('p.hint', 'A new display is not mapped to Control4 until you map it in Devices.'),
      f ? unplaced('Unplaced displays', 'display', unD, 'Every display is on a floor plan.') : null,
      f ? unplaced('Unplaced audio zones', 'zone', unZ, 'Every audio zone is on a floor plan.') : null,
      f && unA.length ? unplaced('Unplaced areas', 'area', unA, '') : null,
      f && (unD.length || unZ.length || unA.length) ? h('p.hint', 'Drag one onto the canvas, or tap it to place it in the middle of the view.') : null);
    var layerRows = [['image', 'Floor plan picture', 'image'], ['areas', 'Areas', 'square'], ['displays', 'Displays', 'tv'], ['zones', 'Audio zones', 'volume'], ['labels', 'Labels', 'type'], ['buttons', 'Scene buttons', 'zap']].map(function (row) {
      var on = st.layers[row[0]];
      return h('button.ld-layer' + (on ? '' : '.off'), { type: 'button', 'aria-pressed': String(on), title: (on ? 'Hide ' : 'Show ') + row[1] + ' on this canvas (a view setting, not saved)', onclick: function () { st.layers[row[0]] = !on; repaint(); } }, icon(row[2], 'sm'), h('span.grow', row[1]), icon(on ? 'eye' : 'eye-off', 'sm'));
    });
    var floorRows = floors().map(function (fl) {
      var n = VF.asList(c.displays).filter(function (d) { return d.floorId === fl.id && hasLayout(d); }).length;
      return h('button.ld-layer' + (fl.id === st.floorId ? '.sel' : ''), { type: 'button', 'aria-current': fl.id === st.floorId ? 'true' : null, onclick: function () { if (fl.id !== st.floorId) setFloor(fl.id); } }, icon('layers', 'sm'), h('span.grow.ellipsis', fl.name), h('span.chip', { title: n + (n === 1 ? ' display' : ' displays') + ' on the plan' }, String(n)));
    });
    ui.objList = h('div.col.tight');
    VF.mount(ui.left, library,
      sec('Layers', h('div.ld-sub', 'Floors'), floorRows, h('button.btn.sm.ghost', { type: 'button', onclick: addFloor }, icon('plus', 'sm'), 'Add floor'),
        h('div.ld-sub', 'Show on the canvas'), layerRows, h('p.hint', 'These switches only change this editor view. What operators see is set per display with "Shown to operators".')),
      sec('On this floor', ui.objList));
    paintLeftSel();
    ui.left.scrollTop = keep;
  }
  /* The list of placed objects (a way to pick something that sits under something else). */
  function paintLeftSel() {
    if (!ui || !ui.objList) return;
    var f = floor(), items = f ? placedOn(f.id).filter(function (it) { return st.layers[LAYER[it.kind]]; }) : [];
    var order = { display: 0, zone: 1, area: 2, button: 3, label: 4 };
    items.sort(function (a, b) { return order[a.kind] - order[b.kind] || String(nameOfItem(a.kind, a.o)).localeCompare(String(nameOfItem(b.kind, b.o)), undefined, { numeric: true }); });
    VF.mount(ui.objList, items.length ? items.map(function (it) {
      var hidden = it.kind === 'display' && it.o.layout.hidden === true;
      return h('button.ld-layer.ld-objrow' + (isSel(it.kind, it.id) ? '.sel' : ''), { type: 'button', onclick: function (e) { if (e.shiftKey || e.ctrlKey || e.metaKey) toggleSel(it.kind, it.id); else setSel([{ kind: it.kind, id: it.id }]); } },
        icon(KIND_ICON[it.kind], 'sm'), h('span.grow.ellipsis', nameOfItem(it.kind, it.o)),
        it.kind === 'display' && !mapping(it.o).mapped ? h('span.dot.warn', { title: 'Not mapped yet' }) : null,
        hidden ? icon('eye-off', 'sm') : null, it.locked ? icon('lock', 'sm') : null);
    }) : h('p.hint', 'Nothing is placed on this floor yet.'));
  }
  function paintPreviewBar() {
    if (!ui) return;
    if (st.mode !== 'preview') { VF.clear(ui.pv); return; }
    var profSel = Studio.select(null, Studio.list('profiles').map(function (p) { return { value: p.id, label: p.name }; }), st.previewProfile, function (v) { st.previewProfile = v || ''; st.previewSel = {}; repaint(); }, { none: 'Installer (sees everything)' });
    profSel.setAttribute('aria-label', 'Preview as');
    var n = ui.pvCounts || { shown: 0, total: 0, hidden: 0 }, picked = Object.keys(st.previewSel).length;
    VF.mount(ui.pv,
      h('span.chip.teal', icon('eye', 'sm'), 'Operator Preview'),
      h('div.ld-pvas', h('span.small.muted.nowrap', 'Preview as'), profSel),
      h('span.small.grow', n.shown + ' of ' + n.total + ' displays on this floor are shown' + (n.hidden ? ' (' + n.hidden + ' hidden from operators)' : '') + '. This is a preview of layout and visibility, not live state: source names are samples.'),
      picked ? h('span.chip.teal', picked + ' selected') : h('span.small.muted.nowrap', 'Tap a display to see selection'),
      picked ? h('button.btn.sm.ghost', { type: 'button', onclick: function () { st.previewSel = {}; paintScene(); paintPreviewBar(); } }, 'Clear') : null);
  }
  function paintStatus() {
    if (!ui) return;
    var items = selItems(), text;
    if (st.mode === 'preview') text = 'Preview. Drag to move the view, tap a display to see how selection looks.';
    else if (items.length === 1) text = NOUN[items[0].kind] + ': ' + nameOfItem(items[0].kind, items[0].o) + (items[0].locked ? ' (locked)' : '');
    else if (items.length > 1) text = items.length + ' objects selected';
    else text = HINT[st.tool];
    ui.coords = h('span.mono.nowrap');
    VF.mount(ui.status, h('span.grow.ellipsis', text), ui.coords);
  }

  /* ── inspector ───────────────────────────────────────────────────────── */
  function fkey(k, el) { var input = el.matches && el.matches('input, select, textarea') ? el : el.querySelector('input, select, textarea'); if (input) input.dataset.f = k; return el; }
  function numField(k, label, value, onChange, opts) {
    return fkey(k, Studio.number(label, value === undefined ? undefined : r1(value), function (n) { if (n === undefined) { paintInspectorSoon(); return; } onChange(n); }, opts));
  }
  function kv(k, v, cls) { return h('div.ld-kv', h('span.muted', k), h('span' + (cls ? '.' + cls : ''), v)); }
  function geomFields(it, withSize) {
    var f = floor(), g = it.g, lock = it.locked;
    function set(prop, label) { return function (n) { editGeom(it, label, function (ng) { ng[prop] = n; }); }; }
    return h('div.ld-g2',
      numField('x', 'X', g.x, set('x', 'Move'), { min: 0, max: f.width, disabled: lock }),
      numField('y', 'Y', g.y, set('y', 'Move'), { min: 0, max: f.height, disabled: lock }),
      withSize ? numField('w', 'Width', g.w, set('w', 'Resize'), { min: 4, max: f.width, disabled: lock }) : null,
      withSize ? numField('h', 'Height', g.h, set('h', 'Resize'), { min: 4, max: f.height, disabled: lock }) : null);
  }
  function lockToggle(it) {
    return Studio.toggle('Locked', it.locked, function (on) { edit(it, on ? 'Lock' : 'Unlock', function (o) { setLocked(it.kind, o, on); }); }, 'A locked object cannot be moved or resized until it is unlocked.');
  }
  function nameField(it, label) { return fkey('name', Studio.text(label || 'Name', it.o.name, function (v) { if (!v) { paintInspectorSoon(); return; } edit(it, 'Rename', function (o) { o.name = v; }); })); }
  function head(it) { return h('div.ld-ihead', icon(KIND_ICON[it.kind]), h('div.grow.col.tight', h('h3.ellipsis', nameOfItem(it.kind, it.o)), h('span.tiny.muted.mono', NOUN[it.kind] + ' · id ' + it.id))); }
  function removeBlock(it, noun, shellKind) {
    return sec('Remove',
      h('button.btn.block', { type: 'button', onclick: function () { removeFromPlan([it]); } }, icon('x'), 'Remove from floor plan'),
      h('p.hint', 'Takes it off the plan only. ' + (shellKind === 'area' ? 'The area is kept, with the displays that belong to it' : 'The ' + noun + ' and its Control4 mapping are kept') + ', and it goes back to the Library as unplaced. The Delete key does this.'),
      h('div.divider'),
      h('button.btn.danger.block', { type: 'button', onclick: function () { askShellDelete(shellKind, it.id, noun); } }, icon('trash'), 'Delete ' + noun),
      h('p.hint', 'Deletes the ' + noun + ' from this VenueFlow configuration, after asking. Neither action can delete or change a Control4 device, room or connection.'));
  }
  function paintIssues() {
    if (!ui || !ui.issueBox) return;
    var id = ui.issueBox.dataset.id, list = Studio.issuesFor('display', id);
    VF.mount(ui.issueBox, list.length ? Studio.issueList(list) : null);
  }
  function displayInspector(it) {
    var d = it.o, m = mapping(d), c = C(), route = VF.asMap(d.route);
    var here = VF.asList(c.areas).filter(function (a) { return a.floorId === st.floorId; });
    var current = d.areaId ? VF.byId(c.areas, d.areaId) : null;
    var opts = here.map(function (a) { return { value: a.id, label: a.name }; });
    if (current && current.floorId !== st.floorId) opts.push({ value: current.id, label: current.name + ' (on another floor)' });
    if (d.areaId && !current) opts.push({ value: d.areaId, label: '(missing area)' });
    var inside = areaAt(c, st.floorId, it.g.x + it.g.w / 2, it.g.y + it.g.h / 2);
    var suggest = inside && inside.id !== d.areaId ? h('div.banner.info.ld-suggest', h('div.grow.small', current ? 'It sits inside ' + inside.name + ' but belongs to ' + current.name + '.' : 'It sits inside ' + inside.name + '.'),
      h('button.btn.sm', { type: 'button', onclick: function () { edit(it, 'Move to area', function (o) { o.areaId = inside.id; }); } }, 'Move to ' + inside.name)) : null;
    var groups = VF.asList(c.groups).filter(function (g) { return VF.asList(g.displayIds).indexOf(d.id) >= 0; });
    var rot = it.g.rot, hidden = d.layout.hidden === true;
    function setRot(n) { editGeom(it, 'Rotate', function (g) { g.rot = normRot(n); }); }
    ui.issueBox = h('div.col.tight', { dataset: { id: d.id } });
    var out = [
      head(it),
      sec(null, nameField(it), h('div.row.wrap.tight', h('span.chip', d.kind === 'videowall' ? 'Video wall' : d.kind === 'projector' ? 'Projector' : 'TV'), m.mapped ? h('span.chip.ok', h('span.dot'), 'Mapped') : h('span.chip.warn', h('span.dot'), 'Not mapped'))),
      sec('Position and size', geomFields(it, true),
        h('div.ld-rot', numField('rot', 'Rotation', rot, setRot, { min: 0, max: 359, disabled: it.locked }),
          h('div.seg', { role: 'group', 'aria-label': 'Rotation' }, [0, 90, 180, 270].map(function (r) { return h('button' + (rot === r ? '.on' : ''), { type: 'button', disabled: it.locked, onclick: function () { setRot(r); } }, r + '°'); }))),
        lockToggle(it),
        Studio.toggle('Shown to operators', !hidden, function (on) { edit(it, on ? 'Show to operators' : 'Hide from operators', function (o) { o.layout.hidden = !on; }); }, 'Off: not drawn on the operator floor plan. It stays controllable from the Command Center.')),
      sec('Area and groups',
        fkey('area', Studio.select('Area', opts, d.areaId, function (v) { edit(it, 'Change area', function (o) { if (v) o.areaId = v; else delete o.areaId; }); }, { none: 'No area' })),
        suggest,
        h('div.col.tight', h('span.small.muted', 'Display groups'), groups.length ? h('div.row.wrap.tight', groups.map(function (g) { return h('span.chip', h('span.dot', { style: { background: safeColor(g.color) } }), g.name); })) : h('span.hint', 'In no display group.'))),
      h('section.ld-sec.ld-map',
        h('div.row.between', h('h4', 'Control4 mapping'), h('span.chip', icon('lock', 'sm'), 'Read only')),
        kv('Room', d.c4RoomId ? 'Room ' + d.c4RoomId : 'Not set', d.c4RoomId ? 'mono' : (m.missing.indexOf('Control4 room') >= 0 ? 'ld-missing' : 'muted')),
        kv('Display device', d.c4DeviceId ? 'Device ' + d.c4DeviceId : 'Not set', d.c4DeviceId ? 'mono' : (m.missing.indexOf('Control4 device') >= 0 ? 'ld-missing' : 'muted')),
        kv('Routing', ROUTE_LABEL[m.strategy] || m.strategy),
        m.strategy === 'command' && VF.asMap(route.command).name ? kv('Command', VF.asMap(route.command).name + ' to device ' + VF.asMap(route.command).deviceId, 'mono') : null,
        kv('Power', POWER_LABEL[d.power] || String(d.power)), kv('Feedback', FEEDBACK_LABEL[d.feedback] || String(d.feedback)),
        kv('Sources', d.sources === 'all' ? 'All' : VF.asList(d.sources).length + ' chosen'),
        m.mapped ? null : h('div.banner.warn', icon('alert', 'sm'), h('div.small', 'Not mapped yet (' + m.missing.join(', ') + ' missing). It cannot be controlled until you map it in Devices.')),
        ui.issueBox,
        h('button.btn.outline.block', { type: 'button', onclick: function () { editMapping(d.id); } }, icon('link'), 'Edit mapping'),
        h('p.hint', 'Moving, resizing, rotating or hiding the icon never changes this mapping.')),
      removeBlock(it, 'display', 'display')
    ];
    paintIssues();
    return out;
  }
  function zoneInspector(it) {
    var z = it.o;
    return [head(it), sec(null, nameField(it)), sec('Position and size', geomFields(it, true), lockToggle(it)),
      h('section.ld-sec.ld-map', h('div.row.between', h('h4', 'Control4 mapping'), h('span.chip', icon('lock', 'sm'), 'Read only')),
        kv('Room', z.c4RoomId ? 'Room ' + z.c4RoomId : 'Not set', z.c4RoomId ? 'mono' : 'ld-missing'), kv('Area', z.areaId ? Studio.nameOf('areas', z.areaId) : 'None'),
        h('p.hint', 'Moving or resizing the pill never changes this mapping. Edit the zone in Audio Zones.')),
      removeBlock(it, 'audio zone', 'zone')];
  }
  function areaInspector(it) {
    var a = it.o, color = safeColor(a.color);
    function setColor(v) { edit(it, 'Area colour', function (o) { o.color = v; }); }
    var picker = h('input.ld-color', { type: 'color', value: color, 'aria-label': 'Custom colour' }); picker.dataset.f = 'color';
    picker.addEventListener('change', function () { setColor(picker.value); });
    var n = Studio.list('displays').filter(function (d) { return d.areaId === a.id; }).length;
    return [head(it), sec(null, nameField(it),
      h('div.col.tight', h('span.small.muted', 'Colour'), h('div.ld-swatches', PALETTE.map(function (p) { return h('button.ld-swatch' + (p === color.toLowerCase() ? '.on' : ''), { type: 'button', 'aria-label': 'Colour ' + p, style: { background: p }, onclick: function () { setColor(p); } }); }), picker)),
      h('p.hint', n + (n === 1 ? ' display belongs' : ' displays belong') + ' to this area.')),
      sec('Position and size', geomFields(it, true), lockToggle(it)),
      removeBlock(it, 'area', 'area')];
  }
  function labelInspector(it) {
    var l = it.o;
    return [head(it), sec(null,
      fkey('text', Studio.text('Text', l.text, function (v) { if (!v) { paintInspectorSoon(); return; } edit(it, 'Label text', function (o) { o.text = v; }); }, { max: 120 })),
      numField('size', 'Text size', labelSize(l).size, function (n) { edit(it, 'Label size', function (o, c) { o.size = n; writeGeom('label', o, fitIn(geom('label', o), VF.byId(c.floors, st.floorId))); }); }, { min: 8, max: 120 })),
      sec('Position', geomFields(it, false), lockToggle(it)),
      sec('Delete', h('button.btn.danger.block', { type: 'button', onclick: function () { removeFromPlan([it]); } }, icon('trash'), 'Delete label'),
        h('p.hint', 'A label exists only on the floor plan. It asks first. No Control4 device is changed.'))];
  }
  function buttonInspector(it) {
    var b = it.o, opts = Studio.entityOptions('scenes'), known = !!Studio.find('scenes', b.sceneId);
    if (!known && b.sceneId) opts.push({ value: b.sceneId, label: '(missing scene)' });
    return [head(it), sec(null,
      fkey('scene', Studio.select('Scene', opts, b.sceneId, function (v) { if (v) edit(it, 'Scene button scene', function (o) { o.sceneId = v; }); })),
      known ? null : h('div.banner.warn', icon('alert', 'sm'), h('div.small', 'This button points to a scene that no longer exists. Choose another.')),
      h('p.hint', 'Operators see the button when their profile may run this scene.')),
      sec('Position and size', geomFields(it, true), lockToggle(it)),
      sec('Delete', h('button.btn.danger.block', { type: 'button', onclick: function () { removeFromPlan([it]); } }, icon('trash'), 'Delete scene button'),
        h('p.hint', 'Deletes the button only, after asking. The scene is kept and no Control4 device is changed.'))];
  }
  function multiInspector(items) {
    var movable = items.filter(function (it) { return !it.locked; }), allLocked = !movable.length;
    var displays = items.filter(function (it) { return it.kind === 'display'; }), allShown = displays.every(function (it) { return it.o.layout.hidden !== true; });
    var counts = {}; items.forEach(function (it) { counts[it.kind] = (counts[it.kind] || 0) + 1; });
    function ab(label, how) { return h('button.btn.sm', { type: 'button', disabled: movable.length < 2, onclick: function () { align(how); } }, label); }
    return [h('div.ld-ihead', icon('copy'), h('div.grow.col.tight', h('h3', items.length + ' objects selected'), h('span.tiny.muted', Object.keys(counts).map(function (k) { return counts[k] + ' ' + NOUN[k].toLowerCase() + (counts[k] === 1 ? '' : 's'); }).join(', ')))),
      sec('Align', h('div.ld-g3', ab('Left', 'left'), ab('Centre', 'centre'), ab('Right', 'right'), ab('Top', 'top'), ab('Middle', 'middle'), ab('Bottom', 'bottom')), h('p.hint', 'Drag any one to move them together. Arrow keys nudge by one grid step (Shift: one unit).')),
      sec(null, Studio.toggle('Locked', allLocked, function (on) { commit(on ? 'Lock' : 'Unlock', function (c) { items.forEach(function (it) { var o = getObj(c, it.kind, it.id); if (o) setLocked(it.kind, o, on); }); }); }, 'Locked objects cannot be moved or resized.'),
        displays.length ? Studio.toggle('Shown to operators', allShown, function (on) { commit(on ? 'Show to operators' : 'Hide from operators', function (c) { displays.forEach(function (it) { var o = getObj(c, 'display', it.id); if (o && hasLayout(o)) o.layout.hidden = !on; }); }); }, displays.length + (displays.length === 1 ? ' display' : ' displays') + ' in the selection.') : null),
      sec('Remove', h('button.btn.block', { type: 'button', onclick: function () { removeFromPlan(items); } }, icon('x'), 'Remove from floor plan'),
        h('p.hint', 'Displays, audio zones and areas are kept with their Control4 mapping and go back to the Library. Labels and scene buttons are deleted, after asking. No Control4 device is changed.'))];
  }
  function floorInspector() {
    var f = floor();
    if (!f) return [sec('Floor', h('p.hint', 'This venue has no floor yet.'), h('button.btn.primary.block', { type: 'button', onclick: addFloor }, icon('plus'), 'Add a floor'))];
    var img = VF.asMap(f.image), has = !!img.key, state = has ? st.images[img.key] : null, c = C();
    function setFloorProp(label, fn) { commit(label, function (cc) { var ff = VF.byId(cc.floors, f.id); if (ff) { fn(ff); keepInside(cc, ff); } }); if (view().auto && fit()) applyView(); }
    var placed = placedOn(f.id), nd = placed.filter(function (it) { return it.kind === 'display'; }).length;
    var onFloor = VF.asList(c.displays).filter(function (d) { return d.floorId === f.id; }).length, areasOn = VF.asList(c.areas).filter(function (a) { return a.floorId === f.id; }).length;
    var up = st.upload && st.upload.floorId === f.id ? st.upload : null;
    var mismatch = has && img.width && img.height && Math.abs(f.width / f.height - img.width / img.height) > 0.01;
    return [
      h('div.ld-ihead', icon('layers'), h('div.grow.col.tight', h('h3.ellipsis', f.name), h('span.tiny.muted.mono', 'Floor · id ' + f.id))),
      sec(null, fkey('name', Studio.text('Floor name', f.name, function (v) { if (!v) { paintInspectorSoon(); return; } setFloorProp('Rename floor', function (ff) { ff.name = v; }); })),
        h('div.ld-g2',
          numField('fw', 'Width', f.width, function (n) { setFloorProp('Resize floor', function (ff) { ff.width = Math.round(n); }); }, { min: 100, max: 20000 }),
          numField('fh', 'Height', f.height, function (n) { setFloorProp('Resize floor', function (ff) { ff.height = Math.round(n); }); }, { min: 100, max: 20000 })),
        numField('grid', 'Grid size', gridOf(f), function (n) { setFloorProp('Grid size', function (ff) { ff.grid = n; }); }, { min: 1, max: 500, hint: 'In canvas units, like every position here. Snap uses it.' }),
        h('p.hint', nd + ' of ' + onFloor + (onFloor === 1 ? ' display' : ' displays') + ' of this floor on the plan. Select nothing to see these floor settings.')),
      sec('Floor plan picture',
        has ? h('div.ld-kv', h('span.muted', 'Picture'), h('span', (img.width && img.height ? img.width + ' x ' + img.height : 'Stored') + (state && state.missing ? ' (not found in the driver)' : ''))) : h('p.hint', 'Blank canvas: this floor has no picture, only the grid.'),
        up ? h('div.banner.' + up.kind, icon(up.kind === 'bad' ? 'alert' : up.kind === 'ok' ? 'check-circle' : 'info', 'sm'), h('div.small', up.text)) : null,
        h('button.btn.block', { type: 'button', onclick: function () { ui.file.value = ''; ui.file.click(); } }, icon('upload'), has ? 'Replace picture' : 'Upload picture'),
        mismatch ? h('button.btn.block', { type: 'button', onclick: matchFloorToPicture, title: 'Sets the floor height so the picture fills the floor exactly' }, icon('maximize'), 'Match floor to picture') : null,
        has ? h('button.btn.block.ghost', { type: 'button', onclick: function () { st.upload = null; commit('Remove picture', function (cc) { var ff = VF.byId(cc.floors, f.id); if (ff) delete ff.image; }); } }, icon('x'), 'Remove picture') : null,
        h('p.hint', 'PNG, JPEG or WebP. It is reduced to at most 1600 px and stored as a JPEG under 560 kB. The picture is drawn under everything, fitted inside the floor.')),
      sec('Delete',
        h('button.btn.danger.block', { type: 'button', disabled: floors().length < 2, onclick: deleteFloor }, icon('trash'), 'Delete floor'),
        h('p.hint', floors().length < 2 ? 'A venue needs at least one floor.' : 'Asks first. Deleting a floor also deletes its ' + areasOn + (areasOn === 1 ? ' area' : ' areas') + ' and ' + onFloor + (onFloor === 1 ? ' display' : ' displays') + ' from this VenueFlow configuration, with its labels and scene buttons. No Control4 device, room or connection is deleted or changed.'))
    ];
  }
  function paintInspector() {
    if (!ui) return;
    ui.issueBox = null;
    if (st.mode !== 'design') { VF.clear(ui.right); return; }
    var items = selItems(), keep = ui.right.scrollTop, body;
    if (!items.length) body = floorInspector();
    else if (items.length > 1) body = multiInspector(items);
    else body = ({ display: displayInspector, zone: zoneInspector, area: areaInspector, label: labelInspector, button: buttonInspector })[items[0].kind](items[0]);
    var sameKey = ui.right.dataset.k === (items.length === 1 ? key(items[0].kind, items[0].id) : String(items.length));
    VF.mount(ui.right, body);
    ui.right.dataset.k = items.length === 1 ? key(items[0].kind, items[0].id) : String(items.length);
    ui.right.scrollTop = sameKey ? keep : 0;
  }
  /* Rebuilt on the next tick, so a Tab out of a field lands on the next field first; focus is put back by field key. */
  function paintInspectorSoon() {
    if (inspTimer) return;
    inspTimer = setTimeout(function () {
      inspTimer = null; if (!ui) return;
      var a = document.activeElement, k = a && a.dataset && ui.right.contains(a) ? a.dataset.f : null;
      paintInspector();
      if (k) { var n = ui.right.querySelector('[data-f="' + k + '"]'); if (n && !n.disabled) { try { n.focus(); if (n.select && n.type !== 'color') n.select(); } catch (e) { /* ignore */ } } }
    }, 0);
  }

  function repaint() {
    if (!ui) return;
    pruneState();
    paintChrome(); paintScene(); applyView(); paintLeft(); paintInspectorSoon(); paintPreviewBar(); paintStatus();
  }

  /* ── keyboard ────────────────────────────────────────────────────────── */
  function onKey(e) {
    if (!ui || !document.body.contains(ui.root) || document.querySelector('.vf-backdrop')) return;
    var t = e.target, tag = t && t.tagName, typing = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || (t && t.isContentEditable);
    var mod = e.ctrlKey || e.metaKey, k = e.key;
    if (typing || st.mode !== 'design') { if (k === 'Escape' && typing) { try { t.blur(); } catch (err) { /* ignore */ } } return; }
    if (mod && (k === 'z' || k === 'Z')) { e.preventDefault(); if (e.shiftKey) redo(); else undo(); return; }
    if (mod && (k === 'y' || k === 'Y')) { e.preventDefault(); redo(); return; }
    if (mod && (k === 'a' || k === 'A')) { e.preventDefault(); var f = floor(); if (f) setSel(placedOn(f.id).filter(function (it) { return st.layers[LAYER[it.kind]]; }).map(function (it) { return { kind: it.kind, id: it.id }; })); return; }
    if (mod || e.altKey) return;
    if (k === ' ' && tag !== 'BUTTON') { spaceDown = true; ui.svg.classList.add('grab'); e.preventDefault(); return; }
    if (k === 'Escape') { if (drag) cancelDrag(); else if (st.tool !== 'select') setTool('select'); else if (st.sel.length) setSel([]); return; }
    if (k === 'Delete' || k === 'Backspace') {
      var all = selItems(), free = all.filter(function (it) { return !it.locked; });
      if (!all.length) return;
      e.preventDefault();
      if (free.length < all.length) VF.toast(free.length ? 'Locked objects were left on the plan. Unlock them first.' : 'This is locked. Unlock it before removing it from the plan.', 'warn');
      if (free.length) removeFromPlan(free);
      return;
    }
    var step = e.shiftKey ? 1 : gridOf(floor());
    if (k === 'ArrowLeft') { e.preventDefault(); nudge(-step, 0); } else if (k === 'ArrowRight') { e.preventDefault(); nudge(step, 0); }
    else if (k === 'ArrowUp') { e.preventDefault(); nudge(0, -step); } else if (k === 'ArrowDown') { e.preventDefault(); nudge(0, step); }
  }
  function onKeyUp(e) { if (e.key === ' ') { spaceDown = false; if (ui) ui.svg.classList.remove('grab'); } }

  /* ── sizing: the section fills the shell's main area ─────────────────── */
  function px(v) { return parseFloat(v) || 0; }
  function fitHost() {
    if (!ui) return;
    var host = ui.host, main = host.parentNode; if (!main || !main.getBoundingClientRect || !document.body.contains(host)) return;
    var cs = getComputedStyle(main), first = !host.previousElementSibling;
    host.style.margin = (first ? -px(cs.paddingTop) : 0) + 'px ' + (-px(cs.paddingRight)) + 'px ' + (-px(cs.paddingBottom)) + 'px ' + (-px(cs.paddingLeft)) + 'px';
    var top = host.getBoundingClientRect().top - main.getBoundingClientRect().top + main.scrollTop;
    host.style.height = Math.max(440, main.clientHeight - top) + 'px';
  }
  function onResize() {
    if (!ui) return;
    fitHost();
    var wasLeft = ui.body.classList.contains('noleft'), wasRight = ui.body.classList.contains('noright');
    if (wasLeft === leftShown() || wasRight === rightShown()) paintChrome();
    var v = view(); if (v.auto) fit();
    applyView();
  }
  function teardown() {
    if (inspTimer) { clearTimeout(inspTimer); inspTimer = null; }
    document.removeEventListener('keydown', onKey); document.removeEventListener('keyup', onKeyUp);
    window.removeEventListener('resize', onResize);
    if (ui && ui.ro) { try { ui.ro.disconnect(); } catch (e) { /* ignore */ } }
    drag = null; pinch = null; pointers = {}; guides = []; st.temp = {}; st.band = null; spaceDown = false;
    ui = null;
  }

  /* ── the section ─────────────────────────────────────────────────────── */
  function render(container, params) {
    teardown();
    if (!Studio.config()) { Studio.emptyDraft(container); return; }
    container.classList.add('wide', 'ld-host');
    if (params && params !== st.lastParams) {
      st.lastParams = params;
      var d = params.displayId ? Studio.find('displays', params.displayId) : null;
      if (d && d.floorId) { st.floorId = d.floorId; st.mode = 'design'; st.layers.displays = true; st.sel = hasLayout(d) ? [{ kind: 'display', id: d.id }] : []; }
      else if (params.floorId && Studio.find('floors', params.floorId)) st.floorId = params.floorId;
    }
    ui = { host: container, nodes: {} };
    ui.patA = sv('pattern', { id: 'ld-grid-a', patternUnits: 'userSpaceOnUse', width: 20, height: 20 }, sv('path', { class: 'ld-gl', d: 'M 20 0 H 0 V 20' }));
    ui.patB = sv('pattern', { id: 'ld-grid-b', patternUnits: 'userSpaceOnUse', width: 100, height: 100 }, sv('path', { class: 'ld-gl major', d: 'M 100 0 H 0 V 100' }));
    ui.world = sv('g'); ui.over = sv('g', { class: 'ld-over' }); ui.rul = sv('g', { class: 'ld-rul' });
    ui.svg = sv('svg', { class: 'ld-svg', tabindex: '0', role: 'application', 'aria-label': 'Floor plan canvas' }, sv('defs', null, ui.patA, ui.patB), ui.world, ui.over, ui.rul);
    ui.msg = h('div.ld-msg.hidden'); ui.status = h('div.ld-status'); ui.zoom = h('div.ld-zoombox', { role: 'group', 'aria-label': 'Zoom' });
    ui.stage = h('div.ld-stage', ui.svg, ui.msg, ui.zoom, ui.status);
    ui.left = h('aside.ld-left.scroll', { 'aria-label': 'Library and layers' });
    ui.right = h('aside.ld-right.scroll', { 'aria-label': 'Inspector' });
    ui.body = h('div.ld-body', ui.left, ui.stage, ui.right);
    ui.top = h('div.ld-top', { role: 'toolbar', 'aria-label': 'Layout tools' });
    ui.pv = h('div.ld-pv-bar');
    ui.file = h('input.hidden', { type: 'file', accept: 'image/png,image/jpeg,image/webp', 'aria-hidden': 'true', tabindex: '-1' });
    ui.file.addEventListener('change', onFile);
    ui.root = h('div.ld', ui.top, ui.body, ui.pv, ui.file);
    VF.mount(container, ui.root);

    ui.svg.addEventListener('pointerdown', onDown);
    ui.svg.addEventListener('pointermove', onMove);
    ui.svg.addEventListener('pointerup', onUp);
    ui.svg.addEventListener('pointercancel', onUp);
    ui.svg.addEventListener('wheel', onWheel, { passive: false });
    ui.svg.addEventListener('auxclick', function (e) { e.preventDefault(); });
    document.addEventListener('keydown', onKey); document.addEventListener('keyup', onKeyUp);
    window.addEventListener('resize', onResize);
    if (typeof ResizeObserver === 'function') { ui.ro = new ResizeObserver(function () { if (!ui) return; var v = view(); if (v.auto) fit(); applyView(); }); ui.ro.observe(ui.stage); }

    repaint();
    var mine2 = ui;
    /* Sized once the shell has mounted the container: on the next frame, and by timer where frames are held back. */
    requestAnimationFrame(function () { if (ui === mine2) onResize(); });
    setTimeout(function () { if (ui === mine2) onResize(); }, 0);
  }

  Studio.register({
    id: 'layout', title: 'Layout Designer', icon: 'map', group: 'Venue', order: 4,
    render: render,
    dispose: teardown,
    onIssues: function () { paintIssues(); }
  });
})();
