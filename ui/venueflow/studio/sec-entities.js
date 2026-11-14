/* Installer Studio: the entity editors.
   Sections: devices (discovery and display mapping), sources, zones (audio),
   groups (display groups), ambient (lighting and shades), rooms (room panels)
   and profiles (staff profiles).

   Every section is a list on the left and an editor for the selected item on
   the right. The selection lives in a module variable, so the re-render that
   follows each change keeps the same item open. Changes go through
   Studio.update (silently) followed by a re-render that waits for the pointer
   to be released and puts the keyboard focus back where it was, so a click on
   the next control right after typing is not lost. */
(function () {
  'use strict';
  var h = VF.h, icon = VF.icon, S = Studio;
  var MINE = { devices: 1, sources: 1, zones: 1, groups: 1, ambient: 1, rooms: 1, profiles: 1 };

  /* ── a re-render that keeps the installer's place ────────────────────── */
  var wanted = false, timer = null, downAt = 0, downEl = null, changedEl = null;
  document.addEventListener('pointerdown', function (e) { downAt = Date.now(); downEl = e.target; }, true);
  ['pointerup', 'pointercancel'].forEach(function (n) { document.addEventListener(n, function () { downAt = 0; if (wanted) later(60); }, true); });
  document.addEventListener('click', function () { downAt = 0; }, true);
  document.addEventListener('change', function (e) { changedEl = e.target; downAt = 0; }, true);
  document.addEventListener('focusin', function (e) { var t = e.target; if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA')) t._enInit = t.value; }, true);
  function later(ms) { clearTimeout(timer); timer = setTimeout(run, ms || 0); }
  function refresh() { wanted = true; later(0); }

  function labelOf(el) {
    var own = el.getAttribute('aria-label'); if (own) return own;
    var wrap = el.closest('label, .en-fld');
    if (wrap) {
      for (var i = 0; i < wrap.childNodes.length; i++) {
        var n = wrap.childNodes[i];
        if (n.nodeType === 3 && n.textContent.trim()) return n.textContent.trim();
        if (n.nodeType === 1 && n.tagName === 'SPAN') return n.textContent.trim();
      }
    }
    return el.tagName === 'BUTTON' ? el.textContent.trim().slice(0, 40) : '';
  }
  function focusKey(el) { var scope = el.closest('[data-fk]'); return (scope ? scope.dataset.fk : '') + '|' + el.tagName + '|' + (el.type || '') + '|' + labelOf(el); }
  function findByKey(root, key) {
    var all = root.querySelectorAll('input, select, textarea, button');
    for (var i = 0; i < all.length; i++) { if (focusKey(all[i]) === key) return all[i]; }
    return null;
  }
  function run() {
    if (!wanted) return;
    if (!MINE[S.currentSection()]) { wanted = false; return; }
    if (downAt && Date.now() - downAt < 700) { later(90); return; }   /* let the click land first */
    var main = document.getElementById('main'); if (!main) return;
    var a = document.activeElement, inside = !!(a && a !== document.body && main.contains(a));
    if (inside && a.tagName === 'SELECT' && a !== changedEl && a === downEl) {   /* a pick list opened by touch or mouse would close */
      if (!a._enWait) {
        a._enWait = true;
        var go = function () { a._enWait = false; a.removeEventListener('blur', go); a.removeEventListener('change', go); later(0); };
        a.addEventListener('blur', go); a.addEventListener('change', go);
      }
      return;
    }
    var keep = null;
    if (inside) {
      keep = { key: focusKey(a), value: null, s: null, e: null };
      if ((a.tagName === 'INPUT' && a.type !== 'checkbox' && a.type !== 'radio') || a.tagName === 'TEXTAREA') {
        if (a !== changedEl && a._enInit !== undefined && a.value !== a._enInit) keep.value = a.value;   /* typed, not committed yet */
        try { keep.s = a.selectionStart; keep.e = a.selectionEnd; } catch (e) { /* number fields have no selection */ }
      }
    }
    var scrolls = {};
    main.querySelectorAll('[data-en-scroll]').forEach(function (el) { scrolls[el.dataset.enScroll] = el.scrollTop; });
    wanted = false; changedEl = null; downEl = null;
    S.refresh();
    main.querySelectorAll('[data-en-scroll]').forEach(function (el) { var v = scrolls[el.dataset.enScroll]; if (v) el.scrollTop = v; });
    if (!keep) return;
    var el = findByKey(main, keep.key); if (!el) return;
    try { el.focus({ preventScroll: true }); } catch (e) { el.focus(); }
    if (keep.value !== null && el.value !== keep.value) {
      el.value = keep.value;
      var fired = false;
      el.addEventListener('change', function () { fired = true; });
      el.addEventListener('blur', function () { if (!fired) el.dispatchEvent(new Event('change', { bubbles: true })); });
    }
    if (keep.s !== null && keep.s !== undefined) { try { el.setSelectionRange(keep.s, keep.e); } catch (e) { /* ignore */ } }
  }

  /* ── small helpers ───────────────────────────────────────────────────── */
  function upd(label, fn) { S.update(label, fn, { silent: true }); refresh(); }
  function edit(field, id, label, fn) { upd(label, function (c) { var x = VF.byId(c[field], id); if (x) fn(x, c); }); }
  function schema() { return (S.boot && S.boot.schema) || {}; }
  function limitOf(field) { var l = VF.asMap(schema().limits); return l[field] || 9999; }
  function atLimit(field, plural) {
    if (S.list(field).length < limitOf(field)) return false;
    VF.toast('This configuration already holds the most ' + plural + ' it can (' + limitOf(field) + ').', 'warn'); return true;
  }
  function uniqueName(field, base) {
    var names = S.list(field).map(function (x) { return x.name; });
    if (names.indexOf(base) < 0) return base;
    for (var n = 2; ; n++) { if (names.indexOf(base + ' ' + n) < 0) return base + ' ' + n; }
  }
  function words(s) { s = String(s || '').replace(/_/g, ' '); return s.charAt(0).toUpperCase() + s.slice(1); }
  function plural(n, one, many) { return n + ' ' + (n === 1 ? one : (many || one + 's')); }
  function multiFloor() { return S.list('floors').length > 1; }
  function areaText(areaId) {
    var a = S.find('areas', areaId); if (!a) return areaId ? '(missing area)' : 'No area';
    return multiFloor() ? S.nameOf('floors', a.floorId, '?') + ' · ' + a.name : a.name;
  }
  function areaOptions(floorId) {
    return S.list('areas').filter(function (a) { return !floorId || a.floorId === floorId; }).map(function (a) { return { value: a.id, label: floorId ? a.name : areaText(a.id) }; });
  }
  function opts(values, labels) { return VF.asList(values).map(function (v) { return { value: v, label: (labels && labels[v]) || words(v) }; }); }
  function fld(label, control, hint) { return h('div.en-fld', h('span.en-fld-l', label), control, hint ? h('span.hint', hint) : null); }
  function card(title, body, extra) { return h('div.card.col.en-card', h('div.row.between', h('h3', title), extra || null), body); }
  function note(text, kind, ic) { return h('div.banner.' + (kind || 'info') + '.en-note', icon(ic || 'info', 'sm'), h('div.small', text)); }
  function nameField(label, value, apply) {
    return S.text(label, value, function (v) {
      if (!v) { VF.toast('A name is needed.', 'warn'); refresh(); return; }
      apply(v);
    });
  }
  /* A new item is named first, so its permanent id says what it is. -> Promise(name | null) */
  function askName(title, field, base) {
    return VF.prompt(title, 'Name', uniqueName(field, base), 'Add').then(function (v) { return typeof v === 'string' && v.trim() ? v.trim().slice(0, 80) : null; });
  }
  /* Brings a newly selected row into view inside its own scrolling list (not on every redraw). */
  var revealed = {};
  function reveal(key, id, row) {
    if (revealed[key] === id) return;
    revealed[key] = id;
    if (!row) return;
    setTimeout(function () {
      if (!row.isConnected) return;
      var box = row.parentNode;
      while (box && box.id !== 'main' && !(box.classList && box.classList.contains('scroll') && /auto|scroll/.test(getComputedStyle(box).overflowY))) box = box.parentNode;
      if (!box || box.id === 'main') return;
      var b = box.getBoundingClientRect(), r = row.getBoundingClientRect(), head = box.querySelector('thead') ? 44 : 0;
      if (r.top < b.top + head) box.scrollTop -= (b.top + head - r.top) + 8;
      else if (r.bottom > b.bottom) box.scrollTop += (r.bottom - b.bottom) + 8;
    }, 0);
  }
  function wait(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  /* Resolves once no key is held. A dialog opened while Enter is still going down would take that same
     key press on its first button (VF.pinPad confirms on Enter and VF.modal focuses Cancel). */
  var keysDown = 0;
  document.addEventListener('keydown', function (e) { if (!e.repeat) keysDown++; }, true);
  document.addEventListener('keyup', function () { keysDown = Math.max(0, keysDown - 1); }, true);
  window.addEventListener('blur', function () { keysDown = 0; });
  function keysReleased() {
    return new Promise(function (resolve) {
      var tries = 0;
      (function check() { if (keysDown === 0 || tries++ > 40) { keysDown = 0; setTimeout(resolve, 40); } else setTimeout(check, 50); })();
    });
  }
  /* Studio.flush answers false while another save is still on its way: try again a few times. */
  function saved(tries) {
    return S.flush().then(function (ok) {
      if (ok) return true;
      if (tries === 0) return false;
      return wait(450).then(function () { return saved((tries === undefined ? 6 : tries) - 1); });
    });
  }

  /* ── issue marks that follow each save without redrawing the form ────── */
  var painters = [];
  function painter(fn) { painters.push(fn); fn(); }
  function chipSlot(kind, id) { var s = h('span.en-slot'); painter(function () { VF.mount(s, S.issueChip(kind, id)); }); return s; }
  function issueSlot(kind, id) { var s = h('div.en-slot'); painter(function () { VF.mount(s, S.issueList(S.issuesFor(kind, id))); }); return s; }
  /* The driver reports a shared Control4 room on only one of the two items. This says it on the other one too. */
  function twinSlot(kind, id, code, twins, why) {
    var s = h('div.en-slot');
    painter(function () {
      var told = S.issuesFor(kind, id).some(function (i) { return i.code === code; });
      VF.mount(s, twins.length && !told ? h('div.banner.bad', icon('alert', 'sm'), h('div.small', twins.map(function (o) { return o.name; }).join(', ') + (twins.length === 1 ? ' is' : ' are') + ' mapped to the same Control4 room. ' + why)) : null);
    });
    return s;
  }
  function onIssues() { painters.forEach(function (fn) { try { fn(); } catch (e) { console.error(e); } }); }

  function section(def) {
    var seen = null;
    S.register({
      id: def.id, title: def.title, icon: def.icon, group: def.group || 'Venue', order: def.order, onIssues: onIssues,
      render: function (container, params) {
        painters = [];
        if (!S.hasDraft()) { S.emptyDraft(container); return; }
        if (params && params !== seen) { seen = params; def.open(params); }
        def.render(container);
      }
    });
  }

  /* ── list and editor frames ──────────────────────────────────────────── */
  /* rows: [{ id, icon | lead (node), title, sub, right: [nodes] }] */
  function listPanel(key, rows, selId, onPick, emptyText, head) {
    var list = h('div.list'), selRow = null;
    rows.forEach(function (r) {
      var row = list.appendChild(h('button.item.clickable.en-item' + (r.id === selId ? '.sel' : ''), { type: 'button', 'aria-label': r.title, 'aria-current': r.id === selId ? 'true' : null, dataset: { fk: key + ':' + r.id }, onclick: function () { onPick(r.id); } },
        r.lead || icon(r.icon || 'square'),
        h('div.grow', h('div.en-item-t' + (r.wrap ? '' : '.ellipsis'), r.title), r.sub ? h('div.small.muted' + (r.wrap ? '' : '.ellipsis'), r.sub) : null, r.wrap && r.right ? h('div.row.tight.wrap.en-item-chips', r.right) : null),
        r.wrap ? null : (r.right || null)));
      if (r.id === selId) selRow = row;
    });
    reveal(key, selId, selRow);
    return h('div.panel.pad.col.en-list.scroll', { dataset: { enScroll: key } }, head || null, rows.length ? list : h('div.empty.small', emptyText));
  }
  function editorHead(kicker, item, onDelete) {
    return h('div.row.between.top', h('div.col.tight.grow', h('h4', kicker), h('h2.ellipsis', item.name || '(no name)'), h('span.tiny.mono.muted', 'id ' + item.id)),
      h('button.btn.sm.danger', { type: 'button', onclick: onDelete }, icon('trash', 'sm'), 'Delete'));
  }
  function pickFirst(list, sel) { if (sel && VF.byId(list, sel)) return sel; return list.length ? list[0].id : null; }
  function nothingSelected(text) { return h('div.empty', text); }

  /* ── discovery (kept for the whole Studio session) ─────────────────────
     Studio.discovered is the last DISCOVER result, for every section that offers Control4 pick lists:
       loaded, loading, at (ms), error, devices [{ id, name, room, roomId, category, online? ... }],
       rooms (the room entries), counts { category: n },
       byCategory(['display', 'projector']), device(id), nameOf(id), refresh(quiet) -> Promise(ok). */
  var disc = { loaded: false, loading: false, at: 0, devices: [], rooms: [], counts: {}, error: null, pending: null };
  function byName(a, b) { return String(a.name || '').localeCompare(String(b.name || ''), undefined, { numeric: true }) || (a.id - b.id); }
  disc.byCategory = function (cats) { return disc.devices.filter(function (d) { return cats.indexOf(d.category) >= 0; }); };
  disc.device = function (id) { for (var i = 0; i < disc.devices.length; i++) { if (disc.devices[i].id === id) return disc.devices[i]; } return null; };
  disc.nameOf = function (id) { var d = disc.device(id); return d ? d.name : null; };
  disc.refresh = function (quiet) {
    if (disc.loading) return disc.pending;
    disc.loading = true; refresh();
    disc.pending = VF.api('DISCOVER', {}, { since: false }).then(function (r) {
      disc.loading = false;
      if (r.ok && r.data) {
        disc.devices = VF.asList(r.data.devices).slice().sort(byName);
        disc.rooms = VF.asList(r.data.rooms).slice().sort(byName);
        if (!disc.rooms.length) disc.rooms = disc.byCategory(['room']);
        disc.counts = VF.asMap(r.data.counts); disc.loaded = true; disc.at = Date.now(); disc.error = null;
        if (!quiet) VF.toast('Found ' + plural(disc.devices.length - disc.rooms.length, 'device') + ' in ' + plural(disc.rooms.length, 'room') + '.', 'ok');
      } else {
        disc.error = r.message || 'The device list could not be read.';
        VF.toast(disc.error, 'bad');
      }
      refresh();
      return r.ok === true;
    });
    return disc.pending;
  };
  S.discovered = disc;

  function discoverButton(primary) {
    return h('button.btn.sm' + (primary ? '.primary' : ''), { type: 'button', disabled: disc.loading, onclick: function () { disc.refresh(); } },
      icon('refresh', 'sm' + (disc.loading ? ' spin' : '')), disc.loading ? 'Looking…' : (disc.loaded ? 'Refresh devices' : 'Discover devices'));
  }
  function discSummary() {
    if (disc.loading) return 'Reading the Control4 project…';
    if (disc.error && !disc.loaded) return disc.error;
    if (!disc.loaded) return 'Not discovered yet. Discovery reads the Control4 project and changes nothing.';
    var c = disc.counts;
    return 'Discovered ' + plural(disc.rooms.length, 'room') + ', ' + plural((c.display || 0) + (c.projector || 0), 'display') + ', ' + plural(c.source || 0, 'source') +
      ' at ' + new Date(disc.at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) + '.';
  }
  /* Pick-list groups: the suggested categories first, then everything else that is not a room. */
  function deviceGroups(cats, label) {
    var first = disc.byCategory(cats);
    var rest = disc.devices.filter(function (d) { return d.category !== 'room' && cats.indexOf(d.category) < 0; });
    return [{ label: label, items: first }, { label: 'Other devices', items: rest }];
  }
  function roomGroups() { return [{ label: 'Rooms', items: disc.rooms }]; }
  function devText(x, extra) { return x.name + ' · ' + x.id + (x.room && x.room !== x.name && x.category !== 'room' ? ' · ' + x.room : '') + (extra ? ' · ' + extra : ''); }

  /* A Control4 id: a pick list of what discovery found AND a box to type the id by hand.
     Discovery is a suggestion; mapping by hand must always be possible. */
  function c4Pick(label, value, groups, onChange, o) {
    o = o || {};
    var sel = h('select.field', { 'aria-label': label });
    sel.appendChild(h('option', { value: '' }, o.none || 'Not mapped'));
    var found = value === undefined || value === null, shown = groups.filter(function (g) { return g.items.length; });
    shown.forEach(function (g) {
      var host = shown.length > 1 ? h('optgroup', { label: g.label }) : sel;
      g.items.forEach(function (x) { var on = !found && x.id === value; if (on) found = true; host.appendChild(h('option', { value: String(x.id), selected: on }, devText(x, o.mark ? o.mark(x) : null))); });
      if (host !== sel) sel.appendChild(host);
    });
    var missing = !found;
    if (missing) sel.appendChild(h('option', { value: String(value), selected: true }, 'Id ' + value + (disc.loaded ? ' (not found by discovery)' : ' (typed by hand)')));
    var num = h('input.field.mono', { type: 'number', min: 1, step: 1, inputmode: 'numeric', placeholder: 'Id', value: value === undefined || value === null ? '' : value, 'aria-label': label + ' id' });
    sel.addEventListener('change', function () { onChange(sel.value === '' ? undefined : Number(sel.value)); });
    num.addEventListener('change', function () {
      if (num.value === '') { onChange(undefined); return; }
      var n = Number(num.value);
      if (!(n > 0) || n !== Math.floor(n)) { VF.toast('A Control4 id is a whole number above zero.', 'warn'); num.value = value === undefined || value === null ? '' : value; return; }
      onChange(n);
    });
    var hint = o.hint || (disc.loaded ? (missing ? 'The last discovery did not find this id. Check it in Composer, or refresh the devices.' : null) : 'Pick from the list after Discover devices, or type the id shown in Composer.');
    return h('div.en-fld', h('span.en-fld-l', label), h('div.en-pick', sel, num), hint ? h('span.hint', hint) : null);
  }

  /* Tick one or many discovered devices. used: { c4 id: name of what already uses it }. -> Promise([device] | null) */
  function pickDiscovered(title, cats, used, intro) {
    var items = disc.byCategory(cats), chosen = {};
    items = items.filter(function (x) { return !used[x.id]; }).concat(items.filter(function (x) { return used[x.id]; }));   /* new ones first */
    var boxes = [];
    var list = h('div.col.tight.en-disclist');
    items.forEach(function (x) {
      var taken = used[x.id];
      var box = h('input', { type: 'checkbox', disabled: !!taken });
      box.addEventListener('change', function () { chosen[x.id] = box.checked; });
      if (!taken) boxes.push({ box: box, id: x.id });
      list.appendChild(h('label.check.en-discrow', box, h('span.grow', x.name, h('span.muted.mono', ' · ' + x.id), x.room && x.room !== x.name ? h('span.muted', ' · ' + x.room) : null),
        taken ? h('span.chip', 'Already added: ' + taken) : (x.online === false ? h('span.chip.warn', 'Offline') : null)));
    });
    function all(on) { boxes.forEach(function (b) { b.box.checked = on; chosen[b.id] = on; }); }
    var body = h('div.col', h('p.muted.small', intro),
      items.length ? h('div.row', h('button.btn.sm', { type: 'button', onclick: function () { all(true); } }, 'Select all new'), h('button.btn.sm.ghost', { type: 'button', onclick: function () { all(false); } }, 'Clear'), h('span.small.muted', plural(boxes.length, 'new device') + ' of ' + items.length)) : null,
      items.length ? list : h('div.empty.small', 'Discovery found nothing of this kind in the Control4 project. Add a blank one and map it by hand.'));
    return VF.modal({ title: title, icon: 'search', wide: true, body: body, actions: [{ label: 'Cancel', kind: 'ghost', value: null }, { label: 'Add selected', kind: 'primary', disabled: !boxes.length, value: function () {
      var out = items.filter(function (x) { return chosen[x.id]; });
      if (!out.length) { VF.toast('Tick at least one device.', 'warn'); return false; }
      return out;
    } }] }).then(function (v) { return Array.isArray(v) ? v : null; });
  }
  function withDiscovery() { return disc.loaded ? Promise.resolve(true) : disc.refresh(true).then(function () { return disc.loaded; }); }

  /* ── key / value parameters of a device command ──────────────────────── */
  function paramValue(text) { var t = String(text).trim(); return /^-?\d+(\.\d+)?$/.test(t) && String(Number(t)) === t ? Number(t) : t; }
  /* write(fn(params)) must apply fn to the stored params object. */
  function paramRows(scope, params, write) {
    var box = h('div.col.tight');
    Object.keys(params).forEach(function (k) {
      var keyIn = h('input.field.mono', { type: 'text', value: k, maxlength: 60, 'aria-label': 'Parameter name' });
      var valIn = h('input.field.mono', { type: 'text', value: String(params[k]), maxlength: 200, 'aria-label': 'Value of ' + k });
      keyIn.addEventListener('change', function () {
        var nk = keyIn.value.trim();
        if (!nk || nk === k) { keyIn.value = k; return; }
        if (Object.prototype.hasOwnProperty.call(params, nk)) { VF.toast('That parameter name is already used.', 'warn'); keyIn.value = k; return; }
        write(function (p) { var copy = {}; Object.keys(p).forEach(function (x) { copy[x === k ? nk : x] = p[x]; delete p[x]; }); Object.assign(p, copy); });
      });
      valIn.addEventListener('change', function () { write(function (p) { p[k] = paramValue(valIn.value); }); });
      box.appendChild(h('div.en-param', { dataset: { fk: scope + ':' + k } }, keyIn, valIn,
        h('button.btn.sm.ghost.icon', { type: 'button', 'aria-label': 'Remove parameter ' + k, onclick: function () { write(function (p) { delete p[k]; }); } }, icon('x', 'sm'))));
    });
    if (!Object.keys(params).length) box.appendChild(h('span.hint', 'No parameters.'));
    box.appendChild(h('div', h('button.btn.sm', { type: 'button', onclick: function () {
      write(function (p) { var n = 'PARAM', i = 1; while (Object.prototype.hasOwnProperty.call(p, n)) n = 'PARAM_' + (++i); p[n] = ''; });
    } }, icon('plus', 'sm'), 'Add parameter')));
    return box;
  }

  /* ── tests against the draft mapping (TEST_DEVICE / TEST_RESULT) ─────── */
  var tests = {}, testHosts = {}, testSource = {};
  var TEST_LABEL = { status: 'Query Status', power_on: 'Test Power On', power_off: 'Test Power Off', route: 'Test Route', source: 'Test Source' };
  function deviceName(id) {
    if (id === undefined || id === null) return 'Not reported';
    if (id === 0) return 'Nothing selected';
    var list = S.list('sources');
    for (var i = 0; i < list.length; i++) { if (list[i].c4DeviceId === id) return list[i].name + ' (device ' + id + ')'; }
    var n = disc.nameOf(id);
    return n ? n + ' (device ' + id + ', not a VenueFlow source)' : 'Device ' + id + ' (not a VenueFlow source)';
  }
  function roomValues(room) {
    if (!room || typeof room !== 'object') return null;
    function row(k, v) { return [h('span.muted', k), h('span', v)]; }
    return h('div.en-kv',
      row('Power', room.power === true ? 'On' : (room.power === false ? 'Off' : 'Not reported')),
      row('Video', deviceName(room.videoDevice)),
      row('Audio', deviceName(room.audioDevice)),
      row('Volume', room.volume === undefined || room.volume === null ? 'Not reported' : String(room.volume)),
      row('Muted', room.muted === true ? 'Yes' : (room.muted === false ? 'No' : 'Not reported')));
  }
  function testResult(t) {
    if (!t) return h('p.small.muted', 'No test run yet. Query Status reads the Control4 room and changes nothing.');
    var title = h('span.en-rb-title', t.label);
    if (t.phase === 'sending') return h('div.col.tight', h('div.row.wrap', title, h('span.chip.teal', h('span.dot.pulse'), 'Saving the mapping and sending')));
    if (t.phase === 'waiting') return h('div.col.tight', h('div.row.wrap', title, h('span.chip.teal', h('span.dot.pulse'), 'Sent, waiting for Control4')), h('p.small.muted', 'The driver reads the room back a few seconds after sending.'));
    if (t.phase === 'error') return h('div.col.tight', h('div.row.wrap', title, h('span.chip.bad', 'Not sent')), h('p.small', t.message || 'The test could not be run.'), t.detail ? h('p.tiny.mono.muted', t.detail) : null);
    var d = t.data || {}, chip, text;
    if (t.status === 'read') {
      if (d.roomId === undefined || d.roomId === null) { chip = h('span.chip.warn', 'No room mapped'); text = 'Map a Control4 room to read its status.'; }
      else if (d.readable) { chip = h('span.chip.info', 'Status read'); text = 'Control4 room ' + d.roomId + ' answered. Nothing was changed.'; }
      else { chip = h('span.chip.warn', 'Unreadable'); text = 'Control4 room ' + d.roomId + ' could not be read. Check the room id.'; }
    } else if (t.status === 'confirmed' && alreadyThere(t)) {
      chip = h('span.chip.warn', icon('alert', 'sm'), 'Confirmed, but nothing changed');
      text = 'The room already reported this before the test, so the readback cannot prove that the command works. ' + (t.test === 'power_on' ? 'Turn it off first, then test again.' : (t.test === 'power_off' ? 'Turn it on first, then test again.' : 'Choose another source and test again.'));
    } else if (t.status === 'confirmed') { chip = h('span.chip.ok', icon('check', 'sm'), 'Confirmed'); text = 'Sent. The Control4 room now reports what was asked for.'; }
    else if (t.status === 'not_confirmed') { chip = h('span.chip.warn', icon('alert', 'sm'), 'Not confirmed'); text = 'Sent, but the Control4 room did not report the change.'; }
    else if (t.status === 'unreadable') { chip = h('span.chip.warn', icon('alert', 'sm'), 'Unreadable'); text = 'Sent, but the Control4 room could not be read afterwards.'; }
    else if (t.status === 'sent_no_feedback') { chip = h('span.chip.info', 'Sent, no feedback'); text = 'Sent. This mapping gives no feedback, so look at the device itself.'; }
    else { chip = h('span.chip.warn', 'No answer'); text = t.message || 'The driver did not report a result.'; }
    var online = d.online === true ? 'Online' : (d.online === false ? 'Not responding' : null);
    return h('div.col.tight',
      h('div.row.wrap', title, chip, h('span.tiny.muted', new Date(t.at).toLocaleTimeString())),
      h('p.small', text),
      t.asked ? h('p.small.muted', 'Asked for: ' + t.asked) : null,
      roomValues(d.room),
      online ? h('div.en-kv', h('span.muted', 'Device link'), h('span', online)) : null);
  }
  /* The driver confirms a test by reading the room afterwards. When the room already said so before
     the command, that reading proves nothing: the room is read first so this can be told apart. */
  function alreadyThere(t) {
    var b = t.before; if (!b || typeof b !== 'object') return false;
    if (t.test === 'route') return t.want !== undefined && b.videoDevice === t.want;
    if (t.test === 'source') return t.want !== undefined && b.audioDevice === t.want;
    if (t.test === 'power_on') return b.power === true;
    if (t.test === 'power_off') return b.power === false;
    return false;
  }
  function busy(key) { var t = tests[key]; return !!t && (t.phase === 'sending' || t.phase === 'waiting'); }
  function paintTest(key) { var host = testHosts[key]; if (host) host.paint(); }
  function finish(key, token, patch) { if (tests[key] !== token) return; Object.assign(token, patch, { at: Date.now() }); paintTest(key); }
  function pollTest(key, token, testId, n) {
    setTimeout(function () {
      if (tests[key] !== token) return;
      VF.api('TEST_RESULT', { testId: testId }, { since: false }).then(function (r) {
        if (!r.ok) { finish(key, token, { phase: 'error', message: r.message, detail: r.detail }); return; }
        if (r.data.status === 'waiting') {
          if (n >= 20) { finish(key, token, { phase: 'done', status: 'none', message: 'The driver did not report a result within 20 seconds.' }); return; }
          pollTest(key, token, testId, n + 1); return;
        }
        finish(key, token, { phase: 'done', status: r.data.status, data: r.data });
      });
    }, 1000);
  }
  /* kind: 'display' | 'zone'. Every test but status asks first, then sends confirm:true. */
  function runTest(kind, id, name, test, sourceId) {
    var key = kind + ':' + id;
    if (busy(key)) { VF.toast('A test is already running here.', 'info'); return; }
    var src = sourceId ? S.find('sources', sourceId) : null;
    var ask = test === 'status' ? Promise.resolve(true) : VF.confirm(TEST_LABEL[test] + ' on ' + name + '?',
      'This sends a real command now. It can interrupt what the venue is ' + (kind === 'zone' ? 'playing' : 'showing') + ' right now.' + (src ? ' Source: ' + src.name + '.' : ''), 'Run the test', 'warn');
    ask.then(function (yes) {
      if (!yes) return;
      var token = { test: test, label: TEST_LABEL[test], phase: 'sending', want: src ? src.c4DeviceId : undefined, asked: test === 'status' ? null : (test === 'power_off' ? 'Power off' : (test === 'power_on' ? 'Power on' + (src ? ' with ' + src.name : '') : (src ? src.name + (src.c4DeviceId ? ' (device ' + src.c4DeviceId + ')' : '') : null))) };
      tests[key] = token; paintTest(key);
      saved().then(function (ok) {
        if (!ok) { finish(key, token, { phase: 'error', message: 'The draft could not be saved, so the driver does not have this mapping yet. Check the save indicator and try again.' }); return; }
        var target = {}; target[kind === 'zone' ? 'zoneId' : 'displayId'] = id;
        var payload = Object.assign({ test: test }, target);
        if (sourceId && test !== 'status' && test !== 'power_off') payload.sourceId = sourceId;
        if (test !== 'status') payload.confirm = true;
        var before = test === 'status' ? Promise.resolve(null) : VF.api('TEST_DEVICE', Object.assign({ test: 'status' }, target), { since: false }).then(function (r) { return r.ok && r.data && r.data.readable ? r.data.room : null; });
        before.then(function (room) {
          if (tests[key] !== token) return;
          token.before = room;
          VF.api('TEST_DEVICE', payload, { since: false }).then(function (r) {
            if (!r.ok) { finish(key, token, { phase: 'error', message: r.message, detail: r.detail }); return; }
            var data = r.data || {};
            if (test === 'status') { finish(key, token, { phase: 'done', status: 'read', data: data }); return; }
            if (data.status && data.status !== 'waiting') { finish(key, token, { phase: 'done', status: data.status, data: data }); return; }
            if (!data.testId) { finish(key, token, { phase: 'done', status: 'none' }); return; }
            finish(key, token, { phase: 'waiting' });
            pollTest(key, token, data.testId, 1);
          });
        });
      });
    });
  }
  /* controls(busy) -> node with the buttons; the block repaints when a test starts and ends. */
  function testBlock(key, controls) {
    var host = h('div.col.en-test');
    host.paint = function () { VF.mount(host, controls(busy(key)), h('div.en-readback', h('h4', 'Readback status'), testResult(tests[key]))); };
    testHosts = {}; testHosts[key] = host;
    host.paint();
    return host;
  }
  function testSourceSelect(key, list, fallback) {
    var value = testSource[key];
    if (!value || !VF.byId(list, value)) value = (fallback && VF.byId(list, fallback)) ? fallback : (list[0] ? list[0].id : undefined);
    testSource[key] = value;
    return S.select('Source for the test', list.map(function (s) { return { value: s.id, label: s.name + (s.c4DeviceId ? '' : ' (not mapped)') }; }), value, function (v) { testSource[key] = v; }, list.length ? {} : { none: 'No source available', disabled: true });
  }

  /* ════════════════════════════════════════════════════════════════════
     1. Devices: discovery and display mapping
     ════════════════════════════════════════════════════════════════════ */
  var dev = { sel: null, area: '', q: '' };
  var cmdStash = {};   /* a custom route command set aside when the strategy changes, given back if it changes back */
  var KIND_LABEL = { tv: 'TV', projector: 'Projector', videowall: 'Video wall' };
  var ROUTE_LABEL = { room: 'Control4 room selects the source', command: 'Custom command', none: 'Cannot be routed' };
  var ROUTE_SHORT = { room: 'Room', command: 'Command', none: 'None' };
  var POWER_LABEL = { room: 'Through the Control4 room', device: 'On and Off sent to the display device', none: 'No power control' };
  var FEEDBACK_LABEL = { room: 'Read back from the Control4 room', none: 'No feedback' };

  function mapState(d) {
    var route = VF.asMap(d.route), missing = [];
    if ((route.strategy === 'room' || d.power === 'room' || d.feedback === 'room') && (d.c4RoomId === undefined || d.c4RoomId === null)) missing.push('Control4 room');
    if (d.power === 'device' && (d.c4DeviceId === undefined || d.c4DeviceId === null)) missing.push('Control4 device');
    if (route.strategy === 'command') { var c = VF.asMap(route.command); if (!(c.deviceId > 0) || !c.name) missing.push('route command'); }
    var controlled = route.strategy !== 'none' || d.power !== 'none' || d.feedback !== 'none';
    return { mapped: controlled && !missing.length, missing: missing, controlled: controlled };
  }
  function displayStatus(d) {
    var list = S.issuesFor('display', d.id), st = mapState(d);
    var errors = list.filter(function (i) { return i.severity === 'error'; });
    var conflict = errors.some(function (i) { return i.code === 'DISPLAY_ROOM_SHARED'; });
    var tip = list.map(function (i) { return i.message; }).join('\n');
    var out = [];
    if (errors.length) out.push(h('span.chip.bad', { title: tip }, icon('alert', 'sm'), conflict ? 'Conflict' : errors.length + ' to fix'));
    else if (!st.mapped) out.push(h('span.chip.warn', { title: st.missing.length ? 'Missing: ' + st.missing.join(', ') : 'No routing, power or feedback is set up.' }, 'Not mapped'));
    else if (disc.loaded && d.c4RoomId && !disc.device(d.c4RoomId)) out.push(h('span.chip.warn', { title: 'The last discovery did not find Control4 room ' + d.c4RoomId + '.' }, 'Room not found'));
    else out.push(h('span.chip.ok', h('span.dot'), 'Mapped'));
    var warnings = list.length - errors.length;
    if (warnings && (errors.length || st.mapped)) out.push(h('span.chip.warn', { title: tip }, icon('alert', 'sm'), String(warnings)));
    return out;
  }
  function roomText(roomId) {
    if (roomId === undefined || roomId === null) return h('span.muted', 'Not set');
    var n = disc.nameOf(roomId);
    return h('span', n ? n + ' · ' : 'Room ', h('span.mono.muted', String(roomId)));
  }
  function blankDisplay(c, name) {
    var floor = c.floors[0];
    return { id: S.freshId('displays', name), name: name, kind: 'tv', floorId: floor ? floor.id : undefined, route: { strategy: 'room' }, sources: 'all', power: 'room', feedback: 'room' };
  }
  function addDisplay() {
    if (atLimit('displays', 'displays')) return;
    askName('Add a display', 'displays', 'Display').then(function (name) {
      if (!name) return;
      var id = null;
      upd('Add display', function (c) { var d = blankDisplay(c, name); id = d.id; c.displays.push(d); });
      dev.sel = id; dev.area = ''; dev.q = '';
    });
  }
  function addDiscoveredDisplays() {
    withDiscovery().then(function (ok) {
      if (!ok) return null;
      var used = {};
      S.list('displays').forEach(function (d) { if (d.c4DeviceId) used[d.c4DeviceId] = d.name; });
      return pickDiscovered('Add displays from discovered devices', ['display', 'projector'], used,
        'Each ticked device becomes a display named after it, mapped to that device and to its Control4 room when Control4 reports one. Place the new displays on the floor in the Layout Designer.');
    }).then(function (picked) {
      if (!picked) return;
      var room = limitOf('displays') - S.list('displays').length;
      if (picked.length > room) { VF.toast('Only ' + plural(Math.max(0, room), 'more display') + ' can be added.', 'warn'); picked = picked.slice(0, Math.max(0, room)); }
      if (!picked.length) return;
      var first = null;
      upd('Add displays from discovered devices', function (c) {
        picked.forEach(function (x) {
          var d = blankDisplay(c, x.name || ('Display ' + x.id));
          d.c4DeviceId = x.id; if (x.roomId) d.c4RoomId = x.roomId;
          if (x.category === 'projector') d.kind = 'projector';
          c.displays.push(d); first = first || d.id;
        });
      });
      dev.sel = first; dev.area = ''; dev.q = '';
      VF.toast(plural(picked.length, 'display') + ' added to the draft.', 'ok');
    });
  }

  function displayInspector(d) {
    var id = d.id, key = 'display:' + id, route = VF.asMap(d.route), cmd = VF.asMap(route.command), params = VF.asMap(cmd.params);
    function ed(label, fn) { edit('displays', id, label, fn); }
    function cmdOf(x) { x.route = VF.asMap(x.route); x.route.command = VF.asMap(x.route.command); x.route.command.params = VF.asMap(x.route.command.params); return x.route.command; }
    var sources = S.list('sources');
    var pickable = sources.filter(function (s) { return s.video !== false || (d.sources !== 'all' && d.sources.indexOf(s.id) >= 0); });
    var allowed = sources.filter(function (s) { return d.sources === 'all' ? s.video !== false : d.sources.indexOf(s.id) >= 0; });
    var roomUsers = {};
    S.list('displays').forEach(function (o) { if (o.id !== id && o.c4RoomId) roomUsers[o.c4RoomId] = 'display ' + o.name; });
    S.list('audioZones').forEach(function (z) { if (z.c4RoomId && !roomUsers[z.c4RoomId]) roomUsers[z.c4RoomId] = 'zone ' + z.name; });
    var st = mapState(d);
    var twins = d.c4RoomId && route.strategy === 'room' ? S.list('displays').filter(function (o) { return o.id !== id && o.c4RoomId === d.c4RoomId && VF.asMap(o.route).strategy === 'room'; }) : [];

    var mapping = card('Control4 mapping', h('div.col',
      c4Pick('Control4 room', d.c4RoomId, roomGroups(), function (v) { ed('Map display room', function (x) { if (v === undefined) delete x.c4RoomId; else x.c4RoomId = v; }); },
        { mark: function (x) { return roomUsers[x.id] ? 'used by ' + roomUsers[x.id] : null; }, hint: disc.loaded && d.c4RoomId && disc.device(d.c4RoomId) ? 'The Control4 room that is this display\'s AV destination.' : null }),
      c4Pick('Control4 device', d.c4DeviceId, deviceGroups(['display', 'projector'], 'Displays'), function (v) { ed('Map display device', function (x) { if (v === undefined) delete x.c4DeviceId; else x.c4DeviceId = v; }); },
        { none: 'None', hint: disc.loaded && d.c4DeviceId && disc.device(d.c4DeviceId) ? 'The display itself: used for its link state and for device power.' : null })),
      h('span.en-slot', st.mapped ? h('span.chip.ok', h('span.dot'), 'Mapped') : h('span.chip.warn', st.missing.length ? 'Missing: ' + st.missing.join(', ') : 'Not controlled')));

    var testing = card('Test this mapping', testBlock(key, function (running) {
      var srcSel = testSourceSelect(key, allowed.filter(function (s) { return s.enabled !== false; }), d.defaultSourceId);
      function go(test) { runTest('display', id, d.name, test, test === 'power_on' && d.power !== 'room' ? undefined : testSource[key]); }
      return h('div.col',
        h('p.small.muted', 'Tests use the draft mapping on this screen, before it is published.'),
        h('div.en-testrow', srcSel,
          h('div.row.wrap',
            h('button.btn.sm', { type: 'button', disabled: running, onclick: function () { go('status'); } }, icon('refresh', 'sm'), 'Query Status'),
            h('button.btn.sm', { type: 'button', disabled: running || d.power === 'none', onclick: function () { go('power_on'); } }, icon('power', 'sm'), 'Test Power On'),
            h('button.btn.sm', { type: 'button', disabled: running || d.power === 'none', onclick: function () { go('power_off'); } }, icon('power', 'sm'), 'Test Power Off'),
            h('button.btn.sm.outline', { type: 'button', disabled: running || route.strategy === 'none' || !testSource[key], onclick: function () { go('route'); } }, icon('route', 'sm'), 'Test Route'))));
    }));

    var routing = card('Video route', h('div.col',
      S.select('Route strategy', opts(schema().routeStrategies || ['room', 'command', 'none'], ROUTE_LABEL), route.strategy, function (v) {
        ed('Route strategy', function (x) {
          x.route = VF.asMap(x.route); x.route.strategy = v || 'room';
          if (v === 'command') { if (!x.route.command && cmdStash[id]) x.route.command = cmdStash[id]; var c = cmdOf(x); if (c.name === undefined) c.name = ''; }
          else if (x.route.command) { cmdStash[id] = x.route.command; delete x.route.command; }   /* no unused command left in the configuration */
        });
      }, { hint: route.strategy === 'room' ? 'Sends SELECT_VIDEO_DEVICE to the Control4 room. Control4\'s own AV bindings decide the path.' : (route.strategy === 'command' ? 'Sends one command you define. No feedback is assumed.' : 'Nothing is sent. Operators cannot change what this display shows.') }),
      route.strategy !== 'command' ? null : h('div.col.en-sub',
        c4Pick('Send the command to', cmd.deviceId, deviceGroups(['video_switch', 'av_over_ip'], 'Video switches'), function (v) { ed('Route command device', function (x) { var c = cmdOf(x); if (v === undefined) delete c.deviceId; else c.deviceId = v; }); }, { none: 'Not chosen' }),
        S.text('Command name', cmd.name, function (v) { ed('Route command name', function (x) { cmdOf(x).name = v; }); }, { placeholder: 'SET_INPUT', max: 60 }),
        fld('Parameters', paramRows('rp:' + id, params, function (fn) { ed('Route command parameters', function (x) { fn(cmdOf(x).params); }); }),
          'A value of ${source} is replaced by the Control4 device id of the chosen source, ${sourceName} by its name. Other values are sent as typed.'))));

    var srcCard = card('Sources', h('div.col',
      S.idPicker('Sources this display can show', 'sources', d.sources, function (v) {
        ed('Display sources', function (x) { x.sources = v; if (v !== 'all' && x.defaultSourceId && v.indexOf(x.defaultSourceId) < 0) delete x.defaultSourceId; });
      }, { items: pickable, allLabel: 'All video sources (including ones added later)' }),
      S.select('Default source', allowed.map(function (s) { return { value: s.id, label: s.name }; }), d.defaultSourceId, function (v) { ed('Default source', function (x) { if (v) x.defaultSourceId = v; else delete x.defaultSourceId; }); },
        { none: 'None', hint: 'Selected when the display is turned on and has no last source.' })));

    var power = card('Power and feedback', h('div.col',
      S.select('Power strategy', opts(schema().powerStrategies || ['room', 'device', 'none'], POWER_LABEL), d.power, function (v) { ed('Power strategy', function (x) { x.power = v || 'room'; }); },
        { hint: d.power === 'room' ? 'Off sends ROOM_OFF to the room. On selects the last or default source.' : (d.power === 'device' ? 'Sends ON and OFF to the Control4 device. No feedback is assumed.' : 'Operators get no power buttons for this display.') }),
      S.select('Feedback', opts(['room', 'none'], FEEDBACK_LABEL), d.feedback, function (v) { ed('Feedback', function (x) { x.feedback = v || 'room'; }); },
        { hint: d.feedback === 'room' ? 'Power and source are confirmed from the room\'s variables.' : 'Changes are shown as Sent, never as Confirmed.' })));

    var groups = S.list('groups');
    var extras = card('Audio zone and groups', h('div.col',
      S.select('Audio zone', S.entityOptions('audioZones'), d.audioZoneId, function (v) { ed('Display audio zone', function (x) { if (v) x.audioZoneId = v; else delete x.audioZoneId; }); },
        { none: 'None', hint: 'What "listen here" offers for this display. It is never an automatic route.' }),
      h('div.col.tight', h('span.en-fld-l', 'Display groups'),
        groups.length ? h('div.en-checks', groups.map(function (g) {
          return S.check(g.name, g.displayIds.indexOf(id) >= 0, function (on) {
            upd('Group membership', function (c) { var gg = VF.byId(c.groups, g.id); if (!gg) return; gg.displayIds = gg.displayIds.filter(function (x) { return x !== id; }); if (on) gg.displayIds.push(id); });
          });
        })) : h('span.hint', 'No display groups yet. Create them under Display Groups.'))));

    return h('div.panel.pad.col.en-editor', { dataset: { fk: 'dev:' + id } },
      editorHead('Mapping inspector', d, function () { S.confirmRemove('display', id, 'display'); }),
      issueSlot('display', id),
      twinSlot('display', id, 'DISPLAY_ROOM_SHARED', twins, 'Displays routed through one room can never show different sources.'),
      h('div.form',
        nameField('Name', d.name, function (v) { ed('Rename display', function (x) { x.name = v; }); }),
        S.select('Kind', opts(schema().displayKinds || ['tv', 'projector', 'videowall'], KIND_LABEL), d.kind, function (v) { ed('Display kind', function (x) { x.kind = v || 'tv'; }); }),
        S.select('Floor', S.entityOptions('floors'), d.floorId, function (v) {
          ed('Display floor', function (x, c) { if (v) x.floorId = v; else delete x.floorId; var a = VF.byId(c.areas, x.areaId); if (a && a.floorId !== x.floorId) delete x.areaId; });
        }, S.find('floors', d.floorId) ? {} : { none: 'Choose a floor' }),
        S.select('Area', areaOptions(d.floorId), d.areaId, function (v) { ed('Display area', function (x, c) { if (v) { x.areaId = v; var a = VF.byId(c.areas, v); if (a && a.floorId) x.floorId = a.floorId; } else delete x.areaId; }); }, { none: 'No area' })),
      d.layout ? null : h('span.hint', 'Not placed on the floor plan yet. The Layout Designer places it.'),
      mapping, testing, routing, srcCard, power, extras);
  }

  function renderDevices(container) {
    var list = S.list('displays');
    dev.sel = pickFirst(list, dev.sel);
    var selected = S.find('displays', dev.sel);

    var counts = h('div.row.wrap.en-counts');
    painter(function () {
      var mapped = 0, issues = 0;
      S.list('displays').forEach(function (d) { if (mapState(d).mapped) mapped++; if (S.issuesFor('display', d.id).some(function (i) { return i.severity === 'error'; })) issues++; });
      VF.mount(counts, h('span.chip', plural(list.length, 'display')), h('span.chip.ok', h('span.dot'), mapped + ' mapped'),
        list.length - mapped ? h('span.chip.warn', (list.length - mapped) + ' not mapped') : null,
        issues ? h('span.chip.bad', icon('alert', 'sm'), plural(issues, 'conflict or error', 'conflicts or errors')) : null);
    });

    var tbody = h('tbody'), rowPainters = [];
    function match(d) {
      if (dev.area === '-' ? !!d.areaId : (dev.area && d.areaId !== dev.area)) return false;
      var q = dev.q.trim().toLowerCase();
      return !q || String(d.name).toLowerCase().indexOf(q) >= 0 || d.id.indexOf(q) >= 0;
    }
    function paintRows() {
      VF.clear(tbody); rowPainters = [];
      var shown = list.filter(match);
      shown.forEach(function (d) {
        var status = h('div.row.tight.wrap');
        rowPainters.push(function () { VF.mount(status, displayStatus(d)); });
        var pick = function () { dev.sel = d.id; refresh(); };
        var tr = tbody.appendChild(h('tr.clickable' + (d.id === dev.sel ? '.sel' : ''), { tabindex: 0, 'aria-label': d.name, onclick: pick, onkeydown: function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); pick(); } } },
          h('td', h('div.row.tight', icon(d.kind === 'projector' ? 'video' : 'tv', 'sm'), h('div.col.tight.en-cellname', h('span.ellipsis', d.name), h('span.tiny.muted.ellipsis.en-compact', areaText(d.areaId))))),
          h('td.en-opt', multiFloor() ? S.nameOf('floors', d.floorId, '?') + ' · ' : '', d.areaId ? S.nameOf('areas', d.areaId) : h('span.muted', 'No area')),
          h('td.en-opt', roomText(d.c4RoomId)),
          h('td.en-opt.en-opt2', ROUTE_SHORT[VF.asMap(d.route).strategy] || '?'),
          h('td.en-opt.en-opt2', d.audioZoneId ? S.nameOf('audioZones', d.audioZoneId) : h('span.muted', 'None')),
          h('td', status)));
        if (d.id === dev.sel) reveal('devices', d.id, tr);
      });
      if (!shown.length) tbody.appendChild(h('tr', h('td.muted', { colspan: 6 }, list.length ? 'No display matches this filter.' : 'No displays yet. Add one, or add from the discovered devices.')));
      rowPainters.forEach(function (fn) { fn(); });
    }
    painter(function () { rowPainters.forEach(function (fn) { fn(); }); });
    paintRows();

    var areaSel = h('select.field', { 'aria-label': 'Filter by area' }, h('option', { value: '' }, 'All areas'),
      S.list('areas').map(function (a) { return h('option', { value: a.id, selected: dev.area === a.id }, areaText(a.id)); }), h('option', { value: '-', selected: dev.area === '-' }, 'No area'));
    areaSel.addEventListener('change', function () { dev.area = areaSel.value; paintRows(); });
    var search = h('input.field', { type: 'search', placeholder: 'Search displays', value: dev.q, 'aria-label': 'Search displays' });
    search.addEventListener('input', function () { dev.q = search.value; paintRows(); });

    VF.mount(container,
      S.sectionHead('Devices', 'Find the Control4 devices in this project and map each display to its Control4 room.', [
        discoverButton(!disc.loaded),
        h('button.btn.sm', { type: 'button', onclick: addDiscoveredDisplays }, icon('search', 'sm'), 'Add from discovered'),
        h('button.btn.sm' + (disc.loaded ? '.primary' : ''), { type: 'button', onclick: addDisplay }, icon('plus', 'sm'), 'Add display')]),
      h('div.row.between.wrap.en-strip', counts, h('span.small.muted', discSummary())),
      S.list('floors').length ? null : note('This draft has no floor yet. A display needs a floor: add one in the Layout Designer.', 'warn', 'alert'),
      h('div.en-dev',
        h('div.panel.en-list.en-devlist.scroll', { dataset: { enScroll: 'devices' } },
          h('div.en-filter', search, areaSel),
          h('table.tbl.en-tbl', h('thead', h('tr', h('th', 'Display'), h('th.en-opt', multiFloor() ? 'Floor / Area' : 'Area'), h('th.en-opt', 'Control4 room'), h('th.en-opt.en-opt2', 'Route'), h('th.en-opt.en-opt2', 'Audio zone'), h('th', 'Status'))), tbody)),
        selected ? displayInspector(selected) : nothingSelected('Add a display to map it to Control4.')));
  }
  section({ id: 'devices', title: 'Devices', icon: 'monitor', order: 1, open: function (p) { if (p.displayId) { dev.sel = p.displayId; dev.area = ''; dev.q = ''; } }, render: renderDevices });

  /* ════════════════════════════════════════════════════════════════════
     2. Sources
     ════════════════════════════════════════════════════════════════════ */
  var src = { sel: null };
  function guessKind(x) {
    var t = (String(x.name) + ' ' + String(x.driverFile || '')).toLowerCase();
    if (t.indexOf('satellite') >= 0) return 'satellite';
    if (t.indexOf('cable') >= 0) return 'cable';
    if (t.indexOf('signage') >= 0 || t.indexOf('brightsign') >= 0) return 'signage';
    if (t.indexOf('roku') >= 0 || t.indexOf('apple') >= 0 || t.indexOf('stream') >= 0) return 'streaming';
    if (t.indexOf('music') >= 0) return 'music';
    if (t.indexOf('camera') >= 0) return 'camera';
    if (t.indexOf('laptop') >= 0) return 'laptop';
    return 'other';
  }
  function addSource() {
    if (atLimit('sources', 'sources')) return;
    askName('Add a source', 'sources', 'Source').then(function (name) {
      if (!name) return;
      var id = S.freshId('sources', name);
      upd('Add source', function (c) { c.sources.push({ id: id, name: name, kind: 'other', video: true, audio: true, enabled: true }); });
      src.sel = id;
    });
  }
  function addDiscoveredSources() {
    withDiscovery().then(function (ok) {
      if (!ok) return null;
      var used = {};
      S.list('sources').forEach(function (s) { if (s.c4DeviceId) used[s.c4DeviceId] = s.name; });
      return pickDiscovered('Add sources from discovered devices', ['source'], used, 'Each ticked device becomes a source named after it and mapped to it. Set what it carries afterwards.');
    }).then(function (picked) {
      if (!picked) return;
      var room = Math.max(0, limitOf('sources') - S.list('sources').length);
      if (picked.length > room) { VF.toast('Only ' + plural(room, 'more source') + ' can be added.', 'warn'); picked = picked.slice(0, room); }
      if (!picked.length) return;
      var first = null;
      upd('Add sources from discovered devices', function (c) {
        picked.forEach(function (x) {
          var name = x.name || ('Source ' + x.id), kind = guessKind(x);
          var s = { id: S.freshId('sources', name), name: name, kind: kind, c4DeviceId: x.id, video: kind !== 'music', audio: kind !== 'signage', enabled: true };
          c.sources.push(s); first = first || s.id;
        });
      });
      src.sel = first;
      VF.toast(plural(picked.length, 'source') + ' added to the draft.', 'ok');
    });
  }
  /* "Default source of X" once per display is a long list: fold those into one line. */
  function shortRefs(refs) {
    var lead = 'Default source of ', names = [], rest = [];
    refs.forEach(function (r) { if (r.indexOf(lead) === 0) names.push(r.slice(lead.length)); else rest.push(r); });
    if (names.length > 3) rest.unshift('Default source of ' + names.length + ' displays (' + names.slice(0, 3).join(', ') + ' and ' + (names.length - 3) + ' more)');
    else rest = names.map(function (n) { return lead + n; }).concat(rest);
    return rest;
  }
  function sourceEditor(s) {
    var id = s.id;
    function ed(label, fn) { edit('sources', id, label, fn); }
    var users = {};
    S.list('sources').forEach(function (o) { if (o.id !== id && o.c4DeviceId) users[o.c4DeviceId] = 'used by ' + o.name; });
    function media(which, other, on) {
      if (!on && s[other] === false) { VF.toast('A source must carry video, audio or both.', 'warn'); refresh(); return; }
      ed('Source media', function (x) { x[which] = on; });
    }
    var refs = S.references('source', id);
    var displays = S.list('displays'), zones = S.list('audioZones');
    var onDisplays = displays.filter(function (d) { return d.sources === 'all' ? s.video !== false : d.sources.indexOf(id) >= 0; }).length;
    var inZones = zones.filter(function (z) { return z.sources === 'all' ? s.audio !== false : z.sources.indexOf(id) >= 0; }).length;
    return h('div.panel.pad.col.en-editor', { dataset: { fk: 'src:' + id } },
      editorHead('Source', s, function () { S.confirmRemove('source', id, 'source'); }),
      issueSlot('source', id),
      h('div.form',
        nameField('Name', s.name, function (v) { ed('Rename source', function (x) { x.name = v; }); }),
        S.select('Kind', opts(schema().sourceKinds || ['other']), s.kind, function (v) { ed('Source kind', function (x) { x.kind = v || 'other'; }); })),
      c4Pick('Control4 device', s.c4DeviceId, deviceGroups(['source'], 'Sources'), function (v) { ed('Map source', function (x) { if (v === undefined) delete x.c4DeviceId; else x.c4DeviceId = v; }); },
        { mark: function (x) { return users[x.id] || null; }, hint: disc.loaded && s.c4DeviceId && disc.device(s.c4DeviceId) ? 'The device id a Control4 room selects to show or play this source.' : null }),
      card('What it carries', h('div.col.tight',
        S.toggle('Carries video', s.video !== false, function (on) { media('video', 'audio', on); }, 'Can be shown on displays.'),
        S.toggle('Carries audio', s.audio !== false, function (on) { media('audio', 'video', on); }, 'Can be played in audio zones.'),
        S.toggle('Enabled', s.enabled !== false, function (on) { ed('Source enabled', function (x) { x.enabled = on; }); }, 'Off: operators cannot choose it.'))),
      card('Where it is used', h('div.col.tight',
        h('div.small', 'Can be shown on ' + onDisplays + ' of ' + plural(displays.length, 'display') + ' and played in ' + inZones + ' of ' + plural(zones.length, 'audio zone') + '.'),
        refs.length ? h('ul.small.en-refs', shortRefs(refs).map(function (r) { return h('li', r); })) : h('div.small.muted', 'No scene, rule or default source uses it.'),
        refs.length ? h('span.hint', 'Deleting this source clears these references.') : null)));
  }
  function renderSources(container) {
    var list = S.list('sources');
    src.sel = pickFirst(list, src.sel);
    var selected = S.find('sources', src.sel);
    var rows = list.map(function (s) {
      return { id: s.id, icon: VF.SOURCE_ICON[s.kind] || 'monitor', title: s.name, sub: words(s.kind) + (s.c4DeviceId ? ' · device ' + s.c4DeviceId : ' · not mapped'),
        right: [s.enabled === false ? h('span.chip', 'Off') : null, s.video === false ? h('span.chip', 'Audio only') : (s.audio === false ? h('span.chip', 'Video only') : null), chipSlot('source', s.id)] };
    });
    VF.mount(container,
      S.sectionHead('Sources', 'What can be shown and played: each one is a Control4 device a room can select.', [
        discoverButton(false),
        h('button.btn.sm', { type: 'button', onclick: addDiscoveredSources }, icon('search', 'sm'), 'Add from discovered'),
        h('button.btn.sm.primary', { type: 'button', onclick: addSource }, icon('plus', 'sm'), 'Add source')]),
      h('div.split',
        listPanel('sources', rows, src.sel, function (id) { src.sel = id; refresh(); }, 'No sources yet.'),
        selected ? sourceEditor(selected) : nothingSelected('Add a source to map it to a Control4 device.')));
  }
  section({ id: 'sources', title: 'Sources', icon: 'cable', order: 2, open: function (p) { if (p.sourceId) src.sel = p.sourceId; }, render: renderSources });

  /* ════════════════════════════════════════════════════════════════════
     3. Audio zones
     ════════════════════════════════════════════════════════════════════ */
  var zon = { sel: null };
  function num(v, fallback) { return typeof v === 'number' ? v : fallback; }
  function addZone() {
    if (atLimit('audioZones', 'audio zones')) return;
    askName('Add an audio zone', 'audioZones', 'Audio zone').then(function (name) {
      if (!name) return;
      var id = S.freshId('audioZones', name);
      upd('Add audio zone', function (c) { c.audioZones.push({ id: id, name: name, sources: 'all', minVolume: 0, maxVolume: 100, presets: [], can: { volume: true, mute: true, source: true, power: true }, feedback: 'room' }); });
      zon.sel = id;
    });
  }
  function zoneEditor(z) {
    var id = z.id, key = 'zone:' + id, lo = num(z.minVolume, 0), hi = num(z.maxVolume, 100), can = VF.asMap(z.can);
    function ed(label, fn) { edit('audioZones', id, label, fn); }
    var sources = S.list('sources');
    var pickable = sources.filter(function (s) { return s.audio !== false || (z.sources !== 'all' && z.sources.indexOf(s.id) >= 0); });
    var allowed = sources.filter(function (s) { return z.sources === 'all' ? s.audio !== false : z.sources.indexOf(s.id) >= 0; });
    var roomUsers = {};
    S.list('audioZones').forEach(function (o) { if (o.id !== id && o.c4RoomId) roomUsers[o.c4RoomId] = 'zone ' + o.name; });
    S.list('displays').forEach(function (d) { if (d.c4RoomId && !roomUsers[d.c4RoomId]) roomUsers[d.c4RoomId] = 'display ' + d.name; });
    var twins = z.c4RoomId ? S.list('audioZones').filter(function (o) { return o.id !== id && o.c4RoomId === z.c4RoomId; }) : [];
    var coupled = z.c4RoomId ? S.list('displays').filter(function (d) { return d.c4RoomId === z.c4RoomId; }) : [];
    function range(which, v) {
      ed('Volume range', function (x) {
        var a = num(x.minVolume, 0), b = num(x.maxVolume, 100);
        v = VF.clamp(Math.round(v === undefined ? (which === 'min' ? 0 : 100) : v), 0, 100);
        if (which === 'min') { a = v; if (b < a) b = a; } else { b = v; if (a > b) a = b; }
        x.minVolume = a; x.maxVolume = b;
        if (typeof x.defaultVolume === 'number') x.defaultVolume = VF.clamp(x.defaultVolume, a, b);
      });
    }
    var presets = h('div.col.tight');
    z.presets.forEach(function (p) {
      var off = typeof p.level === 'number' && (p.level < lo || p.level > hi);
      presets.appendChild(h('div.en-row3', { dataset: { fk: 'zp:' + p.id } },
        S.text('Preset name', p.name, function (v) { if (!v) { VF.toast('A name is needed.', 'warn'); refresh(); return; } ed('Rename volume preset', function (x) { var q = VF.byId(x.presets, p.id); if (q) q.name = v; }); }),
        S.number('Level', p.level, function (v) { ed('Volume preset level', function (x) { var q = VF.byId(x.presets, p.id); if (q) q.level = VF.clamp(Math.round(v === undefined ? lo : v), num(x.minVolume, 0), num(x.maxVolume, 100)); }); }, { min: 0, max: 100, hint: off ? 'Outside the zone range: played at ' + VF.clamp(p.level, lo, hi) + '.' : null }),
        h('button.btn.sm.ghost.icon', { type: 'button', 'aria-label': 'Delete preset ' + p.name, onclick: function () { ed('Delete volume preset', function (x) { x.presets = x.presets.filter(function (q) { return q.id !== p.id; }); }); } }, icon('trash', 'sm'))));
    });
    if (!z.presets.length) presets.appendChild(h('span.hint', 'No presets. Operators still get the volume slider.'));
    presets.appendChild(h('div', h('button.btn.sm', { type: 'button', disabled: z.presets.length >= 12, onclick: function () {
      VF.prompt('Add a volume preset', 'Name', 'Preset ' + (z.presets.length + 1), 'Add').then(function (n) {
        if (typeof n !== 'string' || !n.trim()) return;
        n = n.trim().slice(0, 80);
        ed('Add volume preset', function (x) { x.presets.push({ id: VF.freshId(n, x.presets), name: n, level: VF.clamp(num(x.defaultVolume, Math.round((num(x.minVolume, 0) + num(x.maxVolume, 100)) / 2)), num(x.minVolume, 0), num(x.maxVolume, 100)) }); });
      });
    } }, icon('plus', 'sm'), 'Add preset')));

    var testing = card('Test this zone', testBlock(key, function (running) {
      var srcSel = testSourceSelect(key, allowed.filter(function (s) { return s.enabled !== false; }));
      return h('div.col',
        h('p.small.muted', 'Tests use the draft mapping on this screen, before it is published.'),
        h('div.en-testrow', srcSel, h('div.row.wrap',
          h('button.btn.sm', { type: 'button', disabled: running, onclick: function () { runTest('zone', id, z.name, 'status'); } }, icon('refresh', 'sm'), 'Query Status'),
          h('button.btn.sm.outline', { type: 'button', disabled: running || !testSource[key], onclick: function () { runTest('zone', id, z.name, 'source', testSource[key]); } }, icon('volume', 'sm'), 'Test Source'))));
    }));

    return h('div.panel.pad.col.en-editor', { dataset: { fk: 'zone:' + id } },
      editorHead('Audio zone', z, function () { S.confirmRemove('zone', id, 'audio zone'); }),
      issueSlot('audioZone', id),
      twinSlot('audioZone', id, 'ZONE_ROOM_SHARED', twins, 'Two audio zones cannot share a room: they would always play the same thing.'),
      coupled.length ? note('Shared Control4 room: ' + coupled.map(function (d) { return d.name; }).join(', ') + (coupled.length === 1 ? ' uses' : ' use') + ' the same Control4 room as this zone. In that room Control4 moves the sound with the picture, so changing what the display shows also changes what this zone plays. That is allowed. Give the zone its own Control4 room if the two should be independent.', 'warn', 'alert') : null,
      h('div.form',
        nameField('Name', z.name, function (v) { ed('Rename audio zone', function (x) { x.name = v; }); }),
        S.select('Area', areaOptions(), z.areaId, function (v) { ed('Zone area', function (x, c) { if (v) { x.areaId = v; var a = VF.byId(c.areas, v); if (a && a.floorId) x.floorId = a.floorId; } else delete x.areaId; }); }, { none: 'No area' })),
      c4Pick('Control4 room', z.c4RoomId, roomGroups(), function (v) { ed('Map zone room', function (x) { if (v === undefined) delete x.c4RoomId; else x.c4RoomId = v; }); },
        { mark: function (x) { return roomUsers[x.id] ? 'used by ' + roomUsers[x.id] : null; }, hint: disc.loaded && z.c4RoomId && disc.device(z.c4RoomId) ? 'The Control4 room whose audio this zone is. Two zones cannot share a room.' : null }),
      testing,
      card('Sources', S.idPicker('Sources this zone can play', 'sources', z.sources, function (v) { ed('Zone sources', function (x) { x.sources = v; }); }, { items: pickable, allLabel: 'All audio sources (including ones added later)' })),
      card('Volume', h('div.col',
        h('div.form.en-form3',
          S.number('Minimum', lo, function (v) { range('min', v); }, { min: 0, max: 100 }),
          S.number('Maximum', hi, function (v) { range('max', v); }, { min: 0, max: 100 }),
          S.number('Default', z.defaultVolume, function (v) { ed('Default volume', function (x) { if (v === undefined) delete x.defaultVolume; else x.defaultVolume = VF.clamp(Math.round(v), num(x.minVolume, 0), num(x.maxVolume, 100)); }); }, { min: 0, max: 100, placeholder: 'None' })),
        h('span.hint', 'Every level an operator, a scene or a preset asks for is kept between the minimum and the maximum.'),
        h('span.en-fld-l', 'Volume presets'), presets)),
      card('What operators can do', h('div.col.tight',
        h('div.en-checks',
          ['volume', 'mute', 'source', 'power'].map(function (k) {
            return S.check({ volume: 'Change the volume', mute: 'Mute', source: 'Choose the source', power: 'Turn the zone off' }[k], can[k] !== false, function (on) { ed('Zone capability', function (x) { x.can = VF.asMap(x.can); x.can[k] = on; }); });
          })),
        S.select('Feedback', opts(['room', 'none'], FEEDBACK_LABEL), z.feedback, function (v) { ed('Zone feedback', function (x) { x.feedback = v || 'room'; }); }))));
  }
  function renderZones(container) {
    var list = S.list('audioZones');
    zon.sel = pickFirst(list, zon.sel);
    var selected = S.find('audioZones', zon.sel);
    var rows = list.map(function (z) {
      return { id: z.id, icon: 'volume', title: z.name, sub: (z.areaId ? areaText(z.areaId) : 'No area') + (z.c4RoomId ? ' · room ' + z.c4RoomId : ' · not mapped'), right: [chipSlot('audioZone', z.id)] };
    });
    VF.mount(container,
      S.sectionHead('Audio Zones', 'Each zone is one Control4 room whose sound operators control on its own.', [
        discoverButton(false),
        h('button.btn.sm.primary', { type: 'button', onclick: addZone }, icon('plus', 'sm'), 'Add audio zone')]),
      h('div.split',
        listPanel('zones', rows, zon.sel, function (id) { zon.sel = id; refresh(); }, 'No audio zones yet.'),
        selected ? zoneEditor(selected) : nothingSelected('Add an audio zone to map it to a Control4 room.')));
  }
  section({ id: 'zones', title: 'Audio Zones', icon: 'volume', order: 3, open: function (p) { if (p.zoneId) zon.sel = p.zoneId; }, render: renderZones });

  /* ════════════════════════════════════════════════════════════════════
     4. Display groups
     ════════════════════════════════════════════════════════════════════ */
  var grp = { sel: null };
  var SWATCHES = ['#2dd4bf', '#60a5fa', '#34d399', '#a78bfa', '#f5a524', '#f87171', '#f472b6', '#94a3b8'];
  function addGroup() {
    if (atLimit('groups', 'display groups')) return;
    askName('Add a display group', 'groups', 'Group').then(function (name) {
      if (!name) return;
      var id = S.freshId('groups', name);
      upd('Add display group', function (c) { c.groups.push({ id: id, name: name, color: SWATCHES[c.groups.length % SWATCHES.length], displayIds: [] }); });
      grp.sel = id;
    });
  }
  function groupEditor(g) {
    var id = g.id;
    function ed(label, fn) { edit('groups', id, label, fn); }
    var displays = S.list('displays'), known = {};
    displays.forEach(function (d) { known[d.id] = true; });
    var missing = g.displayIds.filter(function (x) { return !known[x]; });
    var buckets = [], index = {};
    function bucket(k, label) { if (!index[k]) { index[k] = { label: label, items: [] }; buckets.push(index[k]); } return index[k]; }
    S.list('areas').forEach(function (a) { bucket(a.id, areaText(a.id)); });
    displays.forEach(function (d) { (S.find('areas', d.areaId) ? bucket(d.areaId) : bucket('-', 'No area')).items.push(d); });
    function setMany(ids, on) {
      ed('Group members', function (x) { x.displayIds = x.displayIds.filter(function (i) { return ids.indexOf(i) < 0; }); if (on) x.displayIds = x.displayIds.concat(ids); });
    }
    var members = h('div.col');
    buckets.filter(function (b) { return b.items.length; }).forEach(function (b) {
      var ids = b.items.map(function (d) { return d.id; }), inCount = ids.filter(function (i) { return g.displayIds.indexOf(i) >= 0; }).length;
      var all = h('input', { type: 'checkbox', checked: inCount === ids.length });
      all.indeterminate = inCount > 0 && inCount < ids.length;
      all.addEventListener('change', function () { setMany(ids, all.checked); });
      members.appendChild(h('div.col.tight.en-bucket', { dataset: { fk: 'gb:' + b.label } },
        h('label.check.en-bucket-h', all, h('span', b.label), h('span.muted.small', inCount + ' of ' + ids.length)),
        h('div.en-checks', b.items.map(function (d) { return S.check(d.name, g.displayIds.indexOf(d.id) >= 0, function (on) { setMany([d.id], on); }); }))));
    });
    if (!displays.length) members.appendChild(h('span.hint', 'No displays yet. Add them under Devices.'));
    return h('div.panel.pad.col.en-editor', { dataset: { fk: 'grp:' + id } },
      editorHead('Display group', g, function () { S.confirmRemove('group', id, 'display group'); }),
      issueSlot('group', id),
      missing.length ? h('div.banner.warn', icon('alert', 'sm'), h('div.grow.small', plural(missing.length, 'member') + ' no longer exist.'), h('button.btn.sm', { type: 'button', onclick: function () { setMany(missing, false); } }, 'Remove them')) : null,
      nameField('Name', g.name, function (v) { ed('Rename display group', function (x) { x.name = v; }); }),
      h('div.col.tight', h('span.en-fld-l', 'Colour'), h('div.row.wrap.tight', SWATCHES.map(function (c) {
        return h('button.en-swatch' + (g.color === c ? '.on' : ''), { type: 'button', 'aria-label': 'Colour ' + c, 'aria-pressed': g.color === c ? 'true' : 'false', style: { background: c }, onclick: function () { ed('Group colour', function (x) { x.color = c; }); } }, g.color === c ? icon('check', 'sm') : null);
      }))),
      card('Members', members, h('span.chip', plural(g.displayIds.length - missing.length, 'display'))));
  }
  function renderGroups(container) {
    var list = S.list('groups');
    grp.sel = pickFirst(list, grp.sel);
    var selected = S.find('groups', grp.sel);
    var rows = list.map(function (g) {
      return { id: g.id, lead: h('span.en-dot', { style: { background: g.color || 'var(--muted)' } }), title: g.name, sub: plural(g.displayIds.length, 'display'), right: [chipSlot('group', g.id)] };
    });
    VF.mount(container,
      S.sectionHead('Display Groups', 'Sets of displays operators and scenes address together.', [h('button.btn.sm.primary', { type: 'button', onclick: addGroup }, icon('plus', 'sm'), 'Add group')]),
      h('div.split',
        listPanel('groups', rows, grp.sel, function (id) { grp.sel = id; refresh(); }, 'No display groups yet.'),
        selected ? groupEditor(selected) : nothingSelected('Add a group, then tick the displays that belong to it.')));
  }
  section({ id: 'groups', title: 'Display Groups', icon: 'layers', order: 5, open: function (p) { if (p.groupId) grp.sel = p.groupId; }, render: renderGroups });

  /* ════════════════════════════════════════════════════════════════════
     5. Lighting and shades
     ════════════════════════════════════════════════════════════════════ */
  var amb = { kind: 'lighting', sel: null };
  var LIGHT_COMMANDS = {
    ACTIVATE_SCENE: { label: 'Activate a lighting scene (ACTIVATE_SCENE)', hint: 'Send to the Advanced Lighting Scenes agent.', fields: [{ key: 'SCENE_ID', label: 'Scene id (SCENE_ID)', min: 0 }] },
    RAMP_TO_LEVEL: { label: 'Ramp a light to a level (RAMP_TO_LEVEL)', hint: 'Send to a light.', fields: [{ key: 'LEVEL', label: 'Level, 0 to 100 (LEVEL)', min: 0, max: 100 }, { key: 'TIME', label: 'Ramp time in milliseconds (TIME)', min: 0 }] },
    SET_BRIGHTNESS_TARGET: { label: 'Set a brightness target (SET_BRIGHTNESS_TARGET)', hint: 'Send to a light.', fields: [{ key: 'LIGHT_BRIGHTNESS_TARGET', label: 'Brightness, 0 to 100 (LIGHT_BRIGHTNESS_TARGET)', min: 0, max: 100 }, { key: 'RATE', label: 'Rate in milliseconds (RATE)', min: 0 }] }
  };
  function addLighting() {
    if (atLimit('lighting', 'lighting controls')) return;
    askName('Add a lighting control', 'lighting', 'Lighting').then(function (name) {
      if (!name) return;
      var id = S.freshId('lighting', name);
      upd('Add lighting control', function (c) { c.lighting.push({ id: id, name: name, presets: [] }); });
      amb.kind = 'lighting'; amb.sel = id;
    });
  }
  function addShade() {
    if (atLimit('shades', 'shades')) return;
    askName('Add a shade', 'shades', 'Shades').then(function (name) {
      if (!name) return;
      var id = S.freshId('shades', name);
      upd('Add shade', function (c) { c.shades.push({ id: id, name: name, openLevel: 100, closedLevel: 0 }); });
      amb.kind = 'shade'; amb.sel = id;
    });
  }
  /* Scene and rule steps that run one lighting preset. */
  function presetUsers(lightingId, presetId) {
    var out = [], c = S.config();
    function scan(owner, label) { S.eachStep(owner.program.steps, function (st) { if (st.type === 'lighting' && st.lightingId === lightingId && st.presetId === presetId && out.indexOf(label) < 0) out.push(label); }); }
    c.scenes.forEach(function (s) { scan(s, 'Scene ' + s.name); });
    c.rules.forEach(function (r) { scan(r, 'Rule ' + r.name); });
    return out;
  }
  function removePreset(l, p) {
    var users = presetUsers(l.id, p.id);
    var body = h('div.col', h('p', 'Delete lighting preset "' + p.name + '" from ' + l.name + '?'),
      users.length ? h('div.banner.warn', icon('alert'), h('div', h('div', 'It is used in ' + plural(users.length, 'place') + '. Those steps will have no lighting chosen:'), h('ul.small.en-refs', users.map(function (u) { return h('li', u); })))) : null,
      h('p.small.muted', 'This changes the VenueFlow draft only. Nothing in the Control4 project is deleted or changed.'));
    VF.modal({ title: 'Delete lighting preset', icon: 'trash', body: body, actions: [{ label: 'Cancel', kind: 'ghost', value: null }, { label: 'Delete', kind: 'danger', value: true }] }).then(function (yes) {
      if (yes !== true) return;
      upd('Delete lighting preset', function (c) {
        var x = VF.byId(c.lighting, l.id); if (!x) return;
        x.presets = x.presets.filter(function (q) { return q.id !== p.id; });
        function scrub(owner) { S.eachStep(owner.program.steps, function (st) { if (st.type === 'lighting' && st.lightingId === l.id && st.presetId === p.id) { delete st.lightingId; delete st.presetId; } }); }   /* as the shell does for a deleted lighting control */
        c.scenes.forEach(scrub); c.rules.forEach(scrub);
      });
    });
  }
  function lightingEditor(l) {
    var id = l.id;
    function ed(label, fn) { edit('lighting', id, label, fn); }
    function edPreset(pid, label, fn) { ed(label, function (x) { var q = VF.byId(x.presets, pid); if (q) { q.params = VF.asMap(q.params); fn(q); } }); }
    var presets = h('div.col');
    l.presets.forEach(function (p) {
      var known = LIGHT_COMMANDS[p.command], params = VF.asMap(p.params);
      var commandOptions = Object.keys(LIGHT_COMMANDS).map(function (k) { return { value: k, label: LIGHT_COMMANDS[k].label }; }).concat([{ value: '*', label: 'Custom command' }]);
      var body;
      if (known) {
        body = h('div.form', known.fields.map(function (f) {
          return S.number(f.label, typeof params[f.key] === 'number' ? params[f.key] : (params[f.key] !== undefined && params[f.key] !== '' && !isNaN(Number(params[f.key])) ? Number(params[f.key]) : undefined), function (v) {
            edPreset(p.id, 'Lighting preset parameter', function (q) { if (v === undefined) delete q.params[f.key]; else q.params[f.key] = v; });
          }, { min: f.min, max: f.max });
        }));
      } else {
        body = h('div.col',
          S.text('Command name', p.command, function (v) { edPreset(p.id, 'Lighting preset command', function (q) { q.command = v; }); }, { placeholder: 'COMMAND_NAME', max: 60 }),
          fld('Parameters', paramRows('lp:' + p.id, params, function (fn) { edPreset(p.id, 'Lighting preset parameters', function (q) { fn(q.params); }); }), 'Whole numbers are sent as numbers, everything else as typed.'));
      }
      presets.appendChild(h('div.card.col.en-preset', { dataset: { fk: 'lpre:' + p.id } },
        h('div.row.top', h('div.grow', S.text('Preset name', p.name, function (v) { if (!v) { VF.toast('A name is needed.', 'warn'); refresh(); return; } edPreset(p.id, 'Rename lighting preset', function (q) { q.name = v; }); })),
          h('button.btn.sm.ghost.icon.en-rowbtn', { type: 'button', 'aria-label': 'Delete preset ' + p.name, onclick: function () { removePreset(l, p); } }, icon('trash', 'sm'))),
        c4Pick('Control4 device', p.deviceId, deviceGroups(['lighting_scene', 'light'], 'Lighting'), function (v) { edPreset(p.id, 'Lighting preset device', function (q) { if (v === undefined) delete q.deviceId; else q.deviceId = v; }); }, { none: 'Not chosen' }),
        S.select('Command', commandOptions, known ? p.command : '*', function (v) {
          edPreset(p.id, 'Lighting preset command', function (q) {
            if (v === '*' || !LIGHT_COMMANDS[v]) { q.command = ''; q.params = {}; return; }
            var next = {}; LIGHT_COMMANDS[v].fields.forEach(function (f) { if (typeof q.params[f.key] === 'number') next[f.key] = q.params[f.key]; });
            q.command = v; q.params = next;
          });
        }, { hint: known ? known.hint : 'One command of your own, sent to the device as typed.' }),
        body));
    });
    if (!l.presets.length) presets.appendChild(h('div.empty.small', 'No presets yet. A preset is one command to one Control4 device.'));
    presets.appendChild(h('div', h('button.btn.sm', { type: 'button', disabled: l.presets.length >= 24, onclick: function () {
      VF.prompt('Add a lighting preset', 'Name', 'Preset ' + (l.presets.length + 1), 'Add').then(function (n) {
        if (typeof n !== 'string' || !n.trim()) return;
        n = n.trim().slice(0, 80);
        ed('Add lighting preset', function (x) { x.presets.push({ id: VF.freshId(n, x.presets), name: n, command: 'ACTIVATE_SCENE', params: {} }); });
      });
    } }, icon('plus', 'sm'), 'Add preset')));
    return h('div.panel.pad.col.en-editor', { dataset: { fk: 'lit:' + id } },
      editorHead('Lighting control', l, function () { S.confirmRemove('lighting', id, 'lighting control'); }),
      issueSlot('lighting', id),
      h('div.form',
        nameField('Name', l.name, function (v) { ed('Rename lighting control', function (x) { x.name = v; }); }),
        S.select('Area', areaOptions(), l.areaId, function (v) { ed('Lighting area', function (x) { if (v) x.areaId = v; else delete x.areaId; }); }, { none: 'No area' })),
      card('Presets', presets, h('span.chip', plural(l.presets.length, 'preset'))));
  }
  function shadeEditor(s) {
    var id = s.id;
    function ed(label, fn) { edit('shades', id, label, fn); }
    function level(key) { return function (v) { ed('Shade level', function (x) { if (v === undefined) delete x[key]; else x[key] = VF.clamp(Math.round(v), 0, 100); }); }; }
    return h('div.panel.pad.col.en-editor', { dataset: { fk: 'shd:' + id } },
      editorHead('Shade', s, function () { S.confirmRemove('shade', id, 'shade'); }),
      issueSlot('shade', id),
      h('div.form',
        nameField('Name', s.name, function (v) { ed('Rename shade', function (x) { x.name = v; }); }),
        S.select('Area', areaOptions(), s.areaId, function (v) { ed('Shade area', function (x) { if (v) x.areaId = v; else delete x.areaId; }); }, { none: 'No area' })),
      c4Pick('Control4 device', s.deviceId, deviceGroups(['shade'], 'Shades'), function (v) { ed('Map shade', function (x) { if (v === undefined) delete x.deviceId; else x.deviceId = v; }); }, { hint: disc.loaded && s.deviceId && disc.device(s.deviceId) ? 'Open and Close send SET_LEVEL_TARGET to this device.' : null }),
      h('div.form',
        S.number('Open level', s.openLevel, level('openLevel'), { min: 0, max: 100, placeholder: '100', hint: 'Sent for Open. Empty means 100.' }),
        S.number('Closed level', s.closedLevel, level('closedLevel'), { min: 0, max: 100, placeholder: '0', hint: 'Sent for Close. Empty means 0.' })));
  }
  function renderAmbient(container) {
    var lights = S.list('lighting'), shades = S.list('shades');
    var field = amb.kind === 'shade' ? 'shades' : 'lighting';
    if (!S.find(field, amb.sel)) {
      if (lights.length) { amb.kind = 'lighting'; amb.sel = lights[0].id; }
      else if (shades.length) { amb.kind = 'shade'; amb.sel = shades[0].id; }
      else amb.sel = null;
    }
    var selected = amb.sel ? S.find(amb.kind === 'shade' ? 'shades' : 'lighting', amb.sel) : null;
    function head(title, onAdd, label) { return h('div.row.between', h('h3', title), h('button.btn.sm', { type: 'button', onclick: onAdd }, icon('plus', 'sm'), label)); }
    var lightRows = lights.map(function (l) { return { id: l.id, icon: 'bulb', title: l.name, sub: (l.areaId ? areaText(l.areaId) + ' · ' : '') + plural(l.presets.length, 'preset'), right: [chipSlot('lighting', l.id)] }; });
    var shadeRows = shades.map(function (s) { return { id: s.id, icon: 'blinds', title: s.name, sub: (s.areaId ? areaText(s.areaId) + ' · ' : '') + (s.deviceId ? 'device ' + s.deviceId : 'not mapped'), right: [chipSlot('shade', s.id)] }; });
    var subs = VF.asMap(S.config().venue.subsystems);
    VF.mount(container,
      S.sectionHead('Lighting and Shades', 'Lighting presets and shade positions operators and scenes can use.', [discoverButton(false)]),
      note('These commands are sent to Control4 without feedback. VenueFlow shows them as Sent, never as Confirmed, so check the room itself when you set them up.'),
      h('div.split.en-gap',
        h('div.col.en-stack.scroll', { dataset: { enScroll: 'stack' } },
          listPanel('lighting', lightRows, amb.kind === 'lighting' ? amb.sel : null, function (id) { amb.kind = 'lighting'; amb.sel = id; refresh(); }, 'No lighting controls yet.', head('Lighting', addLighting, 'Add lighting')),
          listPanel('shades', shadeRows, amb.kind === 'shade' ? amb.sel : null, function (id) { amb.kind = 'shade'; amb.sel = id; refresh(); }, 'No shades yet.', head('Shades', addShade, 'Add shade')),
          (subs.lighting === false && lights.length) || (subs.shades === false && shades.length) ? h('span.hint', 'The venue settings have ' + (subs.lighting === false && lights.length ? 'lighting' : 'shades') + ' switched off as a subsystem.') : null),
        selected ? (amb.kind === 'shade' ? shadeEditor(selected) : lightingEditor(selected)) : nothingSelected('Add a lighting control or a shade.')));
  }
  section({ id: 'ambient', title: 'Lighting and Shades', icon: 'bulb', order: 6, open: function (p) {
    if (p.lightingId) { amb.kind = 'lighting'; amb.sel = p.lightingId; } else if (p.shadeId) { amb.kind = 'shade'; amb.sel = p.shadeId; }
  }, render: renderAmbient });

  /* ════════════════════════════════════════════════════════════════════
     6. Room panels (Simplified Room Control)
     ════════════════════════════════════════════════════════════════════ */
  var rom = { sel: null };
  var MAX_BUTTONS = 6;
  function addRoom() {
    if (atLimit('rooms', 'room panels')) return;
    askName('Add a room panel', 'rooms', 'Room panel').then(function (name) {
      if (!name) return;
      var id = S.freshId('rooms', name);
      upd('Add room panel', function (c) { c.rooms.push({ id: id, name: name, buttons: [], shadeIds: [], showSources: false }); });
      rom.sel = id;
    });
  }
  function panelPreview(r) {
    var zone = S.find('audioZones', r.volumeZoneId), light = S.find('lighting', r.lightingId);
    var shades = r.shadeIds.map(function (i) { return S.find('shades', i); }).filter(Boolean);
    return h('div.en-prev', { 'aria-label': 'Preview of the panel' },
      h('div.row.between', h('span.en-prev-t', r.name || 'Room'), h('span.tiny.muted', 'Preview')),
      r.buttons.length ? h('div.en-prev-grid', r.buttons.map(function (b) {
        return h('div.en-prev-btn' + (S.find('scenes', b.sceneId) ? '' : '.off'), VF.sceneIcon(b.icon, 'lg'), h('span', b.label || S.nameOf('scenes', b.sceneId, 'No scene')));
      })) : h('div.small.muted', 'No buttons yet.'),
      zone ? h('div.en-prev-line', icon('volume', 'sm'), h('span.grow', 'Volume · ' + zone.name), h('span.en-prev-bar', h('i'))) : null,
      light ? h('div.en-prev-line', icon('bulb', 'sm'), h('div.row.wrap.tight', light.presets.length ? light.presets.map(function (p) { return h('span.chip', p.name); }) : h('span.small.muted', 'No presets'))) : null,
      shades.length ? h('div.en-prev-line', icon('blinds', 'sm'), h('span.grow', shades.map(function (s) { return s.name; }).join(', ')), h('span.chip', 'Open'), h('span.chip', 'Close')) : null,
      r.showSources ? h('div.en-prev-line', icon('monitor', 'sm'), h('span', 'Source picker' + (VF.asList(r.displayIds).length ? ' for ' + plural(VF.asList(r.displayIds).length, 'display') : ''))) : null);
  }
  function roomEditor(r) {
    var id = r.id, scenes = S.list('scenes');
    function ed(label, fn) { edit('rooms', id, label, fn); }
    function edButton(bid, label, fn) { ed(label, function (x) { var b = VF.byId(x.buttons, bid); if (b) fn(b, x); }); }
    var iconKeys = Object.keys(VF.SCENE_ICON);
    var buttons = h('div.col.tight');
    r.buttons.forEach(function (b, i) {
      function move(by) { ed('Reorder room buttons', function (x) { var at = x.buttons.findIndex(function (q) { return q.id === b.id; }), to = at + by; if (at < 0 || to < 0 || to >= x.buttons.length) return; var t = x.buttons[at]; x.buttons[at] = x.buttons[to]; x.buttons[to] = t; }); }
      buttons.appendChild(h('div.card.en-btnrow', { dataset: { fk: 'rb:' + b.id } },
        h('span.en-btnicon', VF.sceneIcon(b.icon, 'lg')),
        h('div.form.grow',
          S.text('Label', b.label, function (v) { edButton(b.id, 'Room button label', function (q) { q.label = v; }); }, { max: 40, placeholder: S.nameOf('scenes', b.sceneId, 'Label') }),
          S.select('Scene', S.entityOptions('scenes'), b.sceneId, function (v) {
            edButton(b.id, 'Room button scene', function (q, x) {
              var old = VF.byId(S.list('scenes'), q.sceneId), next = VF.byId(S.list('scenes'), v);
              if (v) q.sceneId = v; else delete q.sceneId;
              if (next && (!q.label || (old && q.label === old.name))) { q.label = next.name; if (next.icon && VF.SCENE_ICON[next.icon]) q.icon = next.icon; }
            });
          }, S.find('scenes', b.sceneId) ? {} : { none: 'Choose a scene' }),
          S.select('Icon', iconKeys.map(function (k) { return { value: k, label: words(k) }; }), b.icon, function (v) { edButton(b.id, 'Room button icon', function (q) { if (v) q.icon = v; else delete q.icon; }); }, VF.SCENE_ICON[b.icon] ? {} : { none: 'Default' })),
        h('div.col.tight.en-rowbtns',
          h('button.btn.sm.ghost.icon', { type: 'button', disabled: i === 0, 'aria-label': 'Move ' + (b.label || 'button') + ' up', onclick: function () { move(-1); } }, icon('arrow-up', 'sm')),
          h('button.btn.sm.ghost.icon', { type: 'button', disabled: i === r.buttons.length - 1, 'aria-label': 'Move ' + (b.label || 'button') + ' down', onclick: function () { move(1); } }, icon('arrow-down', 'sm')),
          h('button.btn.sm.ghost.icon', { type: 'button', 'aria-label': 'Delete ' + (b.label || 'button'), onclick: function () { ed('Delete room button', function (x) { x.buttons = x.buttons.filter(function (q) { return q.id !== b.id; }); }); } }, icon('trash', 'sm')))));
    });
    if (!r.buttons.length) buttons.appendChild(h('span.hint', 'No buttons yet. Each button runs one scene.'));
    buttons.appendChild(h('div.row.wrap',
      h('button.btn.sm', { type: 'button', disabled: r.buttons.length >= MAX_BUTTONS || !scenes.length, onclick: function () {
        ed('Add room button', function (x) {
          if (x.buttons.length >= MAX_BUTTONS) return;
          var taken = x.buttons.map(function (q) { return q.sceneId; });
          var sc = S.list('scenes').filter(function (s) { return taken.indexOf(s.id) < 0; })[0];
          x.buttons.push({ id: VF.freshId(sc ? sc.name : 'button', x.buttons), label: sc ? sc.name : 'Button', icon: sc && VF.SCENE_ICON[sc.icon] ? sc.icon : 'star', sceneId: sc ? sc.id : undefined });
        });
      } }, icon('plus', 'sm'), 'Add button'),
      h('span.hint', scenes.length ? r.buttons.length + ' of ' + MAX_BUTTONS + ' buttons.' : 'Create a scene first: a button runs a scene.'),
      scenes.length ? null : h('button.btn.sm.ghost', { type: 'button', onclick: function () { S.go('scenes'); } }, 'Open Scenes', icon('arrow-right', 'sm'))));
    return h('div.panel.pad.col.en-editor', { dataset: { fk: 'room:' + id } },
      editorHead('Room panel', r, function () { S.confirmRemove('room', id, 'room panel'); }),
      issueSlot('room', id),
      h('div.form',
        nameField('Name', r.name, function (v) { ed('Rename room panel', function (x) { x.name = v; }); }),
        S.select('Area', areaOptions(), r.areaId, function (v) { ed('Room panel area', function (x) { if (v) x.areaId = v; else delete x.areaId; }); }, { none: 'No area' })),
      panelPreview(r),
      card('Buttons', buttons),
      card('Optional controls', h('div.col',
        h('div.form',
          S.select('Volume zone', S.entityOptions('audioZones'), r.volumeZoneId, function (v) { ed('Room panel volume zone', function (x) { if (v) x.volumeZoneId = v; else delete x.volumeZoneId; }); }, { none: 'No volume control', hint: 'Shows volume and mute for this zone.' }),
          S.select('Lighting control', S.entityOptions('lighting'), r.lightingId, function (v) { ed('Room panel lighting', function (x) { if (v) x.lightingId = v; else delete x.lightingId; }); }, { none: 'No lighting', hint: 'Shows its presets.' })),
        S.idPicker('Shades (Open and Close)', 'shades', r.shadeIds, function (v) { ed('Room panel shades', function (x) { x.shadeIds = v; }); }, { allowAll: false }),
        S.toggle('Show the source picker', r.showSources === true, function (on) { ed('Room panel source picker', function (x) { x.showSources = on; }); }, 'Lets staff choose what the displays below show.'),
        S.idPicker('Displays the source picker acts on', 'displays', VF.asList(r.displayIds), function (v) { ed('Room panel displays', function (x) { x.displayIds = v; }); }, { allowAll: false }))));
  }
  function renderRooms(container) {
    var list = S.list('rooms');
    rom.sel = pickFirst(list, rom.sel);
    var selected = S.find('rooms', rom.sel);
    var rows = list.map(function (r) { return { id: r.id, icon: 'square', title: r.name, sub: (r.areaId ? areaText(r.areaId) + ' · ' : '') + plural(r.buttons.length, 'button'), right: [chipSlot('room', r.id)] }; });
    VF.mount(container,
      S.sectionHead('Room Panels', 'The Simplified Room Control interface: a few big buttons for one room.', [h('button.btn.sm.primary', { type: 'button', onclick: addRoom }, icon('plus', 'sm'), 'Add room panel')]),
      h('div.split',
        listPanel('rooms', rows, rom.sel, function (id) { rom.sel = id; refresh(); }, 'No room panels yet.'),
        selected ? roomEditor(selected) : nothingSelected('Add a room panel for a meeting room, a host stand or any place that needs only a few buttons.')));
  }
  section({ id: 'rooms', title: 'Room Panels', icon: 'square', order: 7, open: function (p) { var id = p.roomId || p.panelId; if (id) rom.sel = id; }, render: renderRooms });

  /* ════════════════════════════════════════════════════════════════════
     7. Staff profiles
     ════════════════════════════════════════════════════════════════════ */
  var pro = { sel: null };
  var ROLE_LABEL = { installer: 'Installer', owner: 'Owner', manager: 'Manager', bartender: 'Bartender', host: 'Host', conference_staff: 'Conference Staff', restricted: 'Restricted Operator' };
  var IFACE_LABEL = { floorplan: 'Floor Plan', command: 'Command Center', room: 'Room Control', manager: 'Manager Overview' };
  var FLAG_LABEL = {
    routeVideo: ['Change what displays show', 'Route a source to a display.'],
    power: ['Turn displays on and off', null],
    audio: ['Control audio', 'Source, volume and mute of audio zones.'],
    lighting: ['Use lighting presets', null],
    shades: ['Open and close shades', null],
    scenes: ['Run scenes', null],
    venueStatus: ['Mark the venue open or closed', null],
    allOff: ['Use All Off', 'Turns every display and zone off.'],
    viewAlerts: ['See alerts', 'Devices that did not confirm or are not responding.']
  };
  function roleLabel(r) { return ROLE_LABEL[r] || words(r); }
  function addProfile() {
    if (atLimit('profiles', 'staff profiles')) return;
    var templates = VF.asList(schema().profileTemplates), closer = null;
    var list = h('div.list');
    templates.forEach(function (t) {
      var perms = VF.asMap(t.permissions), on = VF.asList(schema().permissionFlags).filter(function (f) { return perms[f] === true; });
      list.appendChild(h('button.item.clickable.en-item', { type: 'button', onclick: function () { if (closer) closer(t); } },
        icon(t.role === 'installer' ? 'wrench' : 'user'), h('div.grow', h('div.en-item-t', t.name),
          h('div.small.muted', VF.asList(t.interfaces).map(function (i) { return IFACE_LABEL[i] || i; }).join(', ')),
          h('div.tiny.muted', on.length === VF.asList(schema().permissionFlags).length ? 'Every permission' : (on.map(function (f) { return FLAG_LABEL[f] ? FLAG_LABEL[f][0] : f; }).join(' · ') || 'No permission'))),
        icon('chevron-right', 'sm')));
    });
    VF.modal({ title: 'Add a staff profile', icon: 'users', body: h('div.col', h('p.muted.small', 'Start from a role. Everything can be changed afterwards.'), list), actions: [{ label: 'Cancel', kind: 'ghost', value: null }], onOpen: function (close) { closer = close; } }).then(function (t) {
      if (!t || typeof t !== 'object') return;
      var name = uniqueName('profiles', t.name), id = S.freshId('profiles', name);
      upd('Add staff profile', function (c) {
        var p = VF.clone(t); p.id = id; p.name = name; p.interfaces = VF.asList(p.interfaces); p.permissions = VF.asMap(p.permissions); delete p.hasPin;
        c.profiles.push(p);
      });
      pro.sel = id;
    });
  }
  function stationsOf(profileId) { return S.list('stations').filter(function (st) { return st && st.profileId === profileId; }); }
  function setPin(p) {
    var isDefault = S.config().defaultProfileId === p.id, stations = stationsOf(p.id);
    var why = [];
    if (isDefault) why.push('A tile opens as this profile. With a PIN on it, tiles will ask everyone to sign in until you choose another profile.');
    if (stations.length) why.push((stations.length === 1 ? 'Station ' : 'Stations ') + stations.map(function (st) { return st.name; }).join(', ') + (stations.length === 1 ? ' opens' : ' open') + ' as this profile. A station cannot use a profile that has a PIN, so ' + (stations.length === 1 ? 'it' : 'they') + ' will be reported as an error until given another profile.');
    var first = why.length ? VF.confirm('Set a PIN for ' + p.name + '?', why.join(' '), 'Set a PIN anyway', 'warn') : Promise.resolve(true);
    first.then(function (yes) {
      if (!yes) return null;
      return keysReleased().then(function () { return VF.pinPad('New PIN for ' + p.name, '4 to 8 digits'); });
    }).then(function (pin) {
      if (!pin) return null;
      return keysReleased().then(function () { return VF.pinPad('Enter the PIN again', 'To be sure it was typed as meant'); }).then(function (again) {
        if (!again) return null;
        if (again !== pin) { VF.toast('The two PINs were not the same. Nothing was changed.', 'warn'); return null; }
        return pin;
      });
    }).then(function (pin) {
      if (!pin) return;
      if (S.config().defaultProfileId === p.id) S.update('Tile profile', function (c) { delete c.defaultProfileId; }, { silent: true });
      S.serverEdit('PROFILE_PIN_SET', { profileId: p.id, pin: pin }).then(function (r) {
        if (r.ok && r.data && r.data.hasPin === true) VF.toast('PIN set for ' + p.name + '.', 'ok');
        else VF.toast(r.message || 'The PIN was not set.', 'bad');
      });
    });
  }
  function removePin(p) {
    VF.confirm('Remove the PIN of ' + p.name + '?', 'Staff will no longer be able to sign in as this profile. Without a PIN it can only be the profile a tile or a station opens with.', 'Remove the PIN', 'danger').then(function (yes) {
      if (!yes) return;
      S.serverEdit('PROFILE_PIN_SET', { profileId: p.id, pin: '' }).then(function (r) {
        if (r.ok && r.data && r.data.hasPin === false) VF.toast('PIN removed from ' + p.name + '.', 'ok');
        else VF.toast(r.message || 'The PIN was not removed.', 'bad');
      });
    });
  }
  function profileEditor(p) {
    var id = p.id, perms = VF.asMap(p.permissions), all = VF.asList(schema().interfaces).length ? VF.asList(schema().interfaces) : Object.keys(IFACE_LABEL);
    function ed(label, fn) { edit('profiles', id, label, fn); }
    function perm(key) { return function (v) { ed('Profile permission', function (x) { x.permissions = VF.asMap(x.permissions); x.permissions[key] = v; }); }; }
    var isDefault = S.config().defaultProfileId === id;
    return h('div.panel.pad.col.en-editor', { dataset: { fk: 'pro:' + id } },
      editorHead('Staff profile', p, function () { S.confirmRemove('profile', id, 'staff profile'); }),
      issueSlot('profile', id),
      h('div.form',
        nameField('Name', p.name, function (v) { ed('Rename staff profile', function (x) { x.name = v; }); }),
        S.select('Role', opts(schema().roles || Object.keys(ROLE_LABEL), ROLE_LABEL), p.role, function (v) { ed('Profile role', function (x) { x.role = v || 'restricted'; }); }, { hint: 'A label for the kind of staff. The switches below decide what the profile can do.' })),
      card('PIN', h('div.row.wrap.between',
        h('div.col.tight.grow', p.hasPin ? h('span.chip.ok', icon('lock', 'sm'), 'PIN set') : h('span.chip.warn', icon('unlock', 'sm'), 'No PIN'),
          h('span.hint', p.hasPin ? 'Staff choose this profile on the sign-in pad and type its PIN. The PIN is never shown and is not part of the configuration.' : (isDefault ? 'A tile opens as this profile without asking.' : 'Without a PIN staff cannot sign in as this profile. It can only be the profile a tile or a station opens with.'))),
        h('div.row.wrap',
          h('button.btn.sm', { type: 'button', onclick: function () { setPin(p); } }, icon('key', 'sm'), p.hasPin ? 'Change PIN' : 'Set PIN'),
          p.hasPin ? h('button.btn.sm.danger', { type: 'button', onclick: function () { removePin(p); } }, 'Remove PIN') : null))),
      card('Interfaces', h('div.col',
        h('div.en-checks', all.map(function (k) {
          return S.check(IFACE_LABEL[k] || words(k), p.interfaces.indexOf(k) >= 0, function (on) {
            if (!on && p.interfaces.length <= 1) { VF.toast('A profile needs at least one interface.', 'warn'); refresh(); return; }
            ed('Profile interfaces', function (x) {
              x.interfaces = all.filter(function (i) { return i === k ? on : x.interfaces.indexOf(i) >= 0; });
              if (x.interfaces.indexOf(x.defaultInterface) < 0) x.defaultInterface = x.interfaces[0];
            });
          });
        })),
        S.select('Opens with', p.interfaces.map(function (k) { return { value: k, label: IFACE_LABEL[k] || words(k) }; }), p.defaultInterface, function (v) { ed('Profile default interface', function (x) { if (v) x.defaultInterface = v; }); }))),
      card('What this profile may do', h('div.col.tight',
        VF.asList(schema().permissionFlags).map(function (f) { var l = FLAG_LABEL[f] || [words(f), null]; return S.toggle(l[0], perms[f] === true, perm(f), l[1]); }))),
      card('Where it applies', h('div.col',
        h('span.hint', 'A display is available to this profile when both its floor and its area are.'),
        S.idPicker('Floors', 'floors', perms.floors, perm('floors')),
        S.idPicker('Areas', 'areas', perms.areas, perm('areas'), { items: S.list('areas').map(function (a) { return { id: a.id, name: areaText(a.id) }; }) }),
        S.idPicker('Sources', 'sources', perms.sources, perm('sources')),
        S.idPicker('Audio zones', 'audioZones', perms.zones, perm('zones')),
        S.idPicker('Scenes', 'scenes', perms.sceneIds, perm('sceneIds')))));
  }
  function renderProfiles(container) {
    var list = S.list('profiles'), c = S.config();
    pro.sel = pickFirst(list, pro.sel);
    var selected = S.find('profiles', pro.sel);
    var rows = list.map(function (p) {
      return { id: p.id, icon: p.role === 'installer' ? 'wrench' : 'user', title: p.name, wrap: true, sub: roleLabel(p.role) + ' · ' + p.interfaces.map(function (i) { return IFACE_LABEL[i] || i; }).join(', '),
        right: [c.defaultProfileId === p.id ? h('span.chip.teal', { title: 'A tile opens as this profile' }, icon('star', 'sm'), 'Tile') : null,
          p.hasPin ? h('span.chip.ok', { title: 'Has a PIN' }, icon('lock', 'sm'), 'PIN') : h('span.chip', { title: 'No PIN' }, 'No PIN'), chipSlot('profile', p.id)] };
    });
    var open = list.filter(function (p) { return !p.hasPin; }), current = S.find('profiles', c.defaultProfileId);
    var tileOptions = open.map(function (p) { return { value: p.id, label: p.name }; });
    if (current && current.hasPin) tileOptions.push({ value: current.id, label: current.name + ' (has a PIN: not allowed)' });
    var tile = h('div.panel.pad.col.tight.en-tile',
      S.select('A tile opens as', tileOptions, current ? c.defaultProfileId : '', function (v) { upd('Tile profile', function (x) { if (v) x.defaultProfileId = v; else delete x.defaultProfileId; }); },
        { none: 'Ask everyone to sign in', hint: 'A Navigator tile opens as this profile without a PIN. Only profiles without a PIN can be chosen. Staff with a PIN sign in from the tile.' }));
    VF.mount(container,
      S.sectionHead('Staff Profiles', 'Who uses the screens, which interfaces they get and what they may do.', [h('button.btn.sm.primary', { type: 'button', onclick: addProfile }, icon('plus', 'sm'), 'Add profile')]),
      note('Permissions are enforced by the driver, not by the screens: a screen only hides what the driver would refuse. Changing the configuration is not a profile permission. It always needs the Installer Passcode.', 'info', 'shield'),
      h('div.split.en-gap',
        h('div.col.en-stack.scroll', { dataset: { enScroll: 'stack' } }, tile, listPanel('profiles', rows, pro.sel, function (id) { pro.sel = id; refresh(); }, 'No staff profiles yet. Add at least one.')),
        selected ? profileEditor(selected) : nothingSelected('Add a staff profile from a role template.')));
  }
  section({ id: 'profiles', title: 'Staff Profiles', icon: 'users', group: 'Access', order: 1, open: function (p) { if (p.profileId) pro.sel = p.profileId; }, render: renderProfiles });
})();
