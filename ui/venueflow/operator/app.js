/* VenueFlow operator page: the shell (sign-in, header, interface switcher,
   activity strip) and everything the four interfaces share (selection, routing,
   scenes, All Off, audio zone control, the floor plan drawing).
   Each interface file registers itself with Operator.register(id, factory).
   Rules: ui/venueflow/README.md. The driver is the authority: nothing here
   says "done" for something the driver has not confirmed. */
var Operator = (function () {
  'use strict';
  var h = VF.h;
  var O = {};
  var SVGNS = 'http://www.w3.org/2000/svg';
  var XLINK = 'http://www.w3.org/1999/xlink';
  var root = null;
  var ui = null;            // the shell's elements, null while a full-screen notice or sign-in is up
  var current = null;       // { id, view }
  var live = [];            // extra painters (open sheets)
  var factories = {};

  O.INTERFACES = {
    floorplan: { label: 'Floor Plan', icon: 'map' },
    command: { label: 'Command Center', icon: 'grid' },
    room: { label: 'Room Control', icon: 'home' },
    manager: { label: 'Manager', icon: 'bars' }
  };
  var ORDER = ['floorplan', 'command', 'room', 'manager'];
  var ROLE = { installer: 'Installer', owner: 'Owner', manager: 'Manager', bartender: 'Bartender', host: 'Host', conference_staff: 'Conference staff', restricted: 'Room panel' };

  /* ── small helpers ───────────────────────────────────────────────────── */
  O.svg = function (tag, attrs) {
    var el = document.createElementNS(SVGNS, tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        var v = attrs[k];
        if (v === undefined || v === null || v === false) return;
        if (k.slice(0, 2) === 'on' && typeof v === 'function') el.addEventListener(k.slice(2), v);
        else el.setAttribute(k, String(v));
      });
    }
    for (var i = 2; i < arguments.length; i++) {
      var c = arguments[i];
      if (c === undefined || c === null || c === false) continue;
      el.appendChild(c instanceof Node ? c : document.createTextNode(String(c)));
    }
    return el;
  };
  O.setText = function (el, text) { text = text == null ? '' : String(text); if (el._t !== text) { el._t = text; el.textContent = text; } };
  O.setClass = function (el, name, on) { on = !!on; if (el.classList.contains(name) !== on) el.classList.toggle(name, on); };
  O.setAttr = function (el, name, value) { value = String(value); if (el.getAttribute(name) !== value) el.setAttribute(name, value); };
  /* Rebuilds `el` only when `sig` changed since the last call. */
  O.patch = function (el, sig, build) { if (el._sig === sig) return false; el._sig = sig; VF.mount(el, build()); return true; };
  O.plural = function (n, word) { return n + ' ' + word + (n === 1 ? '' : 's'); };
  O.doc = function () { return VF.state.doc || {}; };
  O.list = function (name) { return (O.lists && O.lists[name]) || []; };
  O.find = function (name, id) { return (O.ix && O.ix[name] && O.ix[name][id]) || null; };
  O.can = function (flag) { return !!O.profile && (O.profile.system || O.profile.can[flag] === true); };
  O.sourceName = function (id) { var s = O.find('sources', id); return s ? s.name : (id ? 'Another source' : ''); };
  O.areaName = function (id) { var a = O.find('areas', id); return a ? a.name : ''; };
  O.addLive = function (fn) { live.push(fn); return function () { live = live.filter(function (f) { return f !== fn; }); }; };
  O.register = function (id, factory) { factories[id] = factory; };

  /* ── selection: one model for Floor Plan and Command Center ──────────── */
  O.selection = (function () {
    var set = {};
    var S = {};
    function changed() { VF.emit('selection'); O.repaint(); }
    S.has = function (id) { return set[id] === true; };
    S.ids = function () { return O.list('displays').filter(function (d) { return set[d.id]; }).map(function (d) { return d.id; }); };
    S.count = function () { return S.ids().length; };
    S.toggle = function (id) { if (set[id]) delete set[id]; else set[id] = true; changed(); };
    S.add = function (ids) { ids.forEach(function (id) { set[id] = true; }); changed(); };
    S.remove = function (ids) { ids.forEach(function (id) { delete set[id]; }); changed(); };
    S.clear = function () { set = {}; changed(); };
    S.prune = function () { Object.keys(set).forEach(function (id) { if (!O.find('displays', id)) delete set[id]; }); };
    /* Tapping a set (an area, a group): select it all, or clear it when it is all selected already. */
    S.toggleMany = function (ids) {
      if (!ids.length) return;
      if (ids.every(function (id) { return set[id]; })) S.remove(ids); else S.add(ids);
    };
    return S;
  })();
  /* What the two routing interfaces share: the chosen source and the "listen" choice. */
  O.pick = { sourceId: '', listen: false, zoneId: '' };

  /* ── what a display is doing, in one word ────────────────────────────── */
  var D_LABEL = { on: 'On', off: 'Off', working: 'Working', failed: 'Not confirmed', offline: 'Offline', unknown: 'Unknown' };
  var D_CHIP = { on: 'ok', off: 'x', working: 'teal', failed: 'warn', offline: 'bad', unknown: 'x' };
  O.displayInfo = function (d) {
    var st = VF.asMap(VF.asMap(O.doc().displays)[d.id]);
    var p = st.power || { status: 'unknown' }, s = st.source || { status: 'unknown' };
    var key;
    if (st.online === false) key = 'offline';
    else if (p.status === 'pending' || s.status === 'pending') key = 'working';
    else if (p.status === 'failed' || s.status === 'failed' || (p.status === 'unknown' && p.errorCode) || (s.status === 'unknown' && s.errorCode)) key = 'failed';
    else if (p.status === 'unknown' || (p.value !== 'on' && p.value !== 'off')) key = 'unknown';
    else key = p.value;
    var label = D_LABEL[key];
    if ((key === 'on' || key === 'off') && p.status === 'commanded') label += ' (sent)';
    var srcName = s.value ? O.sourceName(s.value) : '';
    /* The one short line a tile or a plan icon shows under the name. */
    var line = key === 'on' ? (srcName || 'On') : (key === 'working' ? (srcName || 'Working') : label);
    return { key: key, label: label, chip: D_CHIP[key], power: p, source: s, sourceName: srcName, line: line, on: p.value === 'on' && key !== 'offline' };
  };
  O.displayChip = function () {
    var dot = h('span.dot'), text = h('span');
    var chip = h('span.chip', dot, text);
    chip.set = function (info) {
      var cls = 'chip ' + info.chip;
      if (chip.className !== cls) chip.className = cls;
      O.setClass(dot, 'pulse', info.key === 'working');
      O.setText(text, info.label);
    };
    return chip;
  };
  O.canShow = function (d, sourceId) { return d.sources === 'all' || d.sources == null || VF.asList(d.sources).indexOf(sourceId) >= 0; };
  O.videoSources = function () { return O.list('sources').filter(function (s) { return s.video !== false; }); };
  O.zoneSources = function (zone) {
    return O.list('sources').filter(function (s) { return s.audio !== false && (zone.sources === 'all' || zone.sources == null || VF.asList(zone.sources).indexOf(s.id) >= 0); });
  };
  /* Zones the "listen" option may send sound to. */
  O.listenZones = function () {
    if (!O.can('audio')) return [];
    return O.list('audioZones').filter(function (z) { return VF.asMap(z.can).source !== false; });
  };
  O.listenProblem = function (zone, sourceId) {
    var s = O.find('sources', sourceId);
    if (!zone || !s) return '';
    if (s.audio === false) return s.name + ' has no sound.';
    if (!(zone.sources === 'all' || zone.sources == null || VF.asList(zone.sources).indexOf(s.id) >= 0)) return s.name + ' cannot play in ' + zone.name + '.';
    return '';
  };
  O.sourceIcon = function (s, cls) { return VF.icon(VF.SOURCE_ICON[s && s.kind] || 'monitor', cls); };

  /* ── commands ────────────────────────────────────────────────────────── */
  /* A partial or failed reply names each device: put the list in front of the operator. */
  O.outcomeSheet = function (reply, title) {
    var results = VF.asList(reply && reply.results);
    if (!reply || !results.length) return;
    if (reply.status !== 'partial' && reply.ok) return;
    VF.modal({ title: title || (reply.ok ? 'Some of this could not be done' : 'This could not be done'), icon: 'alert', body: VF.outcomeList(results), actions: [{ label: 'Close', kind: 'primary', value: null }] });
  };
  /* One display asked, one refused: a single line says it all. Otherwise the summary
     toast, and the per-device list when anything was refused. */
  function report(r, okText, partialTitle, failedTitle) {
    var results = VF.asList(r.results);
    if (!r.ok && results.length === 1 && results[0].message) { VF.toast((results[0].name || 'This display') + ': ' + results[0].message, 'bad'); return; }
    VF.toastReply(r, okText);
    O.outcomeSheet(r, r.ok ? partialTitle : failedTitle);
  }
  O.route = function (sourceId, displayIds, audioZoneId) {
    var src = O.find('sources', sourceId);
    var payload = { sourceId: sourceId, displayIds: displayIds };
    if (audioZoneId) payload.audioZoneId = audioZoneId;
    return VF.api('ROUTE_VIDEO', payload).then(function (r) {
      var n = (r.summary && r.summary.accepted) || displayIds.length;
      report(r, (src ? src.name : 'Source') + ' sent to ' + O.plural(n, 'display'), 'Some displays were not changed', 'No display was changed');
      var audio = r.data && r.data.audio;
      if (audio && !audio.ok) VF.toast('The sound was not changed. ' + (audio.message || ''), 'warn');
      return r;
    });
  };
  O.power = function (displayIds, power) {
    return VF.api('DISPLAY_POWER', { displayIds: displayIds, power: power }).then(function (r) {
      var n = (r.summary && r.summary.accepted) || displayIds.length;
      report(r, 'Power ' + power + ' sent to ' + O.plural(n, 'display'), 'Some displays were not changed', 'No display was changed');
      return r;
    });
  };
  /* Audio, lighting and shade commands: quiet when accepted (the control itself shows
     working / not confirmed), plain when refused. */
  O.send = function (command, payload, okText) {
    return VF.api(command, payload).then(function (r) {
      VF.toastReply(r, okText);
      if (r.ok && r.data && r.data.clamped) VF.toast('Limited to ' + r.data.level + '% for this zone', 'warn');
      return r;
    });
  };

  O.sceneState = function (scene) {
    var doc = O.doc();
    var running = VF.asList(doc.running).some(function (x) { return x.kind === 'scene' && (x.refId ? x.refId === scene.id : x.name === scene.name); });
    return { active: !!doc.activeScene && doc.activeScene.id === scene.id, running: running };
  };
  function stepList(execution) {
    var steps = VF.asList(execution && execution.steps);
    var list = h('div.list.op-steps');
    steps.forEach(function (s, i) {
      list.appendChild(h('div.item', h('span.op-stepno', String(i + 1)), h('div.grow', s.label || s.type)));
    });
    return steps.length ? list : h('p.muted', 'This scene has no steps.');
  }
  function sceneReply(scene, r) {
    var exec = r.data && r.data.execution;
    if (r.ok && r.status === 'partial') {
      VF.toast(scene.name + ': some steps could not be done', 'warn');
      VF.modal({ title: scene.name + ': what happened', icon: 'alert', body: VF.outcomeList(VF.asList(exec && exec.steps)), actions: [{ label: 'Close', kind: 'primary', value: null }] });
    } else if (r.ok) {
      /* "ok" is the driver saying every step finished; "accepted" is only "sent". */
      VF.toast(r.status === 'ok' ? scene.name + ' ran' : scene.name + ' started', r.status === 'ok' ? 'ok' : '');
    } else if (r.errorCode === 'VF_CONDITION_FALSE' || r.errorCode === 'VF_LICENSE_RESTRICTED') {
      VF.toast(scene.name + ': ' + (r.message || 'not available right now'), 'warn');
    } else {
      VF.toastReply(r);
      var steps = VF.asList(exec && exec.steps);
      if (steps.length) VF.modal({ title: scene.name + ' did not run', icon: 'alert', body: VF.outcomeList(steps), actions: [{ label: 'Close', kind: 'primary', value: null }] });
    }
    return r;
  }
  O.activateScene = function (scene, opts) {
    opts = opts || {};
    var payload = { sceneId: scene.id };
    if (opts.areaId) payload.areaId = opts.areaId;
    return VF.api('SCENE_ACTIVATE', payload).then(function (r) {
      if (r.errorCode !== 'VF_CONFIRM_REQUIRED') return sceneReply(scene, r);
      var body = h('div.col', h('p.muted', scene.description || 'This scene asks for confirmation before it runs.'), h('h4', 'What it will do'), stepList(r.data && r.data.preview));
      return VF.modal({ title: 'Run ' + scene.name + '?', icon: 'help', body: body, actions: [{ label: 'Cancel', kind: 'ghost', value: false }, { label: 'Run ' + scene.name, kind: 'primary', value: true }] }).then(function (go) {
        if (go !== true) return null;
        payload.confirm = true;
        return VF.api('SCENE_ACTIVATE', payload).then(function (r2) { return sceneReply(scene, r2); });
      });
    });
  };
  O.allOff = function () {
    return VF.api('ALL_OFF_PREVIEW', {}).then(function (r) {
      if (!r.ok) { VF.toastReply(r); return null; }
      var d = r.data || {};
      var results = VF.asList(r.results);
      var lines = h('div.list');
      lines.appendChild(h('div.item', VF.icon('tv'), h('div.grow', O.plural(d.displays || 0, 'display') + ' will be switched off')));
      lines.appendChild(h('div.item', VF.icon('volume'), h('div.grow', O.plural(d.zones || 0, 'audio zone') + ' will be switched off')));
      if (d.activeScene) lines.appendChild(h('div.item', VF.icon('zap'), h('div.grow', 'The active scene "' + d.activeScene + '" will end')));
      var refused = results.filter(function (x) { return x.status === 'failed'; });
      var detail = h('div.col.hidden', VF.outcomeList(results));
      var more = h('button.btn.sm.ghost', { type: 'button', onclick: function () { detail.classList.toggle('hidden'); } }, VF.icon('list'), 'Show every device');
      var body = h('div.col', h('p.muted', 'Everything below is switched off, and any scene still running is stopped.'), lines,
        refused.length ? h('div.banner.warn', VF.icon('alert'), h('div', O.plural(refused.length, 'device') + ' cannot be switched off from here.')) : null,
        results.length ? more : null, detail);
      return VF.modal({ title: 'All Off: Confirmation Preview', icon: 'power', body: body, actions: [{ label: 'Cancel', kind: 'ghost', value: false }, { label: 'Confirm All Off', kind: 'danger', icon: 'power', value: true }] }).then(function (go) {
        if (go !== true) return null;
        return VF.api('ALL_OFF', { confirm: true }).then(function (r2) {
          VF.toastReply(r2, 'All Off sent');
          O.outcomeSheet(r2, r2.ok ? 'Some devices were not switched off' : 'Nothing was switched off');
          return r2;
        });
      });
    });
  };
  O.setVenueStatus = function (status) {
    var open = status === 'open';
    return VF.confirm(open ? 'Mark the venue open?' : 'Mark the venue closed?',
      (open ? 'This marks the venue as open.' : 'This marks the venue as closed.') + ' Anything set up to happen at that moment will run. It does not switch anything off by itself.',
      open ? 'Open venue' : 'Close venue').then(function (go) {
      if (!go) return null;
      return VF.api('VENUE_STATUS', { status: status }).then(function (r) { VF.toastReply(r, open ? 'Venue marked open' : 'Venue marked closed'); return r; });
    });
  };

  /* ── shared components ───────────────────────────────────────────────── */
  O.sceneButton = function (scene, opts) {
    opts = opts || {};
    var tag = h('span.op-scene-tag');
    var btn = h('button.btn.op-scene' + (opts.large ? '.lg' : ''), { type: 'button', title: scene.description || scene.name, onclick: function () {
      if (btn.disabled) return;
      btn.disabled = true;
      O.activateScene(scene, opts).then(function () { btn.disabled = false; });
    } }, VF.sceneIcon(scene.icon), h('span.ellipsis', opts.label || scene.name), tag);
    btn.update = function () {
      var st = O.sceneState(scene);
      O.setClass(btn, 'on', st.active);
      O.setClass(btn, 'busy', st.running);
      O.setText(tag, st.running ? 'Running' : (st.active ? 'Active' : ''));
    };
    btn.update();
    return btn;
  };
  /* A row of scene shortcuts; null when the profile has no scene. */
  O.sceneBar = function () {
    var scenes = O.list('scenes');
    if (!scenes.length) return null;
    var buttons = scenes.map(function (s) { return O.sceneButton(s); });
    var bar = h('div.op-scenes.scroll', buttons);
    bar.update = function () { buttons.forEach(function (b) { b.update(); }); };
    return bar;
  };
  O.allOffButton = function (cls) {
    if (!O.can('allOff')) return null;
    return h('button.btn.danger' + (cls || ''), { type: 'button', onclick: function () { O.allOff(); } }, VF.icon('power'), 'All Off');
  };

  /* Radio list of the sources that carry video. opts: { get(), set(id), note(source) -> text } */
  O.sourceList = function (opts) {
    var rows = O.videoSources().map(function (s) {
      var note = h('div.small.op-src-note');
      var row = h('button.item.clickable.op-src', { type: 'button', role: 'radio', onclick: function () { opts.set(s.id); } },
        h('span.op-radio'), O.sourceIcon(s), h('div.grow', h('div.ellipsis', s.name), note));
      row._s = s; row._note = note;
      return row;
    });
    var el = h('div.op-srclist', { role: 'radiogroup', 'aria-label': 'Source' }, rows.length ? rows : h('div.empty', 'No source is available to this profile.'));
    el.update = function () {
      var cur = opts.get();
      rows.forEach(function (row) {
        var on = row._s.id === cur;
        O.setClass(row, 'sel', on);
        O.setAttr(row, 'aria-checked', on ? 'true' : 'false');
        var text = row._s.mapped === false ? 'Not connected yet' : (opts.note ? opts.note(row._s) : '');
        O.setText(row._note, text);
        O.setClass(row, 'noted', !!text);
      });
    };
    return el;
  };

  /* One audio zone: source, volume, mute, off, presets. Every control shows what the
     driver knows about it (working / not confirmed).
     opts: { variant: 'card' | 'bar', source, presets, off, more } */
  var Z_FIELD = { power: 'Power', source: 'Source', volume: 'Volume', mute: 'Mute' };
  O.zoneControl = function (zone, opts) {
    opts = opts || {};
    var can = VF.asMap(zone.can);
    var min = Number(zone.minVolume) || 0;
    var max = zone.maxVolume == null ? 100 : Number(zone.maxVolume);
    if (!(max > min)) max = min + 1;
    var touching = false, holdUntil = 0;
    var bar = opts.variant === 'bar';
    function cells() { return VF.asMap(VF.asMap(O.doc().zones)[zone.id]); }

    var state = h('span.chip'), stateDot = h('span.dot'), stateText = h('span');
    VF.append(state, [stateDot, stateText]);
    var notes = h('div.op-zc-notes');
    var pct = h('span.op-zc-pct');
    var slider = null, mute = null, off = null, select = null, presets = [];

    if (can.volume !== false) {
      slider = VF.slider(min, min, max, function (v) {
        touching = false; holdUntil = Date.now() + 1500;
        O.send('AUDIO_VOLUME', { zoneId: zone.id, level: v });
      }, function (v) { touching = true; O.setText(pct, v + '%'); });
      slider.setAttribute('aria-label', zone.name + ' volume');
      ['pointerdown', 'touchstart', 'mousedown'].forEach(function (ev) { slider.addEventListener(ev, function () { touching = true; }); });
      ['pointerup', 'pointercancel', 'touchend', 'touchcancel', 'mouseup', 'blur'].forEach(function (ev) { slider.addEventListener(ev, function () { setTimeout(function () { touching = false; }, 600); }); });
    }
    if (can.mute !== false) {
      mute = h('button.btn.icon.op-zc-mute', { type: 'button', onclick: function () {
        var c = cells().mute || {};
        O.send('AUDIO_MUTE', { zoneId: zone.id, muted: c.value !== true });
      } });
    }
    if (can.power !== false && opts.off !== false) {
      off = h('button.btn.sm.ghost', { type: 'button', onclick: function () { O.send('AUDIO_POWER', { zoneId: zone.id, power: 'off' }); } }, VF.icon('power', 'sm'), 'Off');
    }
    var sources = O.zoneSources(zone);
    if (can.source !== false && opts.source !== false && sources.length) {
      select = h('select.field.op-zc-src', { 'aria-label': zone.name + ' source', onchange: function () {
        if (select.value) O.send('AUDIO_SOURCE', { zoneId: zone.id, sourceId: select.value });
      } }, h('option', { value: '' }, 'Choose a source'), sources.map(function (s) { return h('option', { value: s.id }, s.name); }));
    }
    if (can.volume !== false && opts.presets !== false) {
      presets = VF.asList(zone.presets).map(function (p) {
        var b = h('button.btn.sm.op-zc-preset', { type: 'button', onclick: function () { holdUntil = 0; O.send('AUDIO_PRESET', { zoneId: zone.id, presetId: p.id }); } }, p.name);
        b._level = p.level;
        return b;
      });
    }

    /* A compact card keeps source, presets and off one tap away. */
    var more = opts.more ? h('button.btn.sm.ghost.icon.op-zc-more', { type: 'button', 'aria-label': 'More for ' + zone.name, title: 'Source, presets and off', onclick: function () { O.zoneSheet(zone); } }, VF.icon('sliders')) : null;
    var el = h('div.op-zc.' + (bar ? 'bar' : 'stack'),
      h('div.op-zc-head', VF.icon('volume'), h('div.grow.ellipsis.op-zc-name', zone.name), state, off, more),
      slider ? h('div.op-zc-vol', mute, slider, pct) : (mute ? h('div.op-zc-vol', mute) : null),
      select,
      presets.length ? h('div.op-zc-presets', presets) : null,
      bar ? notes : null);

    el.update = function () {
      var c = cells();
      var power = c.power || { status: 'unknown' }, vol = c.volume || { status: 'unknown' }, mu = c.mute || { status: 'unknown' }, src = c.source || { status: 'unknown' };
      var on = power.value === 'on', muted = mu.value === true;
      /* What each control is waiting for, or could not confirm. */
      var flags = [];
      ['power', 'source', 'volume', 'mute'].forEach(function (f) {
        var cell = c[f] || {};
        var word = cell.status === 'pending' ? 'working' : ((cell.status === 'failed' || (cell.status === 'unknown' && cell.errorCode)) ? 'not confirmed' : (cell.status === 'commanded' ? 'sent' : ''));
        if (word) flags.push({ field: f, word: word });
      });
      var worst = flags.some(function (x) { return x.word === 'not confirmed'; }) ? 'not confirmed' : (flags.some(function (x) { return x.word === 'working'; }) ? 'working' : (flags.length ? 'sent' : ''));
      var stCls, stLabel;
      if (worst && bar === false) {
        /* The card's chip names the control: no extra row, so nothing moves under a finger. */
        stCls = 'chip ' + (worst === 'working' ? 'teal' : (worst === 'sent' ? 'info' : 'warn'));
        stLabel = flags.length === 1 ? Z_FIELD[flags[0].field] + ' ' + flags[0].word : (worst === 'working' ? 'Working' : (worst === 'sent' ? 'Sent' : 'Not confirmed'));
      } else {
        stCls = 'chip ' + (power.status === 'unknown' ? 'x' : (on ? 'ok' : 'x'));
        stLabel = power.status === 'unknown' ? 'Unknown' : (on ? (src.value ? O.sourceName(src.value) : 'On') : 'Off');
      }
      if (state.className !== stCls) state.className = stCls;
      O.setClass(stateDot, 'pulse', worst === 'working' && bar === false);
      O.setText(stateText, stLabel);
      if (slider) {
        var v = typeof vol.value === 'number' ? VF.clamp(vol.value, min, max) : null;
        if (!touching && Date.now() >= holdUntil) {
          if (v !== null && Number(slider.value) !== v) slider.setValue(v);
          O.setText(pct, muted ? 'Muted' : (bar && power.value === 'off' ? 'Off' : (typeof vol.value === 'number' ? vol.value + '%' : 'Unknown')));
        }
        O.setClass(pct, 'st-pending', vol.status === 'pending');
        O.setClass(pct, 'st-failed', vol.status === 'failed');
      }
      if (mute) {
        var key = muted ? 'm' : 'u';
        if (mute._k !== key) { mute._k = key; VF.mount(mute, VF.icon(muted ? 'volume-x' : 'volume')); }
        O.setClass(mute, 'warn', muted);
        O.setAttr(mute, 'aria-pressed', muted ? 'true' : 'false');
        O.setAttr(mute, 'aria-label', muted ? 'Unmute ' + zone.name : 'Mute ' + zone.name);
        O.setClass(mute, 'working', mu.status === 'pending');
      }
      if (off) off.disabled = power.value === 'off' && power.status === 'confirmed';
      if (select && document.activeElement !== select) {
        var want = src.value && sources.some(function (s) { return s.id === src.value; }) ? src.value : '';
        if (select.value !== want) select.value = want;
      }
      presets.forEach(function (b) { O.setClass(b, 'on', vol.status === 'confirmed' && vol.value === b._level); });
      if (select) { O.setClass(select, 'working', src.status === 'pending'); O.setClass(select, 'failed', src.status === 'failed'); }
      if (mute) O.setClass(mute, 'failed', mu.status === 'failed');
      if (bar) {
        var sig = flags.map(function (x) { return x.field + ':' + x.word; }).join(';');
        O.patch(notes, sig, function () {
          return flags.map(function (x) {
            return h('span.chip.' + (x.word === 'working' ? 'teal' : (x.word === 'sent' ? 'info' : 'warn')), h('span.dot' + (x.word === 'working' ? '.pulse' : '')), Z_FIELD[x.field] + ' ' + x.word);
          });
        });
      }
    };
    el.update();
    return el;
  };
  O.zoneSheet = function (zone) {
    var ctl = O.zoneControl(zone, { variant: 'card' });
    var stop = O.addLive(function () { ctl.update(); });
    VF.modal({ title: zone.name + ' audio', icon: 'volume', body: ctl, actions: [{ label: 'Close', kind: 'primary', value: null }] }).then(stop);
  };

  /* ── floor plan drawing (Floor Plan, the Command Center map, Manager) ── */
  var images = {};
  O.image = function (key) {
    if (!images[key]) {
      images[key] = VF.api('IMAGE_GET', { key: key }).then(function (r) {
        var url = r.ok && r.data && typeof r.data.dataUrl === 'string' && /^data:image\//.test(r.data.dataUrl) ? r.data.dataUrl : '';
        if (!url) delete images[key];
        return url;
      });
    }
    return images[key];
  };
  var COLOR = /^#[0-9a-fA-F]{3,8}$/;
  function fit(text, width, size) {
    text = String(text || '');
    var maxChars = Math.max(2, Math.floor(width / (size * 0.56)));
    return text.length <= maxChars ? text : text.slice(0, Math.max(1, maxChars - 1)) + '…';
  }
  function placed(x) { var L = x && x.layout; return !!L && L.hidden !== true && typeof L.x === 'number' && typeof L.y === 'number'; }
  O.placed = placed;
  O.floorDisplays = function (floorId) { return O.list('displays').filter(function (d) { return d.floorId === floorId; }); };
  /* Displays that have no place on any drawn floor: they stay controllable from a list. */
  O.unplacedDisplays = function (floorId) {
    return O.list('displays').filter(function (d) { return (d.floorId === floorId || !O.find('floors', d.floorId)) && !placed(d); });
  };

  /* opts: { compact, onDisplay(d), onArea(area), zones, extras, selection } -> { el, update(), count } */
  O.plan = function (floor, opts) {
    opts = opts || {};
    var W = Number(floor.width) || 1200, H = Number(floor.height) || 800;
    var box = { x: 0, y: 0, w: W, h: H };
    /* Draw the part of the floor this profile can see. A bartender who has only the bar gets the bar
       large, not a small bar in the corner of an empty venue. The whole floor is kept when what is
       visible already covers most of it. */
    (function () {
      var x0 = W, y0 = H, x1 = 0, y1 = 0;
      function grow(ax, ay, bx, by) { x0 = Math.min(x0, ax); y0 = Math.min(y0, ay); x1 = Math.max(x1, bx); y1 = Math.max(y1, by); }
      O.list('areas').forEach(function (a) { if (a.floorId === floor.id && a.layout) grow(a.layout.x, a.layout.y, a.layout.x + a.layout.w, a.layout.y + a.layout.h); });
      O.list('displays').forEach(function (d) { if (d.floorId === floor.id && placed(d)) { var r = Math.max(Number(d.layout.w) || 96, Number(d.layout.h) || 58); grow(d.layout.x - 6, d.layout.y - 6, d.layout.x + r + 6, d.layout.y + r + 6); } });
      if (!opts.compact) {
        O.list('audioZones').forEach(function (z) { var L = z.layout; if (L && typeof L.x === 'number' && (!z.floorId || z.floorId === floor.id)) grow(L.x, L.y, L.x + (L.w || 140), L.y + (L.h || 60)); });
        O.list('sceneButtons').forEach(function (b) { if (b.floorId === floor.id) grow(b.x, b.y, b.x + (b.w || 130), b.y + (b.h || 44)); });
      }
      if (!(x1 > x0 && y1 > y0)) return;
      var pad = opts.compact ? 34 : 28;
      var cx = Math.max(0, x0 - pad), cy = Math.max(0, y0 - pad);
      var cw = Math.min(W, x1 + pad) - cx, ch = Math.min(H, y1 + pad) - cy;
      if (opts.compact || (cw * ch) < 0.6 * W * H) { box.x = cx; box.y = cy; box.w = cw; box.h = ch; }
    })();
    var svg = O.svg('svg', { 'class': 'op-plan' + (opts.compact ? ' compact' : ''), viewBox: box.x + ' ' + box.y + ' ' + box.w + ' ' + box.h, preserveAspectRatio: 'xMidYMid meet', role: 'group', 'aria-label': (floor.name || 'Floor') + ' plan' });
    svg.appendChild(O.svg('rect', { 'class': 'op-plan-bg', x: box.x + 1, y: box.y + 1, width: box.w - 2, height: box.h - 2, rx: 14 }));
    if (floor.image && floor.image.key) {
      var img = O.svg('image', { 'class': 'op-plan-img', x: 0, y: 0, width: W, height: H, preserveAspectRatio: 'xMidYMid meet' });
      svg.appendChild(img);
      O.image(floor.image.key).then(function (url) { if (url) { img.setAttribute('href', url); img.setAttributeNS(XLINK, 'xlink:href', url); } });
    }
    var items = [], zoneItems = [], sceneItems = [];

    O.list('areas').forEach(function (a) {
      if (a.floorId !== floor.id || !a.layout) return;
      var L = a.layout, color = COLOR.test(a.color || '') ? a.color : '#7f93b2';
      svg.appendChild(O.svg('rect', { 'class': 'op-parea', x: L.x, y: L.y, width: L.w, height: L.h, rx: 12, fill: color, 'fill-opacity': 0.06, stroke: color, 'stroke-opacity': 0.45 }));
      var fs = opts.compact ? 26 : 15;
      var tw = Math.min(L.w - 24, String(a.name || '').length * fs * 0.6 + 22), th = fs + 12;
      var name = fit(a.name, tw - 16, fs);
      var g = O.svg('g', { 'class': 'op-parea-tag' + (opts.onArea ? ' tap' : ''), role: opts.onArea ? 'button' : null, 'aria-label': opts.onArea ? 'Select every display in ' + a.name : null,
        onclick: opts.onArea ? function () { opts.onArea(a); } : null });
      if (opts.onArea) g.appendChild(O.svg('rect', { 'class': 'op-hit', x: L.x + 4, y: L.y - th / 2 - 10, width: tw + 20, height: th + 20 }));
      g.appendChild(O.svg('rect', { x: L.x + 14, y: L.y - th / 2, width: tw, height: th, rx: th / 2, stroke: color }));
      g.appendChild(O.svg('text', { x: L.x + 14 + tw / 2, y: L.y, 'font-size': fs, 'text-anchor': 'middle', 'dominant-baseline': 'central', fill: color }, name));
      svg.appendChild(g);
    });

    if (opts.extras !== false && !opts.compact) {
      O.list('labels').forEach(function (l) {
        if (l.floorId !== floor.id || typeof l.x !== 'number') return;
        svg.appendChild(O.svg('text', { 'class': 'op-plabel', x: l.x, y: l.y, 'font-size': VF.clamp(Number(l.size) || 16, 8, 120), 'dominant-baseline': 'hanging' }, l.text));
      });
      O.list('sceneButtons').forEach(function (b) {
        var scene = O.find('scenes', b.sceneId);
        if (b.floorId !== floor.id || !scene) return;
        var w = Number(b.w) || 130, hh = Number(b.h) || 44, fs = Math.min(15, hh * 0.36);
        var busy = false;
        var g = O.svg('g', { 'class': 'op-pscene', role: 'button', 'aria-label': 'Run ' + scene.name, onclick: function () {
          if (busy) return; busy = true;
          O.activateScene(scene).then(function () { busy = false; });
        } });
        g.appendChild(O.svg('rect', { x: b.x, y: b.y, width: w, height: hh, rx: 10 }));
        g.appendChild(O.svg('text', { x: b.x + w / 2, y: b.y + hh / 2, 'font-size': fs, 'text-anchor': 'middle', 'dominant-baseline': 'central' }, fit(scene.name, w - 12, fs)));
        svg.appendChild(g);
        sceneItems.push({ g: g, scene: scene, cls: '' });
      });
    }

    if (opts.zones !== false && !opts.compact) {
      O.list('audioZones').forEach(function (z) {
        if (!placed(z)) return;
        var area = O.find('areas', z.areaId);
        if ((z.floorId || (area && area.floorId)) !== floor.id) return;
        var L = z.layout, w = Number(L.w) || 140, hh = Number(L.h) || 60;
        var g = O.svg('g', { 'class': 'op-pzone', role: 'button', 'aria-label': z.name + ' audio', onclick: O.can('audio') ? function () { O.zoneSheet(z); } : null });
        g.appendChild(O.svg('rect', { x: L.x, y: L.y, width: w, height: hh, rx: Math.min(hh / 2, 30) }));
        g.appendChild(O.svg('text', { 'class': 'nm', x: L.x + w / 2, y: L.y + hh * 0.34, 'font-size': Math.min(14, hh * 0.26), 'text-anchor': 'middle', 'dominant-baseline': 'central' }, fit(z.name, w - 16, 14)));
        var val = O.svg('text', { 'class': 'val', x: L.x + w / 2, y: L.y + hh * 0.68, 'font-size': Math.min(17, hh * 0.3), 'text-anchor': 'middle', 'dominant-baseline': 'central' });
        g.appendChild(val);
        svg.appendChild(g);
        zoneItems.push({ g: g, z: z, val: val, cls: '' });
      });
    }

    O.list('displays').forEach(function (d) {
      if (d.floorId !== floor.id || !placed(d)) return;
      var L = d.layout, w = Number(L.w) || 76, hh = Number(L.h) || 44, rot = Number(L.rot) || 0;
      var cx = L.x + w / 2, cy = L.y + hh / 2;
      var turned = Math.abs(rot % 180) === 90;
      var tw = turned ? hh : w, th = turned ? w : hh;
      var g = O.svg('g', { role: opts.onDisplay ? 'button' : null, 'aria-label': d.name, onclick: opts.onDisplay ? function () { opts.onDisplay(d); } : null });
      var body = O.svg('g', rot ? { transform: 'rotate(' + rot + ' ' + cx + ' ' + cy + ')' } : null);
      body.appendChild(O.svg('rect', { 'class': 'ring', x: L.x - 5, y: L.y - 5, width: w + 10, height: hh + 10, rx: 9 }));
      body.appendChild(O.svg('rect', { 'class': 'body', x: L.x, y: L.y, width: w, height: hh, rx: 6 }));
      g.appendChild(body);
      var src = null;
      if (!opts.compact) {
        /* The name on one line when it fits at a readable size, else on two; then the
           source line. Shrink before cutting short. */
        var name = String(d.name || ''), lines = [name];
        var fs = VF.clamp(th * 0.3, 9, 15);
        var need = name.length * 0.56;
        if ((tw - 6) / need < 11 && th >= 40 && name.indexOf(' ') > 0) {
          var mid = name.length / 2, cut = -1;
          for (var i = 0; i < name.length; i++) if (name.charAt(i) === ' ' && (cut < 0 || Math.abs(i - mid) < Math.abs(cut - mid))) cut = i;
          lines = [name.slice(0, cut), name.slice(cut + 1)];
          need = Math.max(lines[0].length, lines[1].length) * 0.56;
          fs = VF.clamp(th * 0.25, 9, 13);
        }
        fs = Math.max(9, Math.min(fs, (tw - 6) / Math.max(1, need)));
        var fs2 = VF.clamp(th * 0.24, 8, 12);
        var ys = lines.length === 2 ? [cy - th * 0.29, cy - th * 0.03] : [cy - th * 0.17];
        lines.forEach(function (line, n) {
          g.appendChild(O.svg('text', { 'class': 'nm', x: cx, y: ys[n], 'font-size': fs, 'text-anchor': 'middle', 'dominant-baseline': 'central' }, fit(line, tw - 6, fs)));
        });
        src = O.svg('text', { 'class': 'src', x: cx, y: cy + th * (lines.length === 2 ? 0.3 : 0.24), 'font-size': fs2, 'text-anchor': 'middle', 'dominant-baseline': 'central' });
        src._w = tw - 6; src._fs = fs2;
        g.appendChild(src);
      }
      svg.appendChild(g);
      items.push({ g: g, d: d, src: src, cls: '' });
    });

    function update() {
      items.forEach(function (it) {
        var info = O.displayInfo(it.d);
        var cls = 'op-pd ' + info.key + (opts.selection !== false && O.selection.has(it.d.id) ? ' sel' : '') + (opts.onDisplay ? ' tap' : '');
        if (it.cls !== cls) { it.cls = cls; it.g.setAttribute('class', cls); }
        if (it.src) O.setText(it.src, fit(info.line, it.src._w, it.src._fs));
      });
      zoneItems.forEach(function (it) {
        var c = VF.asMap(VF.asMap(O.doc().zones)[it.z.id]);
        var power = c.power || {}, vol = c.volume || {}, mu = c.mute || {};
        var working = ['power', 'source', 'volume', 'mute'].some(function (f) { return (c[f] || {}).status === 'pending'; });
        var failed = ['power', 'source', 'volume', 'mute'].some(function (f) { return (c[f] || {}).status === 'failed'; });
        var text = mu.value === true ? 'Muted' : (power.value === 'off' ? 'Off' : (typeof vol.value === 'number' ? vol.value + '%' : 'Unknown'));
        O.setText(it.val, text);
        var cls = 'op-pzone' + (mu.value === true ? ' muted' : '') + (power.value === 'on' ? ' on' : '') + (working ? ' working' : '') + (failed ? ' failed' : '');
        if (it.cls !== cls) { it.cls = cls; it.g.setAttribute('class', cls); }
      });
      sceneItems.forEach(function (it) {
        var st = O.sceneState(it.scene);
        var cls = 'op-pscene' + (st.active ? ' on' : '') + (st.running ? ' busy' : '');
        if (it.cls !== cls) { it.cls = cls; it.g.setAttribute('class', cls); }
      });
    }
    update();
    return { el: svg, update: update, count: items.length };
  };

  /* ── full-screen notices and sign-in ─────────────────────────────────── */
  function brand() { return h('div.op-brand', h('span.op-logo', VF.icon('activity')), h('span', 'Venue', h('b', 'Flow'))); }
  function studioUrl() { return (VF.transport.relay || '') + '/studio'; }
  function leaveShell() {
    VF.poll.stop();
    if (current && current.view && current.view.destroy) { try { current.view.destroy(); } catch (e) { console.error(e); } }
    current = null; ui = null; closeMenu();
  }
  function notice(icon, title, text, extra) {
    leaveShell();
    VF.mount(root, h('div.op-notice', h('div.op-notice-box', brand(), VF.icon(icon, 'xl'), h('h1', title), text ? h('p.muted', text) : null, extra)));
  }
  var retryTimer = null;
  function showUnreachable(reply) {
    notice('alert', 'Cannot reach the controller', (reply && reply.errorCode !== 'VF_NETWORK' && reply.message) || 'Check that this screen is on the venue network. Trying again every few seconds.',
      h('button.btn.primary', { type: 'button', onclick: function () { hello(); } }, VF.icon('refresh'), 'Try again'));
    clearTimeout(retryTimer);
    retryTimer = setTimeout(function () { if (!ui) hello(); }, 4000);
  }

  function showSignIn(cancel) {
    leaveShell();
    var d = O.hello || {};
    var profiles = VF.asList(d.profiles);
    var msg = h('div.op-signin-msg', { role: 'alert' });
    var buttons = [];
    var lockedUntil = 0, lockTimer = null;
    function setMsg(kind, text) { VF.mount(msg, text ? h('div.banner.' + kind, VF.icon('alert'), h('div', text)) : null); }
    function tick() {
      var left = Math.ceil((lockedUntil - Date.now()) / 1000);
      if (left <= 0) {
        clearInterval(lockTimer); lockTimer = null;
        buttons.forEach(function (b) { b.disabled = false; });
        setMsg('', '');
        return;
      }
      buttons.forEach(function (b) { b.disabled = true; });
      setMsg('warn', 'Too many wrong attempts. Try again in ' + left + ' s.');
    }
    function lock(seconds) { lockedUntil = Date.now() + seconds * 1000; clearInterval(lockTimer); lockTimer = setInterval(tick, 1000); tick(); }
    function pick(p) {
      setMsg('', '');
      VF.pinPad('Enter PIN', p.name).then(function (pin) {
        if (!pin) return;
        var old = VF.session.get();
        VF.api('PROFILE_LOGIN', { profileId: p.id, pin: pin }, { since: false }).then(function (r) {
          if (r.ok && r.data && r.data.session && r.data.profile) {
            clearInterval(lockTimer);
            if (old) VF.api('LOGOUT', {}, { since: false });      // ends the session this one replaces
            VF.session.set(r.data.session);
            var data = Object.assign({}, d, r.data, { signedIn: true, needsSignIn: false });
            enter(data);
            VF.toast('Signed in as ' + r.data.profile.name, 'ok');
            return;
          }
          var retry = Number(r.data && r.data.retryIn) || 0;
          if (r.errorCode === 'VF_LOCKED') lock(retry > 0 ? retry : 60);
          else setMsg(r.errorCode === 'VF_BAD_PIN' ? 'warn' : 'bad', r.message || 'That did not work.');
        });
      });
    }
    profiles.forEach(function (p) {
      buttons.push(h('button.btn.lg.op-signin-btn', { type: 'button', onclick: function () { pick(p); } },
        VF.icon('user', 'lg'), h('div.grow', h('div.op-signin-name', p.name), h('div.small.muted', ROLE[p.role] || 'Staff')), VF.icon('chevron-right')));
    });
    var body;
    if (O.asStudio) {
      body = h('div.col', h('p.muted', 'Sign in to the Installer Studio in this tab first, then open this page again.'), h('a.btn.primary', { href: studioUrl() }, VF.icon('settings'), 'Open Installer Studio'));
    } else if (!profiles.length) {
      body = h('div.col', h('p.muted', 'No staff profile can sign in on this screen yet. Ask your installer to set a PIN for a profile.'),
        d.studioEnabled ? h('a.btn', { href: studioUrl() }, VF.icon('settings'), 'Installer Studio') : null);
    } else {
      body = h('div.col', h('p.muted', 'Choose your profile, then enter your PIN.'), msg, h('div.op-signin-list', buttons));
    }
    VF.mount(root, h('div.op-notice.scroll', h('div.op-notice-box.op-signin', brand(), d.venueName ? h('div.op-signin-venue', d.venueName) : null,
      h('h1', cancel ? 'Switch profile' : 'Sign in'), body,
      cancel ? h('button.btn.ghost', { type: 'button', onclick: function () { clearInterval(lockTimer); cancel(); } }, VF.icon('arrow-left'), 'Back') : null)));
  }

  /* ── the shell ───────────────────────────────────────────────────────── */
  function setData(d) {
    var c = VF.asMap(d.config);
    O.config = c;
    O.lists = {}; O.ix = {};
    ['floors', 'areas', 'sources', 'displays', 'audioZones', 'groups', 'lighting', 'shades', 'rooms', 'scenes', 'labels', 'sceneButtons'].forEach(function (k) {
      var list = VF.asList(c[k]).filter(function (x) { return x && typeof x === 'object'; });
      var map = {};
      list.forEach(function (x) { if (x.id) map[x.id] = x; });
      O.lists[k] = list; O.ix[k] = map;
    });
    var p = VF.asMap(d.profile);
    var venue = VF.asMap(c.venue);
    /* An Installer Studio session is "System": every interface, every permission. */
    var allowed = p.system ? ORDER : VF.asList(p.interfaces);
    O.profile = {
      id: p.id || (p.system ? 'system' : ''),
      name: p.system ? 'Installer' : (p.name || 'Staff'),
      role: p.role || '', system: p.system === true,
      interfaces: ORDER.filter(function (x) { return allowed.indexOf(x) >= 0 && factories[x]; }),
      defaultInterface: p.system ? venue.defaultInterface : p.defaultInterface,
      can: VF.asMap(p.can)
    };
    O.signedIn = d.signedIn === true;
    O.venueName = d.venueName || venue.name || 'Venue';
    O.selection.prune();
    if (!O.find('sources', O.pick.sourceId)) O.pick.sourceId = '';
    if (!O.find('audioZones', O.pick.zoneId)) O.pick.zoneId = '';
  }
  /* Compared between two HELLO replies, so it must not depend on the order in which the
     driver's JSON encoder happens to write the keys. */
  function stable(x) {
    if (Array.isArray(x)) return x.map(stable);
    if (x && typeof x === 'object') { var o = {}; Object.keys(x).sort().forEach(function (k) { o[k] = stable(x[k]); }); return o; }
    return x;
  }
  function dataKey(d) { return JSON.stringify(stable([d.profile || null, d.config || null, d.venueName || '', d.signedIn === true])); }

  var lastKey = '', lastProfileId = null, lastViewId = null;
  function enter(d) {
    leaveShell();
    O.hello = d;
    lastKey = dataKey(d);
    setData(d);
    buildShell();
    if (d.state) VF.state.set(d.state);
    var keep = lastProfileId === O.profile.id && O.profile.interfaces.indexOf(lastViewId) >= 0;
    lastProfileId = O.profile.id;
    var first = keep ? lastViewId : (O.profile.interfaces.indexOf(O.profile.defaultInterface) >= 0 ? O.profile.defaultInterface : O.profile.interfaces[0]);
    show(first);
    paint();
    fitHeader();
    VF.poll.start(1500);
  }

  function buildShell() {
    ui = {};
    ui.sim = h('div.simbar.hidden', 'Simulation: no real equipment is being controlled');
    ui.venueDot = h('span.dot'); ui.venueText = h('span');
    ui.venue = h(O.can('venueStatus') ? 'button.chip.op-venue-chip.tap' : 'span.chip.op-venue-chip', O.can('venueStatus') ? { type: 'button', title: 'Open or close the venue', onclick: function () {
      O.setVenueStatus(O.doc().venueStatus === 'open' ? 'closed' : 'open');
    } } : {}, ui.venueDot, ui.venueText);
    ui.connDot = h('span.dot.ok'); ui.connText = h('span.op-conn-text', 'Connected');
    ui.conn = h('span.op-conn', { role: 'status' }, ui.connDot, ui.connText);
    ui.clock = h('span.op-clock');
    var items = menuItems();
    ui.profile = h(items.length ? 'button.op-profile.tap' : 'span.op-profile', items.length ? { type: 'button', 'aria-haspopup': 'true', onclick: function (e) { e.stopPropagation(); toggleMenu(items); } } : {},
      VF.icon('user'), h('span.ellipsis', O.profile.name), items.length ? VF.icon('chevron-down', 'sm') : null);
    ui.nav = null;
    if (O.profile.interfaces.length > 1) {
      ui.tabs = {};
      ui.nav = h('nav.seg.op-nav', { role: 'tablist', 'aria-label': 'Interface' }, O.profile.interfaces.map(function (id) {
        var def = O.INTERFACES[id];
        var b = h('button', { type: 'button', role: 'tab', onclick: function () { show(id); } }, VF.icon(def.icon), h('span', def.label));
        ui.tabs[id] = b;
        return b;
      }));
    }
    ui.venueName = h('div.op-venue.ellipsis', O.venueName);
    ui.banners = h('div.op-banners');
    ui.activity = h('div.op-activity');
    ui.main = h('main.op-main');
    ui.head = h('header.op-head', brand(), ui.venueName, ui.nav || h('div.grow'), h('div.op-head-right', ui.venue, ui.conn, ui.clock, ui.profile));
    VF.mount(root, h('div.op-shell', ui.sim, ui.head, ui.banners, ui.activity, ui.main));
    paintOnline();
    paintClock();
    fitHeader();
  }
  /* The venue name gives way first: when it is squeezed to a stub, hide it. */
  function fitHeader() {
    if (!ui || !ui.venueName) return;
    ui.venueName.classList.remove('hidden');
    ui.head.classList.remove('tight', 'tighter');
    if (ui.venueName.scrollWidth > ui.venueName.clientWidth + 1 && ui.venueName.clientWidth < 96) ui.venueName.classList.add('hidden');
    /* Then the clock, then the tab icons, before a tab is pushed out of sight. */
    if (ui.nav && ui.nav.scrollWidth > ui.nav.clientWidth + 1) {
      ui.head.classList.add('tight');
      if (ui.nav.scrollWidth > ui.nav.clientWidth + 1) ui.head.classList.add('tighter');
    }
  }

  function show(id) {
    if (!ui) return;
    if (current && current.view && current.view.destroy) { try { current.view.destroy(); } catch (e) { console.error(e); } }
    current = null;
    VF.clear(ui.main);
    if (!id || !factories[id]) {
      VF.mount(ui.main, h('div.op-view', h('div.empty', 'This profile has no screen assigned. Ask your installer to give it an interface.')));
      return;
    }
    lastViewId = id;
    if (ui.tabs) Object.keys(ui.tabs).forEach(function (k) { O.setClass(ui.tabs[k], 'on', k === id); O.setAttr(ui.tabs[k], 'aria-selected', k === id ? 'true' : 'false'); });
    var host = h('div.op-view.op-view-' + id);
    ui.main.appendChild(host);
    var view = null;
    try { view = factories[id](host) || {}; } catch (e) { console.error('VenueFlow view ' + id, e); VF.mount(host, h('div.empty', 'This screen could not be drawn.')); view = {}; }
    current = { id: id, view: view };
    if (view.update) view.update();
  }
  O.show = show;
  O.currentId = function () { return current ? current.id : null; };

  /* profile menu */
  var menuEl = null;
  function closeMenu() { if (menuEl && menuEl.parentNode) menuEl.parentNode.removeChild(menuEl); menuEl = null; document.removeEventListener('click', closeMenu); }
  function menuItems() {
    var items = [];
    if (O.profile.system) {
      items.push({ icon: 'settings', label: 'Back to Installer Studio', run: function () { location.href = studioUrl(); } });
      return items;
    }
    if (VF.asList(O.hello && O.hello.profiles).length) {
      items.push({ icon: 'users', label: 'Switch profile', run: function () { var d = O.hello; showSignIn(function () { enter(d); }); } });
    }
    if (O.signedIn) {
      items.push({ icon: 'log-out', label: 'Sign out', run: function () {
        VF.api('LOGOUT', {}, { since: false }).then(function () { VF.session.clear(); lastProfileId = null; hello(); });
      } });
    }
    return items;
  }
  function toggleMenu(items) {
    if (menuEl) { closeMenu(); return; }
    menuEl = h('div.op-menu', { role: 'menu' },
      h('div.op-menu-who', h('div', O.profile.name), h('div.small.muted', O.profile.system ? 'Full access' : ((ROLE[O.profile.role] || 'Staff') + (O.signedIn ? '' : ' (this screen)')))),
      items.map(function (it) { return h('button.btn.ghost.block', { type: 'button', role: 'menuitem', onclick: function () { closeMenu(); it.run(); } }, VF.icon(it.icon), h('span.grow', it.label)); }));
    var r = ui.profile.getBoundingClientRect();
    menuEl.style.top = Math.round(r.bottom + 6) + 'px';
    menuEl.style.right = Math.max(8, Math.round(window.innerWidth - r.right)) + 'px';
    document.body.appendChild(menuEl);
    setTimeout(function () { document.addEventListener('click', closeMenu); }, 0);
  }

  /* header + banners + activity */
  var isOnline = true;
  function paintOnline() {
    if (!ui) return;
    ui.connDot.className = 'dot ' + (isOnline ? 'ok' : 'bad');
    O.setText(ui.connText, isOnline ? 'Connected' : 'No connection');
    O.setClass(ui.conn, 'off', !isOnline);
    paintBanners();
  }
  function paintClock() {
    if (!ui) return;
    O.setText(ui.clock, new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }));
  }
  function paintBanners() {
    if (!ui) return;
    var doc = O.doc();
    var restricted = !!(doc.license && doc.license.restricted);
    O.patch(ui.banners, (isOnline ? '' : 'off') + (restricted ? 'lic' : ''), function () {
      return [
        isOnline ? null : h('div.banner.bad', VF.icon('alert'), h('div', 'Cannot reach the controller. What you see may be out of date. Trying again.')),
        restricted ? h('div.banner.warn', VF.icon('alert'), h('div', h('b', 'SmartBuildOS licence needed. '), 'Scenes and schedules are paused. Manual control keeps working.')) : null
      ];
    });
  }

  /* What an operation has done so far, in the words an operator uses. Counted from the
     targets this profile can see. */
  O.opCounts = function (op) {
    var c = { confirmed: 0, sent: 0, working: 0, unconfirmed: 0, refused: 0, replaced: 0, total: 0 };
    VF.asList(op.targets).forEach(function (t) {
      c.total++;
      if (t.status === 'confirmed') c.confirmed++;
      else if (t.status === 'commanded') c.sent++;
      else if (t.status === 'pending') c.working++;
      else if (t.status === 'unknown' || (t.status === 'failed' && t.errorCode === 'VF_NOT_CONFIRMED')) c.unconfirmed++;
      else if (t.status === 'superseded') c.replaced++;
      else c.refused++;
    });
    c.bad = c.unconfirmed + c.refused;
    return c;
  };
  O.opText = function (op) {
    var c = O.opCounts(op), parts = [];
    if (c.confirmed) parts.push(c.confirmed + ' confirmed');
    if (c.sent) parts.push(c.sent + ' sent (no feedback)');
    if (c.working) parts.push(c.working + ' working');
    if (c.unconfirmed) parts.push(c.unconfirmed + ' not confirmed');
    if (c.refused) parts.push(c.refused + ' not done');
    if (c.replaced) parts.push(c.replaced + ' replaced');
    return parts.join(', ') || 'nothing to do';
  };
  O.opTone = function (op) { var c = O.opCounts(op); return !op.done ? 'teal' : (c.bad ? 'warn' : (c.confirmed ? 'ok' : 'info')); };
  O.opSheet = function (op) {
    VF.modal({ title: op.label || 'Operation', icon: 'list', body: h('div.col', h('p.muted', (op.done ? 'Finished' : 'Still working') + ': ' + O.opText(op) + '.'), VF.outcomeList(op.targets)), actions: [{ label: 'Close', kind: 'primary', value: null }] });
  };

  var opSeen = {};
  function paintActivity() {
    if (!ui) return;
    var doc = O.doc(), now = Date.now();
    var ops = VF.asList(doc.operations);
    var shown = [], sig = '', present = {};
    VF.asList(doc.running).forEach(function (x) { shown.push({ run: x }); sig += 'x' + x.id + x.status + '|'; });
    ops.forEach(function (op) {
      present[op.id] = true;
      var seen = opSeen[op.id];
      if (!seen) seen = opSeen[op.id] = { old: !!op.done && (Number(doc.time) || 0) - (Number(op.finishedAt) || 0) > 5, doneAt: 0, dismissed: false };
      if (op.done && !seen.doneAt) seen.doneAt = now;
      var bad = O.opCounts(op).bad > 0;
      /* A finished audio change that went well needs no line: the control itself shows it. */
      var quiet = !bad && !VF.asList(op.targets).some(function (t) { return t.kind === 'display'; });
      var keep = !op.done || (!seen.old && !seen.dismissed && !quiet && now - seen.doneAt < (bad ? 45000 : 6000));
      if (keep) { shown.push({ op: op }); sig += op.id + ':' + O.opText(op) + (op.done ? 'd' : '') + '|'; }
    });
    Object.keys(opSeen).forEach(function (id) { if (!present[id]) delete opSeen[id]; });
    var active = doc.activeScene && doc.activeScene.name ? doc.activeScene : null;
    sig = (active ? 'a' + active.id + active.at : '') + '|' + sig;
    O.patch(ui.activity, sig, function () {
      var lead = active ? h('div.op-act.idle', VF.icon('zap', 'sm'), h('span.op-act-text', 'Active scene: ', h('b', active.name), active.at ? ' since ' + VF.fmtTime(active.at) : ''))
        : (O.list('scenes').length && !shown.length ? h('div.op-act.idle.none', h('span.op-act-text', 'No scene active')) : null);
      return [lead].concat(shown.map(function (it) {
        if (it.run) {
          return h('div.op-act.teal', h('span.dot.teal.pulse'), h('span.op-act-text', h('b', it.run.name), it.run.status === 'settling' ? ': waiting for the devices to confirm' : ': running'));
        }
        var op = it.op, tone = O.opTone(op);
        return h('div.op-act.' + tone, h('span.dot.' + tone + (op.done ? '' : '.pulse')),
          h('span.op-act-text', h('b', op.label || 'Operation'), ': ' + O.opText(op)),
          h('button.btn.sm.ghost', { type: 'button', onclick: function () { O.opSheet(op); } }, 'Details'),
          op.done ? h('button.btn.sm.ghost.icon', { type: 'button', 'aria-label': 'Dismiss', onclick: function () { opSeen[op.id].dismissed = true; paintActivity(); } }, VF.icon('x', 'sm')) : null);
      }));
    });
  }

  function paint() {
    if (!ui) return;
    var doc = O.doc();
    O.setClass(ui.sim, 'hidden', doc.simulation !== true);
    var open = doc.venueStatus === 'open';
    O.setText(ui.venueText, doc.venueStatus ? (open ? 'Venue Open' : 'Venue Closed') : 'Venue');
    ui.venueDot.className = 'dot ' + (open ? 'ok' : '');
    O.setClass(ui.venue, 'ok', open);
    paintBanners();
    paintActivity();
    if (current && current.view && current.view.update) {
      try { current.view.update(); } catch (e) { console.error('VenueFlow view update', e); }
    }
    live.slice().forEach(function (fn) { try { fn(); } catch (e) { console.error(e); } });
  }
  var paintQueued = false;
  O.repaint = function () {
    if (paintQueued) return;
    paintQueued = true;
    setTimeout(function () { paintQueued = false; paint(); }, 0);
  };

  /* ── start ───────────────────────────────────────────────────────────── */
  function hello() {
    clearTimeout(retryTimer);
    return VF.api('HELLO', {}, { since: false }).then(function (r) {
      if (!r.ok || !r.data) { showUnreachable(r); return; }
      var d = r.data;
      O.hello = d;
      if (!d.published) {
        notice('settings', 'This venue has not been set up yet', 'Your installer needs to publish the venue before this screen can control anything.',
          d.studioEnabled ? h('a.btn', { href: studioUrl() }, VF.icon('settings'), 'Open Installer Studio') : null);
        clearTimeout(retryTimer);
        retryTimer = setTimeout(function () { if (!ui) hello(); }, 15000);
        return;
      }
      if (d.needsSignIn || !d.profile) { lastProfileId = null; showSignIn(null); return; }
      enter(d);
    });
  }
  /* The state document carries no configuration version, so look again now and then:
     a republished venue or a changed profile redraws the page. */
  function recheck() {
    if (!ui || document.hidden || document.querySelector('.vf-backdrop')) return;
    VF.api('HELLO', {}, { since: false }).then(function (r) {
      if (!ui || !r.ok || !r.data || document.querySelector('.vf-backdrop')) return;
      var d = r.data;
      if (!d.published) { hello(); return; }
      if (d.needsSignIn || !d.profile) { O.hello = d; lastProfileId = null; showSignIn(null); return; }
      if (dataKey(d) !== lastKey) { enter(d); VF.toast('The venue setup was updated.'); }
    });
  }

  O.start = function () {
    root = document.getElementById('root');
    O.asStudio = new URLSearchParams(location.search).get('as') === 'studio';
    VF.session.use(O.asStudio ? 'studio' : 'op');
    VF.on('state', O.repaint);
    /* The state names the published version: when it changes, load the new setup at once
       (the 60 s recheck below remains as the safety net). */
    var seenVersion = null;
    VF.on('state', function (doc) {
      var v = doc && doc.configVersion;
      if (!v) return;
      if (seenVersion !== null && v !== seenVersion) recheck();
      seenVersion = v;
    });
    VF.on('online', function (on) { isOnline = on !== false; paintOnline(); });
    VF.on('signedout', function () { lastProfileId = null; hello(); });
    setInterval(function () { paintClock(); paintActivity(); }, 1000);
    setInterval(recheck, 60000);
    window.addEventListener('resize', VF.debounce(fitHeader, 150));
    hello();
  };

  return O;
})();
