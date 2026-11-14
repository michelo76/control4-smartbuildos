/* Installer Studio: Scenes, Visual Programming (rules and variables) and Scheduling.

   One block editor serves all three. A program reads top to bottom as
   WHEN / IF / DO and is DATA drawn from the driver's fixed vocabulary
   (src/venueflow/rules.lua): nothing typed here is ever evaluated as code.
   The summaries use the same words as rules.lua describeStep / describeCondition.

   Every change goes through Studio.update on the scene or rule inside the draft.
   Which item and which cards are open lives in module variables, so the shell's
   re-render does not collapse the editor. Text fields commit on `change` without
   a re-render (the summaries are repainted in place), so typing never loses focus. */
(function () {
  'use strict';
  var h = VF.h, icon = VF.icon, asList = VF.asList, asMap = VF.asMap, S = Studio;

  /* ── vocabulary ──────────────────────────────────────────────────────── */
  var DAY = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  var DAY_LONG = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  var CMP_TEXT = { eq: '=', ne: 'is not', gt: '>', lt: '<', ge: '>=', le: '<=' };
  var CMP_LABEL = { eq: 'is (=)', ne: 'is not', gt: 'is more than (>)', lt: 'is less than (<)', ge: 'is at least (>=)', le: 'is at most (<=)' };
  var MAX_NEST = 4, MAX_STEPS = 60, MAX_COND_DEPTH = 6;
  var ACTIVE = { running: true, settling: true };
  var KIND_LABEL = { scene: 'Scene', rule: 'Rule', adhoc: 'Studio test' };

  var STEP = {
    display_power: { label: 'Power displays', icon: 'power', hint: 'Switch displays on or off', make: function () { return { type: 'display_power', power: 'on', target: {} }; } },
    route_video: { label: 'Route video', icon: 'route', hint: 'Show a source on displays', make: function () { return { type: 'route_video', target: {} }; } },
    route_audio: { label: 'Route audio', icon: 'music', hint: 'Play a source in an audio zone', make: function () { return { type: 'route_audio' }; } },
    volume: { label: 'Set volume', icon: 'volume', hint: 'Set an audio zone to a level', make: function () { return { type: 'volume', level: 50 }; } },
    mute: { label: 'Mute or unmute', icon: 'volume-x', hint: 'Mute or unmute an audio zone', make: function () { return { type: 'mute', muted: true }; } },
    zone_power: { label: 'Turn zone off', icon: 'power', hint: 'Switch an audio zone off', make: function () { return { type: 'zone_power', power: 'off' }; } },
    lighting: { label: 'Lighting preset', icon: 'bulb', hint: 'Recall a lighting preset', make: function () { return { type: 'lighting' }; } },
    shade: { label: 'Shade', icon: 'blinds', hint: 'Open or close a shade', make: function () { return { type: 'shade', action: 'open' }; } },
    wait: { label: 'Wait', icon: 'clock', hint: 'Pause before the next step', make: function () { return { type: 'wait', seconds: 5 }; } },
    'if': { label: 'IF / ELSE', icon: 'help', hint: 'Do one thing or another', make: function () { return { type: 'if', condition: defaultCond('venue_status'), then: [], 'else': [] }; } },
    run_scene: { label: 'Run scene', icon: 'play', hint: 'Run another scene here', make: function () { return { type: 'run_scene' }; } },
    set_variable: { label: 'Set variable', icon: 'sliders', hint: 'Change a VenueFlow variable', make: function () { return { type: 'set_variable', value: true }; } },
    set_venue_status: { label: 'Mark venue open or closed', icon: 'flag', hint: 'Change the venue status', make: function () { return { type: 'set_venue_status', status: 'open' }; } },
    notify: { label: 'Send notification', icon: 'send', hint: 'Show a message to managers', make: function () { return { type: 'notify', message: '', level: 'info' }; } }
  };
  var PALETTE = [
    ['Displays', ['display_power', 'route_video']],
    ['Audio', ['route_audio', 'volume', 'mute', 'zone_power']],
    ['Room', ['lighting', 'shade']],
    ['Flow', ['wait', 'if', 'run_scene']],
    ['State', ['set_variable', 'set_venue_status', 'notify']]
  ];
  var TRIGGER_LABEL = {
    manual: 'Only when run by hand',
    scene_activated: 'A scene is activated',
    schedule: 'At a time of day',
    c4_event: 'A Control4 event (from Composer programming)',
    external: 'An event from another system',
    device_state: 'A display or zone changes state',
    c4_variable: 'A Control4 variable changes',
    venue_status: 'The venue opens or closes'
  };
  var TRIGGER_ORDER = ['schedule', 'scene_activated', 'venue_status', 'device_state', 'c4_event', 'external', 'c4_variable', 'manual'];
  var COND_LABEL = {
    venue_status: 'The venue is open or closed',
    time_range: 'The time of day is between',
    day_of_week: 'The day of the week is',
    display_state: 'A display is in a state',
    zone_state: 'An audio zone is in a state',
    source_available: 'A source is available',
    variable: 'A VenueFlow variable',
    c4_variable: 'A Control4 variable',
    context_area: 'It was pressed in an area',
    bool: 'Always or never'
  };
  var COND_ORDER = ['venue_status', 'time_range', 'day_of_week', 'display_state', 'zone_state', 'source_available', 'variable', 'c4_variable', 'context_area', 'bool'];

  function schemaList(name) { var s = S.boot && S.boot.schema; var l = s ? asList(s[name]) : []; return l.length ? l : null; }
  function limitOf(field, fallback) { var s = S.boot && S.boot.schema; var n = s && asMap(s.limits)[field]; return typeof n === 'number' ? n : fallback; }
  function maxWait() { var s = S.boot && S.boot.schema; return (s && Number(s.maxWaitSeconds)) || 600; }
  function plural(n, word) { return n + ' ' + word + (n === 1 ? '' : 's'); }
  function isSet(v) { return v !== undefined && v !== null && v !== ''; }

  /* ── module state (survives the shell's re-render) ───────────────────── */
  var view = { scenes: null, programming: null };   // the open scene / rule id
  var seenParams = null;                            // params are applied once, not on every re-render
  var active = null;                                // the section on screen
  var uids = new WeakMap(), uidSeq = 0;
  function uid(o) { var u = uids.get(o); if (!u) { u = 'u' + (++uidSeq); uids.set(o, u); } return u; }
  var openSteps = new WeakSet();                    // expanded step cards
  var openPick = new WeakSet();                     // steps whose "individual displays" list is open
  var tests = {};                                   // 'scene:id' | 'rule:id' -> testing panel state
  var runs = { data: null, at: 0, loading: false, error: null };   // the last EXECUTIONS reply
  var pollTimer = null, pollKey = null, pollBusy = false;
  var drag = null;
  var lives = [];                                   // repaint-in-place functions of the current render

  function live(el, paint) { lives.push(function () { paint(el); }); paint(el); return el; }
  function refreshLive() {
    var keep = focusMark();
    lives.forEach(function (f) { try { f(); } catch (e) { console.error(e); } });
    if (keep && keep.key && !document.contains(keep.el)) focusRestore(keep);
  }

  /* ── focus keeping across re-renders ─────────────────────────────────── */
  var FOCUSABLE = 'button, select, input, textarea';
  function root() { return document.querySelector('#main .sec'); }
  function focusMark() {
    var a = document.activeElement, r = root();
    if (!a || !r || !r.contains(a)) return null;
    var m = { el: a, key: (a.dataset && a.dataset.vpk) || null, tag: a.tagName, type: a.type || '' };
    if (!m.key) m.index = Array.prototype.indexOf.call(r.querySelectorAll(FOCUSABLE), a);
    return m;
  }
  function focusRestore(m) {
    var r = root(); if (!m || !r) return;
    var el = null;
    if (m.key) el = r.querySelector('[data-vpk="' + m.key + '"]');
    else if (m.index >= 0) {
      el = r.querySelectorAll(FOCUSABLE)[m.index] || null;
      if (el && (el.tagName !== m.tag || (el.type || '') !== m.type || /^(text|number|time|textarea|password)$/.test(el.type || ''))) el = null;
    }
    if (el && !el.disabled) { try { el.focus({ preventScroll: true }); } catch (e) { /* ignore */ } }
  }
  /* A change that redraws the section (selects, switches, buttons). */
  function commit(label, fn, opts) {
    var keep = opts && opts.focus === false ? null : focusMark();
    S.update(label, fn);
    focusRestore(keep);
  }
  /* A change from a text field: saved, summaries repainted in place, nothing redrawn. */
  function soft(label, fn) { S.update(label, fn, { silent: true }); refreshLive(); }
  function redraw() { var keep = focusMark(); S.refresh(); focusRestore(keep); }
  /* A yes/no question. (VF.modal keeps a dialog open when an action's value is `false`, so Cancel answers null.) */
  function ask(title, text, okLabel, kind) {
    return VF.modal({ title: title, icon: kind === 'danger' || kind === 'warn' ? 'alert' : 'help', body: text, actions: [{ label: 'Cancel', kind: 'ghost', value: null }, { label: okLabel || 'Confirm', kind: kind || 'primary', value: true }] }).then(function (v) { return v === true; });
  }
  function toTop() { var m = document.getElementById('main'); if (m) m.scrollTop = 0; }

  /* ── small controls ──────────────────────────────────────────────────── */
  function field(label, control, hint) { return h('label.lbl', label, control, hint ? h('span.hint', hint) : null); }
  function group(label, control, hint, cls) { return h('div.vp-group' + (cls || ''), h('span.vp-group-label', label), control, hint ? h('span.hint', hint) : null); }
  function textField(label, value, onChange, opts) {
    opts = opts || {};
    var input = h(opts.multiline ? 'textarea.field' : 'input.field', { type: 'text', value: isSet(value) ? value : '', placeholder: opts.placeholder, maxlength: opts.max || 80 });
    input.addEventListener('change', function () { onChange(input.value.trim()); });
    return field(label, input, opts.hint);
  }
  function numField(label, value, onChange, opts) {
    opts = opts || {};
    var input = h('input.field', { type: 'number', value: isSet(value) ? value : '', min: opts.min, max: opts.max, step: opts.step || 1, placeholder: opts.placeholder, inputmode: 'numeric' });
    input.addEventListener('change', function () {
      if (input.value === '') { onChange(undefined); return; }
      var n = Number(input.value); if (isNaN(n)) { onChange(undefined); return; }
      if (opts.integer !== false) n = Math.round(n);
      if (opts.min !== undefined) n = Math.max(opts.min, n);
      if (opts.max !== undefined) n = Math.min(opts.max, n);
      input.value = n; onChange(n);
    });
    return field(label, input, opts.hint);
  }
  function timeField(label, value, onChange, hint) {
    var input = h('input.field', { type: 'time', value: isSet(value) ? value : '', placeholder: 'HH:MM' });
    input.addEventListener('change', function () { var v = String(input.value || '').slice(0, 5); onChange(/^\d\d:\d\d$/.test(v) ? v : undefined); });
    return field(label, input, hint);
  }
  /* options: [[value, label], ...] */
  function seg(options, value, onChange, key) {
    return h('div.seg.vp-seg', { role: 'group' }, options.map(function (o) {
      return h('button' + (o[0] === value ? '.on' : ''), { type: 'button', 'aria-pressed': o[0] === value ? 'true' : 'false', dataset: key ? { vpk: key + ':' + o[0] } : null, onclick: function () { if (o[0] !== value) onChange(o[0]); } }, o[1]);
    }));
  }
  function dayPicker(days, onChange, key) {
    var chosen = asList(days);
    return h('div.vp-days', { role: 'group', 'aria-label': 'Days of the week' }, DAY.map(function (name, i) {
      var d = i + 1, on = chosen.indexOf(d) >= 0;
      return h('button' + (on ? '.on' : ''), { type: 'button', 'aria-pressed': on ? 'true' : 'false', title: DAY_LONG[i], dataset: key ? { vpk: key + ':d' + d } : null, onclick: function () {
        var next = chosen.filter(function (x) { return x !== d; }); if (!on) next.push(d);
        next.sort(function (a, b) { return a - b; }); onChange(next);
      } }, name);
    }));
  }
  /* A select over entities of the draft. An id that no longer exists stays visible as "(missing)". */
  function refPick(label, fieldName, value, onChange, opts) {
    opts = opts || {};
    var all = S.list(fieldName);
    var items = opts.filter ? all.filter(opts.filter) : all;
    var options = items.map(function (x) { return { value: x.id, label: x.name }; });
    var state = '';
    if (!isSet(value)) state = 'unset';
    else if (!items.some(function (x) { return x.id === value; })) {
      var known = VF.byId(all, value);
      options.unshift({ value: value, label: known ? known.name + ' ' + (opts.filterNote || '(not usable here)') : '(missing) ' + value });
      state = 'missing';
    }
    var node = S.select(label, options, value, onChange, { none: opts.none || 'Choose...', hint: opts.hint || (!all.length ? 'Nothing to choose from yet.' : undefined) });
    if (state) node.classList.add('vp-' + state + '-field');
    return node;
  }
  /* A value editor typed like a VenueFlow variable. */
  function valueField(label, type, value, onFull, onSoft) {
    if (type === 'bool') return S.select(label, [{ value: 'true', label: 'Yes (true)' }, { value: 'false', label: 'No (false)' }], value === true || value === 'true' ? 'true' : 'false', function (v) { onFull(v === 'true'); });
    if (type === 'number') return numField(label, typeof value === 'number' ? value : undefined, function (n) { onSoft(n === undefined ? 0 : n); }, { integer: false, step: 'any' });
    return textField(label, typeof value === 'string' ? value : (isSet(value) ? String(value) : ''), onSoft, { max: 200 });
  }
  function coerce(type, value) {
    if (type === 'bool') return value === true || value === 'true';
    if (type === 'number') return typeof value === 'number' ? value : (isNaN(Number(value)) || value === '' || typeof value === 'boolean' ? 0 : Number(value));
    return typeof value === 'string' ? value : '';
  }
  function iconBtn(name, label, onClick, key, opts) {
    opts = opts || {};
    return h('button.vp-ib' + (opts.danger ? '.danger' : ''), { type: 'button', title: label, 'aria-label': label, disabled: opts.disabled, dataset: key ? { vpk: key } : null, onclick: function (e) { e.stopPropagation(); onClick(e); } }, icon(name));
  }
  function btn(cls, iconName, label, onClick, key, disabled) {
    return h('button.btn.vp-btn' + (cls || ''), { type: 'button', disabled: disabled, dataset: key ? { vpk: key } : null, onclick: onClick }, iconName ? icon(iconName) : null, label);
  }

  /* ── wording (the same words as rules.lua) ───────────────────────────── */
  /* A description is a list of parts: text, or { t, c } for a marked part
     ("(missing)" in red, "(not set)" in amber). */
  function nm(fieldName, id) {
    if (!isSet(id)) return { t: '(not set)', c: 'unset' };
    var x = S.find(fieldName, id);
    return x ? String(x.name) : { t: '(missing)', c: 'missing', title: String(id) };
  }
  function val(v) { if (v === undefined || v === null) return { t: '(not set)', c: 'unset' }; return v === '' ? '""' : String(v); }
  function targetParts(target) {
    if (!target || typeof target !== 'object') return [{ t: '(no displays)', c: 'unset' }];
    if (target.all === true) return ['all displays'];
    var parts = [];
    function add(p) { if (parts.length) parts.push(', '); parts = parts.concat(p); }
    asList(target.groupIds).forEach(function (id) { add(['group ', nm('groups', id)]); });
    asList(target.areaIds).forEach(function (id) { add(['area ', nm('areas', id)]); });
    var ids = asList(target.displayIds);
    if (ids.length > 0 && ids.length <= 3) ids.forEach(function (id) { add([nm('displays', id)]); });
    else if (ids.length > 3) {
      var gone = ids.filter(function (id) { return !S.find('displays', id); }).length;
      add([ids.length + ' displays']); if (gone) parts.push(' ', { t: '(' + gone + ' missing)', c: 'missing' });
    }
    return parts.length ? parts : [{ t: '(no displays)', c: 'unset' }];
  }
  function presetPart(st) {
    var l = S.find('lighting', st.lightingId);
    var p = l ? VF.byId(l.presets, st.presetId) : null;
    if (p) return String(p.name);
    return isSet(st.presetId) && l ? { t: '(missing)', c: 'missing', title: String(st.presetId) } : { t: '(not set)', c: 'unset' };
  }
  function describeStep(st) {
    var t = st && typeof st === 'object' ? st.type : '?';
    switch (t) {
      case 'display_power': return ['Power ', val(st.power), ' '].concat(targetParts(st.target));
      case 'route_video': return ['Route ', nm('sources', st.sourceId), ' to '].concat(targetParts(st.target));
      case 'route_audio': return ['Play ', nm('sources', st.sourceId), ' in ', nm('audioZones', st.zoneId)];
      case 'volume': return ['Set ', nm('audioZones', st.zoneId), ' volume to ', val(st.level), '%'];
      case 'mute': return [st.muted ? 'Mute ' : 'Unmute ', nm('audioZones', st.zoneId)];
      case 'zone_power': return ['Turn off ', nm('audioZones', st.zoneId)];
      case 'lighting': return ['Lighting ', nm('lighting', st.lightingId), ': ', presetPart(st)];
      case 'shade': return [st.action === 'open' ? 'Open' : 'Close', ' shade ', nm('shades', st.shadeId)];
      case 'wait': return ['Wait ', val(st.seconds), ' s'];
      case 'run_scene': return ['Run scene ', nm('scenes', st.sceneId)];
      case 'set_variable': return ['Set ', nm('variables', st.variableId), ' to ', val(st.value)];
      case 'set_venue_status': return ['Mark the venue ', val(st.status)];
      case 'notify': return ['Notify: ', isSet(st.message) ? String(st.message).replace(/\s+/g, ' ').slice(0, 80) : { t: '(no message)', c: 'unset' }];
      case 'if': return ['IF '].concat(describeCondition(st.condition));
    }
    return ['Unknown step'];
  }
  function describeCondition(c) {
    if (!c || typeof c !== 'object') return ['(no condition)'];
    var parts, v;
    switch (c.op) {
      case 'and': case 'or':
        parts = ['('];
        asList(c.items).forEach(function (item, i) { if (i) parts.push(c.op === 'and' ? ' AND ' : ' OR '); parts = parts.concat(describeCondition(item)); });
        if (!asList(c.items).length) parts.push({ t: 'nothing yet', c: 'unset' });
        parts.push(')'); return parts;
      case 'not': return ['NOT '].concat(describeCondition(c.item));
      case 'bool': return [c.value ? 'always' : 'never'];
      case 'venue_status': return ['venue is ', val(c.is)];
      case 'time_range': return ['time is ', val(c.from), ' to ', val(c.to)];
      case 'day_of_week': return ['day is ', asList(c.days).length ? asList(c.days).map(function (d) { return DAY[d - 1] || '?'; }).join('/') : { t: '(no day)', c: 'unset' }];
      case 'display_state': v = c.field === 'source' ? nm('sources', c.equals) : val(c.equals); return [nm('displays', c.displayId), ' ', String(c.field), ' is ', v];
      case 'zone_state': v = c.field === 'source' ? nm('sources', c.equals) : val(c.equals); return [nm('audioZones', c.zoneId), ' ', String(c.field), ' is ', v];
      case 'source_available': return [nm('sources', c.sourceId), ' is available'];
      case 'variable': return [nm('variables', c.variableId), ' ', CMP_TEXT[c.cmp || 'eq'] || '?', ' ', val(c.value)];
      case 'c4_variable': return ['Control4 ', val(c.deviceId), '.', isSet(c.variable) ? String(c.variable) : { t: '(not set)', c: 'unset' }, ' ', CMP_TEXT[c.cmp || 'eq'] || '?', ' ', val(c.value)];
      case 'context_area': return ['pressed in ', nm('areas', c.areaId)];
    }
    return ['(unknown condition)'];
  }
  function daysText(days) {
    var d = asList(days).slice().sort(function (a, b) { return a - b; });
    if (!d.length) return { t: '(no day chosen)', c: 'unset' };
    var s = d.join('');
    if (s === '1234567') return 'every day';
    if (s === '12345') return 'Mon to Fri';
    if (s === '67') return 'Sat and Sun';
    return d.map(function (x) { return DAY[x - 1] || '?'; }).join(', ');
  }
  function describeTrigger(t) {
    t = asMap(t);
    switch (t.type) {
      case 'manual': return ['only when run by hand from this Studio'];
      case 'scene_activated': return ['scene ', nm('scenes', t.sceneId), ' is activated'];
      case 'schedule': return ['it is ', isSet(t.time) ? String(t.time) : { t: '(no time)', c: 'unset' }, ' on ', daysText(t.days)];
      case 'c4_event': return ['Control4 event "', isSet(t.name) ? String(t.name) : { t: '(no name)', c: 'unset' }, '" is triggered'];
      case 'external': return ['external event "', isSet(t.name) ? String(t.name) : { t: '(no name)', c: 'unset' }, '" arrives'];
      case 'device_state':
        var who = t.entity === 'zone' ? nm('audioZones', t.id) : nm('displays', t.id);
        var to = !isSet(t.equals) ? [] : [' to ', t.field === 'source' ? nm('sources', t.equals) : String(t.equals)];
        return [who, ' ', String(t.field || 'state'), ' changes'].concat(to);
      case 'c4_variable': return ['Control4 variable ', val(t.deviceId), '.', isSet(t.variable) ? String(t.variable) : { t: '(not set)', c: 'unset' }, ' changes'];
      case 'venue_status': return ['the venue ', t.status === 'closed' ? 'closes' : 'opens'];
    }
    return [{ t: '(unknown trigger)', c: 'missing' }];
  }
  function partsText(parts) { return parts.map(function (p) { return typeof p === 'string' ? p : p.t; }).join(''); }
  function partsNodes(parts) { return parts.map(function (p) { return typeof p === 'string' ? p : h('span.vp-' + p.c, { title: p.title || (p.c === 'missing' ? 'This no longer exists in the draft' : 'Not chosen yet') }, p.t); }); }
  function partsHave(parts, cls) { return parts.some(function (p) { return typeof p !== 'string' && p.c === cls; }); }

  function countSteps(steps) { var n = 0; S.eachStep(asList(steps), function () { n++; }); return n; }
  function targetEmpty(t) { t = asMap(t); return t.all !== true && !asList(t.displayIds).length && !asList(t.groupIds).length && !asList(t.areaIds).length; }
  /* 'unset' (amber "Not set up yet": the driver reports STEP_INCOMPLETE), 'bad' (cannot run as it is), or null. */
  function stepState(st) {
    if (!st || typeof st !== 'object' || !STEP[st.type]) return 'bad';
    var parts = describeStep(st);
    if (st.type === 'if') {
      if (!st.condition || typeof st.condition !== 'object') return 'bad';
      return partsHave(parts, 'missing') ? 'bad' : (partsHave(parts, 'unset') ? 'unset' : null);
    }
    if ((st.type === 'display_power' || st.type === 'route_video') && asMap(st.target).all !== true) {
      var t = asMap(st.target);
      if (asList(t.displayIds).some(function (id) { return !S.find('displays', id); }) || asList(t.groupIds).some(function (id) { return !S.find('groups', id); }) || asList(t.areaIds).some(function (id) { return !S.find('areas', id); })) return 'bad';
    }
    if (partsHave(parts, 'missing')) return 'bad';
    if (st.type === 'wait' && !(typeof st.seconds === 'number' && st.seconds > 0 && st.seconds <= maxWait())) return 'bad';
    if (st.type === 'volume' && isSet(st.zoneId) && !(typeof st.level === 'number' && st.level >= 0 && st.level <= 100)) return 'bad';
    if (st.type === 'notify' && !isSet(String(st.message || '').trim())) return 'bad';
    if (partsHave(parts, 'unset')) return 'unset';
    return null;
  }
  function resolveTarget(target) {
    target = asMap(target);
    var displays = S.list('displays');
    if (target.all === true) return displays.map(function (d) { return d.id; });
    var wanted = {}, areas = {};
    asList(target.displayIds).forEach(function (id) { wanted[id] = true; });
    asList(target.groupIds).forEach(function (gid) { var g = S.find('groups', gid); asList(g && g.displayIds).forEach(function (id) { wanted[id] = true; }); });
    asList(target.areaIds).forEach(function (id) { areas[id] = true; });
    return displays.filter(function (d) { return wanted[d.id] || (isSet(d.areaId) && areas[d.areaId]); }).map(function (d) { return d.id; });
  }

  /* ── issues ──────────────────────────────────────────────────────────── */
  function relPath(path) { return String(path || '').replace(/^(scenes|rules)\[\d+\]\.?/, ''); }
  function condTrail(p) { var out = '', m, re = /\.items\[(\d+)\]|\.item\b/g; while ((m = re.exec(p))) out += m[1] ? ', condition ' + m[1] : ', inside NOT'; return out; }
  /* "program.steps[3].then[1].sourceId" -> "Step 3 > THEN step 1" */
  function readablePath(path) {
    var p = relPath(path), m, out = [];
    if (/^trigger/.test(p)) return 'WHEN';
    if (/^condition/.test(p)) return 'IF' + condTrail(p.slice(9));
    if ((m = /^program\.steps\[(\d+)\]/.exec(p))) {
      out.push('Step ' + m[1]); p = p.slice(m[0].length);
      while ((m = /^\.(then|else)\[(\d+)\]/.exec(p))) { out.push(m[1].toUpperCase() + ' step ' + m[2]); p = p.slice(m[0].length); }
      if (/^\.condition/.test(p)) out.push('its IF' + condTrail(p.slice(10)));
      return out.join(' > ');
    }
    if (/^program/.test(p)) return 'DO';
    return '';
  }
  function issueRows(list) {
    return h('div.col.tight', asList(list).map(function (i) {
      var where = readablePath(i.path);
      return h('div.banner.vp-issue.' + (i.severity === 'error' ? 'bad' : 'warn'), icon('alert', 'sm'), h('div.small', where ? h('b', where + ': ') : null, i.message));
    }));
  }
  /* Saved issues point at steps by position. Between an edit and the driver's answer to the save,
     positions may have moved, so the per-step marks wait for the save. */
  var issuesStale = false;
  S.on('config', function () { issuesStale = true; });
  S.on('saved', function () { issuesStale = false; });
  S.on('boot', function () { issuesStale = false; });
  function stepIssues(ctx, path) {
    if (issuesStale) return [];
    return S.issuesFor(ctx.kind, ctx.item.id).filter(function (i) {
      var r = relPath(i.path);
      return r === path || (r.indexOf(path + '.') === 0 && r.indexOf(path + '.then[') !== 0 && r.indexOf(path + '.else[') !== 0);
    });
  }

  /* ── EXECUTIONS (runs, last run, upcoming, variable values) ──────────── */
  function setRuns(data) {
    runs.data = data || null; runs.at = Date.now(); runs.error = null;
    var byId = {}; asList(data && data.executions).forEach(function (x) { byId[x.id] = x; });
    Object.keys(tests).forEach(function (k) { var t = tests[k]; if (t.run && t.run.execution && byId[t.run.execution.id]) t.run.execution = byId[t.run.execution.id]; });
  }
  function loadRuns() {
    if (runs.loading) return Promise.resolve(false);
    runs.loading = true;
    return VF.api('EXECUTIONS', {}, { since: false }).then(function (r) {
      runs.loading = false;
      if (r.ok && r.data) setRuns(r.data); else runs.error = r.message || 'The run history could not be read.';
      refreshLive();
      return r.ok;
    });
  }
  function stopPoll() { if (pollTimer) clearInterval(pollTimer); pollTimer = null; pollKey = null; }
  function startPoll(key) {
    stopPoll(); pollKey = key;
    pollTimer = setInterval(function () {
      if (pollBusy) return;
      pollBusy = true;
      VF.api('EXECUTIONS', {}, { since: false }).then(function (r) {
        pollBusy = false;
        if (!r.ok || !r.data) return;
        setRuns(r.data);
        var t = tests[pollKey], ex = t && t.run && t.run.execution;
        if (!ex || !ACTIVE[ex.status]) stopPoll();
        refreshLive();
      });
    }, 1000);
  }
  function enter(id, params) {
    lives = [];
    if (params && params !== seenParams) {
      seenParams = params;
      if (params.sceneId) view.scenes = params.sceneId;
      if (params.ruleId) view.programming = params.ruleId;
    }
    if (active !== id) { active = id; loadRuns(); }
  }
  function leave() { active = null; stopPoll(); drag = null; lives = []; }

  /* ── condition editor ────────────────────────────────────────────────── */
  function defaultCond(op) {
    switch (op) {
      case 'venue_status': return { op: op, is: 'open' };
      case 'time_range': return { op: op, from: '17:00', to: '23:00' };
      case 'day_of_week': return { op: op, days: [1, 2, 3, 4, 5] };
      case 'display_state': return { op: op, field: 'power', equals: 'on' };
      case 'zone_state': return { op: op, field: 'power', equals: 'on' };
      case 'source_available': return { op: op };
      case 'variable': return { op: op, cmp: 'eq', value: true };
      case 'c4_variable': return { op: op, variable: '', cmp: 'eq', value: '' };
      case 'context_area': return { op: op };
      case 'bool': return { op: op, value: true };
      case 'and': case 'or': return { op: op, items: [defaultCond('venue_status')] };
    }
    return { op: 'bool', value: true };
  }
  function condHeight(c) {
    if (!c || typeof c !== 'object') return 1;
    if (c.op === 'and' || c.op === 'or') return 1 + asList(c.items).reduce(function (m, x) { return Math.max(m, condHeight(x)); }, 0);
    if (c.op === 'not') return 1 + condHeight(c.item);
    return 1;
  }
  function stateValueControl(c, sourceOptional) {
    if (c.field === 'source') {
      return refPick('Source', 'sources', c.equals, function (v) { commit('Change condition', function () { if (v === undefined) delete c.equals; else c.equals = v; }); }, { none: sourceOptional ? 'Any source (any change)' : 'Choose...' });
    }
    if (c.field === 'muted') {
      var mv = c.equals === true || c.equals === 'true' ? 'true' : (c.equals === false || c.equals === 'false' ? 'false' : '');
      return S.select('Is', [{ value: 'true', label: 'Muted' }, { value: 'false', label: 'Not muted' }], mv, function (v) { commit('Change condition', function () { if (v === undefined) delete c.equals; else c.equals = v === 'true'; }); }, sourceOptional ? { none: 'Any change' } : (mv === '' ? { none: 'Choose...' } : undefined));
    }
    var pv = c.equals === 'on' || c.equals === 'off' ? c.equals : '';
    return S.select('Is', [{ value: 'on', label: 'On' }, { value: 'off', label: 'Off' }], pv, function (v) { commit('Change condition', function () { if (v === undefined) delete c.equals; else c.equals = v; }); }, sourceOptional ? { none: 'Any change' } : (pv === '' ? { none: 'Choose...' } : undefined));
  }
  function defaultEquals(fieldName) { return fieldName === 'muted' ? true : (fieldName === 'source' ? undefined : 'on'); }
  function condFields(c) {
    var out = [];
    function full(fn) { commit('Change condition', fn); }
    function softly(fn) { soft('Change condition', fn); }
    switch (c.op) {
      case 'venue_status':
        out.push(group('Venue is', seg([['open', 'Open'], ['closed', 'Closed']], c.is, function (v) { full(function () { c.is = v; }); }, uid(c) + ':is')));
        break;
      case 'time_range':
        out.push(timeField('From', c.from, function (v) { softly(function () { c.from = v; }); }));
        out.push(timeField('To', c.to, function (v) { softly(function () { c.to = v; }); }, 'A range over midnight is allowed (22:00 to 02:00).'));
        break;
      case 'day_of_week':
        out.push(group('On', dayPicker(c.days, function (d) { full(function () { c.days = d; }); }, uid(c)), null, '.vp-span'));
        break;
      case 'display_state':
        out.push(refPick('Display', 'displays', c.displayId, function (v) { full(function () { c.displayId = v; }); }));
        out.push(S.select('State', [{ value: 'power', label: 'Power' }, { value: 'source', label: 'Source' }], c.field, function (v) { full(function () { c.field = v || 'power'; c.equals = defaultEquals(c.field); if (c.equals === undefined) delete c.equals; }); }));
        out.push(stateValueControl(c, false));
        break;
      case 'zone_state':
        out.push(refPick('Audio zone', 'audioZones', c.zoneId, function (v) { full(function () { c.zoneId = v; }); }));
        out.push(S.select('State', [{ value: 'power', label: 'Power' }, { value: 'muted', label: 'Mute' }, { value: 'source', label: 'Source' }], c.field, function (v) { full(function () { c.field = v || 'power'; c.equals = defaultEquals(c.field); if (c.equals === undefined) delete c.equals; }); }));
        out.push(stateValueControl(c, false));
        break;
      case 'source_available':
        out.push(refPick('Source', 'sources', c.sourceId, function (v) { full(function () { c.sourceId = v; }); }, { hint: 'True when the source is enabled, mapped and its device answers.' }));
        break;
      case 'variable':
        var def = S.find('variables', c.variableId);
        out.push(refPick('Variable', 'variables', c.variableId, function (v) { full(function () { c.variableId = v; var d = S.find('variables', v); if (d) { c.value = coerce(d.type, c.value); if (d.type !== 'number' && c.cmp !== 'ne') c.cmp = 'eq'; } }); }, { hint: !S.list('variables').length ? 'Add a variable under Visual Programming first.' : undefined }));
        out.push(S.select('Compare', (def && def.type !== 'number' ? ['eq', 'ne'] : (schemaList('comparators') || Object.keys(CMP_TEXT))).map(function (k) { return { value: k, label: CMP_LABEL[k] || k }; }), c.cmp || 'eq', function (v) { full(function () { c.cmp = v || 'eq'; }); }));
        out.push(valueField('Value', def ? def.type : (typeof c.value === 'boolean' ? 'bool' : (typeof c.value === 'number' ? 'number' : 'string')), c.value, function (v) { full(function () { c.value = v; }); }, function (v) { softly(function () { c.value = v; }); }));
        break;
      case 'c4_variable':
        out.push(numField('Control4 device id', c.deviceId, function (n) { softly(function () { if (n === undefined) delete c.deviceId; else c.deviceId = n; }); }, { min: 1, hint: 'The device that owns the variable (Composer shows the id).' }));
        out.push(textField('Variable name', c.variable, function (v) { softly(function () { c.variable = v; }); }, { placeholder: 'For example LIGHT_LEVEL' }));
        out.push(S.select('Compare', (schemaList('comparators') || Object.keys(CMP_TEXT)).map(function (k) { return { value: k, label: CMP_LABEL[k] || k }; }), c.cmp || 'eq', function (v) { full(function () { c.cmp = v || 'eq'; }); }));
        out.push(textField('Value', isSet(c.value) ? String(c.value) : '', function (v) { softly(function () { c.value = v !== '' && !isNaN(Number(v)) ? Number(v) : v; }); }, { hint: 'A number is compared as a number. For a yes/no variable use 1 or 0.' }));
        break;
      case 'context_area':
        out.push(refPick('Area', 'areas', c.areaId, function (v) { full(function () { c.areaId = v; }); }, { hint: 'True only when a scene is pressed from a screen in that area.' }));
        break;
      case 'bool':
        out.push(group('Result', seg([[true, 'Always'], [false, 'Never']], c.value === true, function (v) { full(function () { c.value = v; }); }, uid(c) + ':b')));
        break;
    }
    return out;
  }
  /* slot = { get(), set(cond | undefined), fixed: true when the root may not be removed } */
  function condNode(c, slot, depth) {
    var id = uid(c && typeof c === 'object' ? c : slot);
    function wrapNot() { commit('Negate condition', function () { slot.set({ op: 'not', item: c }); }); }
    var canWrap = depth + condHeight(c) <= MAX_COND_DEPTH;
    var notBtn = btn('.ghost', null, 'NOT', wrapNot, id + ':not', !canWrap);
    notBtn.title = canWrap ? 'Use the opposite of this' : 'Conditions can be nested ' + MAX_COND_DEPTH + ' deep; this cannot go deeper.';
    var removeBtn = slot.fixed ? null : iconBtn('trash', 'Remove this condition', function () { commit('Remove condition', function () { slot.set(undefined); }, { focus: false }); }, id + ':rm', { danger: true });

    if (!c || typeof c !== 'object' || !COND_LABEL[c.op] && c.op !== 'and' && c.op !== 'or' && c.op !== 'not') {
      return h('div.vp-cleaf.bad', h('div.grow', h('span.vp-missing', 'Unknown condition. It cannot be evaluated.')), btn('', 'refresh', 'Replace', function () { commit('Replace condition', function () { slot.set(defaultCond('venue_status')); }); }), removeBtn);
    }
    if (c.op === 'not') {
      return h('div.vp-cnot',
        h('div.vp-chead', h('span.chip.warn', 'NOT'), h('span.grow.small.muted', 'True when the following is NOT true'),
          btn('.ghost', 'x', 'Remove NOT', function () { commit('Remove NOT', function () { slot.set(c.item); }); }, id + ':unnot')),
        condNode(c.item, { get: function () { return c.item; }, set: function (v) { if (v === undefined) slot.set(undefined); else c.item = v; }, fixed: slot.fixed }, depth + 1));
    }
    if (c.op === 'and' || c.op === 'or') {
      var items = asList(c.items);
      var canNest = depth + 2 <= MAX_COND_DEPTH;
      var box = h('div.vp-cgroup',
        h('div.vp-chead',
          seg([['and', 'ALL OF'], ['or', 'ANY OF']], c.op, function (v) { commit('Change group', function () { c.op = v; }); }, id + ':op'),
          h('span.grow.small.muted', c.op === 'and' ? 'every line below must be true' : 'at least one line below must be true'),
          notBtn, iconBtn('trash', 'Remove this group', function () {
            if (!items.length) { commit('Remove group', function () { slot.set(undefined); }, { focus: false }); return; }
            ask('Remove group', 'This removes the group and its ' + plural(items.length, 'condition') + '.', 'Remove', 'danger').then(function (ok) { if (ok) commit('Remove group', function () { slot.set(undefined); }, { focus: false }); });
          }, id + ':rm', { danger: true })));
      items.forEach(function (child, i) {
        if (i) box.appendChild(h('div.vp-cjoin', c.op === 'and' ? 'AND' : 'OR'));
        box.appendChild(condNode(child, { get: function () { return asList(c.items)[i]; }, set: function (v) { c.items = asList(c.items); if (v === undefined) c.items.splice(i, 1); else c.items[i] = v; } }, depth + 1));
      });
      if (!items.length) box.appendChild(h('div.vp-nosteps.warn', 'This group is empty. Add a condition, or remove the group.'));
      var addGroup = btn('.ghost', 'layers', 'Add group', function () { commit('Add group', function () { c.items = asList(c.items); c.items.push(defaultCond(c.op === 'and' ? 'or' : 'and')); }); }, id + ':addg', !canNest || depth + 1 >= MAX_COND_DEPTH);
      if (addGroup.disabled) addGroup.title = 'Conditions can be nested ' + MAX_COND_DEPTH + ' deep.';
      box.appendChild(h('div.row.wrap.tight',
        btn('.outline', 'plus', 'Add condition', function () { commit('Add condition', function () { c.items = asList(c.items); c.items.push(defaultCond('venue_status')); }); }, id + ':addc', depth + 1 > MAX_COND_DEPTH),
        addGroup));
      return box;
    }
    var allowed = schemaList('conditionOps');
    var ops = COND_ORDER.filter(function (op) { return !allowed || allowed.indexOf(op) >= 0; }).map(function (op) { return { value: op, label: COND_LABEL[op] }; });
    var opSel = S.select('Check', ops, c.op, function (v) {
      if (!v || v === c.op) return;
      commit('Change condition', function () { var next = defaultCond(v); Object.keys(c).forEach(function (k) { delete c[k]; }); Object.assign(c, next); });
    });
    return h('div.vp-cleaf', h('div.vp-cfields', opSel, condFields(c)), h('div.vp-cacts', notBtn, removeBtn));
  }
  /* The whole tree for one owner, with "add another" at the root when the root is a single line. */
  function condEditor(slot) {
    var c = slot.get();
    var box = h('div.vp-cond', condNode(c, slot, 1));
    if (c && typeof c === 'object' && c.op !== 'and' && c.op !== 'or') {
      var id = uid(c);
      box.appendChild(h('div.row.wrap.tight',
        btn('.outline', 'plus', 'Add another condition', function () { commit('Add condition', function () { slot.set({ op: 'and', items: [slot.get(), defaultCond('venue_status')] }); }); }, id + ':wrap', condHeight(c) + 1 > MAX_COND_DEPTH),
        h('span.hint', 'Groups them as ALL OF; switch the group to ANY OF when one is enough.')));
    }
    return box;
  }

  /* ── target picker ───────────────────────────────────────────────────── */
  function targetPicker(st) {
    var t = asMap(st.target), all = t.all === true;
    function tgt() { if (!st.target || typeof st.target !== 'object' || Array.isArray(st.target)) st.target = {}; return st.target; }
    function toggleIn(key, id, on) {
      commit('Choose displays', function () { var o = tgt(); delete o.all; var list = asList(o[key]).filter(function (x) { return x !== id; }); if (on) list.push(id); o[key] = list; });
    }
    function listOf(title, key, fieldName, describe) {
      var chosen = asList(t[key]), items = S.list(fieldName);
      var grid = h('div.vp-checks');
      items.forEach(function (x) { grid.appendChild(S.check(describe ? describe(x) : x.name, chosen.indexOf(x.id) >= 0, function (on) { toggleIn(key, x.id, on); })); });
      chosen.filter(function (id) { return !VF.byId(items, id); }).forEach(function (id) {
        var c = S.check('(missing) ' + id, true, function (on) { toggleIn(key, id, on); }); c.classList.add('vp-missing'); c.title = 'This no longer exists. Untick it to remove it from the step.'; grid.appendChild(c);
      });
      if (!grid.firstChild) grid.appendChild(h('span.hint', 'None in this venue yet.'));
      return { title: title, count: chosen.length, node: grid };
    }
    var box = h('div.vp-target');
    var n = resolveTarget(st.target).length;
    box.appendChild(h('div.row.between.wrap',
      h('span.vp-group-label', 'Which displays'),
      h('span.chip.' + (n ? 'teal' : 'warn'), icon('monitor', 'sm'), all ? 'All ' + plural(n, 'display') : (n ? plural(n, 'display') : 'No displays chosen'))));
    box.appendChild(S.check('All displays (including ones added later)', all, function (on) { commit('Choose displays', function () { st.target = on ? { all: true } : { displayIds: [], groupIds: [], areaIds: [] }; }); }));
    if (!all) {
      var groups = listOf('Display groups', 'groupIds', 'groups', function (g) { return g.name + ' (' + asList(g.displayIds).length + ')'; });
      var areas = listOf('Areas', 'areaIds', 'areas', function (a) { return a.name + ' (' + S.list('displays').filter(function (d) { return d.areaId === a.id; }).length + ')'; });
      var displays = listOf('Individual displays', 'displayIds', 'displays');
      box.appendChild(h('div.vp-target-cols',
        h('div.vp-target-col', h('h4', groups.title), groups.node),
        h('div.vp-target-col', h('h4', areas.title), areas.node)));
      var showAll = openPick.has(st) || displays.count > 0;
      box.appendChild(h('div.vp-target-col',
        h('div.row.between', h('h4', displays.title + (displays.count ? ' (' + displays.count + ' chosen)' : '')),
          displays.count ? null : btn('.ghost', showAll ? 'chevron-up' : 'chevron-down', showAll ? 'Hide' : 'Show the list', function () { if (showAll) openPick.delete(st); else openPick.add(st); redraw(); }, uid(st) + ':pick')),
        showAll ? displays.node : null));
      box.appendChild(h('span.hint', 'A display is counted once, however it is chosen. Group and area membership is read when the step runs.'));
    }
    return box;
  }

  /* ── step fields ─────────────────────────────────────────────────────── */
  function stepFields(ctx, st) {
    var f = h('div.vp-fields');
    function full(fn) { commit('Change step', fn); }
    function softly(fn) { soft('Change step', fn); }
    var k = uid(st), zone;
    switch (st.type) {
      case 'display_power':
        f.appendChild(group('Switch them', seg([['on', 'On'], ['off', 'Off']], st.power, function (v) { full(function () { st.power = v; }); }, k + ':pw'), 'On selects each display\'s last or default source.'));
        f.appendChild(targetPicker(st));
        break;
      case 'route_video':
        f.appendChild(refPick('Source', 'sources', st.sourceId, function (v) { full(function () { if (v === undefined) delete st.sourceId; else st.sourceId = v; }); }, { filter: function (s) { return s.video !== false; }, filterNote: '(no video)' }));
        f.appendChild(targetPicker(st));
        break;
      case 'route_audio':
        f.appendChild(refPick('Audio zone', 'audioZones', st.zoneId, function (v) { full(function () { if (v === undefined) delete st.zoneId; else st.zoneId = v; }); }));
        f.appendChild(refPick('Source', 'sources', st.sourceId, function (v) { full(function () { if (v === undefined) delete st.sourceId; else st.sourceId = v; }); }, { filter: function (s) { return s.audio !== false; }, filterNote: '(no audio)' }));
        break;
      case 'volume':
        zone = S.find('audioZones', st.zoneId);
        f.appendChild(refPick('Audio zone', 'audioZones', st.zoneId, function (v) { full(function () { if (v === undefined) delete st.zoneId; else st.zoneId = v; }); }));
        f.appendChild(numField('Volume (0 to 100)', st.level, function (n) { softly(function () { if (n === undefined) delete st.level; else st.level = n; }); }, { min: 0, max: 100, hint: zone ? 'This zone is limited to ' + (zone.minVolume || 0) + ' to ' + (zone.maxVolume === undefined ? 100 : zone.maxVolume) + '; a level outside is clamped.' : undefined }));
        break;
      case 'mute':
        f.appendChild(refPick('Audio zone', 'audioZones', st.zoneId, function (v) { full(function () { if (v === undefined) delete st.zoneId; else st.zoneId = v; }); }));
        f.appendChild(group('Do', seg([[true, 'Mute'], [false, 'Unmute']], st.muted === true, function (v) { full(function () { st.muted = v; }); }, k + ':mu')));
        break;
      case 'zone_power':
        f.appendChild(refPick('Audio zone', 'audioZones', st.zoneId, function (v) { full(function () { if (v === undefined) delete st.zoneId; else st.zoneId = v; st.power = 'off'; }); }, { hint: 'A zone can only be switched off here. Route audio to start it.' }));
        break;
      case 'lighting':
        var light = S.find('lighting', st.lightingId);
        f.appendChild(refPick('Lighting', 'lighting', st.lightingId, function (v) { full(function () { if (v === undefined) delete st.lightingId; else st.lightingId = v; delete st.presetId; }); }));
        var presets = asList(light && light.presets).map(function (p) { return { value: p.id, label: p.name }; });
        var missingPreset = isSet(st.presetId) && light && !VF.byId(light.presets, st.presetId);
        if (missingPreset) presets.unshift({ value: st.presetId, label: '(missing) ' + st.presetId });
        var ps = S.select('Preset', presets, st.presetId, function (v) { full(function () { if (v === undefined) delete st.presetId; else st.presetId = v; }); }, { none: 'Choose...', disabled: !light, hint: light && !asList(light.presets).length ? 'This lighting control has no presets yet.' : undefined });
        if (missingPreset) ps.classList.add('vp-missing-field'); else if (!isSet(st.presetId)) ps.classList.add('vp-unset-field');
        f.appendChild(ps);
        break;
      case 'shade':
        f.appendChild(refPick('Shade', 'shades', st.shadeId, function (v) { full(function () { if (v === undefined) delete st.shadeId; else st.shadeId = v; }); }));
        f.appendChild(group('Do', seg([['open', 'Open'], ['close', 'Close']], st.action, function (v) { full(function () { st.action = v; }); }, k + ':sh')));
        break;
      case 'wait':
        f.appendChild(numField('Seconds (1 to ' + maxWait() + ')', st.seconds, function (n) { softly(function () { if (n === undefined) delete st.seconds; else st.seconds = n; }); }, { min: 1, max: maxWait(), hint: 'The program pauses here, then goes on. A newer program that changes the same devices stops it.' }));
        break;
      case 'run_scene':
        f.appendChild(refPick('Scene', 'scenes', st.sceneId, function (v) { full(function () { if (v === undefined) delete st.sceneId; else st.sceneId = v; }); }, { filter: function (s) { return !(ctx.kind === 'scene' && s.id === ctx.item.id); }, filterNote: '(a scene cannot run itself)', hint: 'Its own IF still applies: when it is not met the scene is skipped.' }));
        break;
      case 'set_variable':
        var def = S.find('variables', st.variableId);
        f.appendChild(refPick('Variable', 'variables', st.variableId, function (v) { full(function () { if (v === undefined) delete st.variableId; else st.variableId = v; var d = S.find('variables', v); if (d) st.value = coerce(d.type, st.value); }); }, { hint: !S.list('variables').length ? 'Add a variable under Visual Programming first.' : undefined }));
        f.appendChild(valueField('Set it to', def ? def.type : (typeof st.value === 'number' ? 'number' : (typeof st.value === 'string' ? 'string' : 'bool')), st.value, function (v) { full(function () { st.value = v; }); }, function (v) { softly(function () { st.value = v; }); }));
        break;
      case 'set_venue_status':
        f.appendChild(group('Mark the venue', seg([['open', 'Open'], ['closed', 'Closed']], st.status, function (v) { full(function () { st.status = v; }); }, k + ':vs'), 'Rules that start when the venue opens or closes run after this.'));
        break;
      case 'notify':
        f.appendChild(h('div.vp-wide', textField('Message (up to 200 characters)', st.message, function (v) { softly(function () { st.message = v; }); }, { max: 200, placeholder: 'What should managers be told?' })));
        f.appendChild(S.select('Level', [{ value: 'info', label: 'Information' }, { value: 'warning', label: 'Warning' }], st.level || 'info', function (v) { full(function () { st.level = v || 'info'; }); }));
        break;
      case 'if':
        f.appendChild(h('div.vp-wide', h('span.vp-group-label', 'IF this is true'),
          condEditor({ get: function () { return st.condition; }, set: function (v) { st.condition = v === undefined ? defaultCond('venue_status') : v; }, fixed: true })));
        break;
    }
    return f;
  }

  /* ── step cards and lists ────────────────────────────────────────────── */
  /* lc = { key, depth (how many IFs enclose this list), path, read() -> steps, get() -> the live array (inside an update) } */
  function moveStep(lc, st, delta) {
    commit(delta < 0 ? 'Move step up' : 'Move step down', function () {
      var list = lc.get(), i = list.indexOf(st), j = i + delta;
      if (i < 0 || j < 0 || j >= list.length) return;
      list.splice(i, 1); list.splice(j, 0, st);
    });
  }
  function clearDropMarks() { var r = root(); if (!r) return; Array.prototype.forEach.call(r.querySelectorAll('.vp-drop-before, .vp-drop-after'), function (el) { el.classList.remove('vp-drop-before', 'vp-drop-after'); }); }
  function stepCard(ctx, st, i, count, lc) {
    var known = st && typeof st === 'object' && STEP[st.type];
    var def = known ? STEP[st.type] : { label: 'Unknown step', icon: 'alert' };
    var id = known ? uid(st) : lc.key + ':' + i;
    var path = lc.path + '[' + (i + 1) + ']';
    var open = known && openSteps.has(st);
    var nested = known && st.type === 'if' ? countSteps(asList(st.then)) + countSteps(asList(st['else'])) : 0;

    function remove() {
      function go() { commit('Remove step', function () { var list = lc.get(), j = list.indexOf(st); if (j >= 0) list.splice(j, 1); }, { focus: false }); }
      if (!nested) { go(); return; }
      ask('Remove IF / ELSE', 'This also removes the ' + plural(nested, 'step') + ' inside it.', 'Remove', 'danger').then(function (ok) { if (ok) go(); });
    }
    function duplicate() {
      var add = 1 + nested;
      if (countSteps(ctx.item.program.steps) + add > MAX_STEPS) { VF.toast('A program can have up to ' + MAX_STEPS + ' steps. This copy would not fit.', 'warn'); return; }
      commit('Duplicate step', function () { var list = lc.get(), j = list.indexOf(st); var copy = VF.clone(st); list.splice(j + 1, 0, copy); if (open) openSteps.add(copy); });
    }

    var card = h('div.vp-step' + (open ? '.open' : '') + (known && st.type === 'if' ? '.is-if' : ''));
    var sum = live(h('span.vp-sum'), function (el) { VF.mount(el, known ? partsNodes(describeStep(st)) : h('span.vp-missing', 'Unknown step type. It cannot run; remove it.')); });
    var flags = live(h('span.vp-flags'), function (el) {
      var state = stepState(st), list = known ? stepIssues(ctx, path) : [];
      card.classList.toggle('unset', state === 'unset'); card.classList.toggle('bad', state === 'bad' || list.some(function (x) { return x.severity === 'error'; }));
      var errors = list.filter(function (x) { return x.severity === 'error'; }).length;
      var tip = list.map(function (x) { return x.message; }).join('\n') || null;
      VF.mount(el,
        state === 'bad' || errors ? h('span.chip.bad', { title: tip }, 'Needs fixing')
          : (state === 'unset' ? h('span.chip.warn', { title: tip }, 'Not set up yet')
            : (list.length ? h('span.chip.warn', { title: tip }, icon('alert', 'sm'), String(list.length)) : null)));
    });
    var grip = h('span.vp-grip', { draggable: 'true', title: 'Drag to reorder (or use the arrows)', 'aria-hidden': 'true' }, icon('grip'));
    grip.addEventListener('dragstart', function (e) {
      drag = { key: lc.key, st: st, lc: lc };
      try { e.dataTransfer.effectAllowed = 'move'; e.dataTransfer.setData('text/plain', 'step'); if (e.dataTransfer.setDragImage) e.dataTransfer.setDragImage(card, 20, 20); } catch (err) { /* ignore */ }
      card.classList.add('vp-dragging');
    });
    grip.addEventListener('dragend', function () { drag = null; card.classList.remove('vp-dragging'); clearDropMarks(); });
    card.addEventListener('dragover', function (e) {
      if (!drag || drag.key !== lc.key) return;
      e.stopPropagation();
      if (drag.st === st) return;
      e.preventDefault();
      var r = card.getBoundingClientRect(), before = e.clientY < r.top + Math.min(r.height / 2, 40);
      clearDropMarks(); card.classList.add(before ? 'vp-drop-before' : 'vp-drop-after');
    });
    card.addEventListener('drop', function (e) {
      if (!drag || drag.key !== lc.key) return;
      e.stopPropagation(); e.preventDefault();
      var moved = drag.st, before = card.classList.contains('vp-drop-before');
      drag = null; clearDropMarks();
      if (moved === st) return;
      commit('Reorder steps', function () {
        var list = lc.get(), from = list.indexOf(moved); if (from < 0) return;
        list.splice(from, 1);
        var to = list.indexOf(st); if (to < 0) { list.splice(from, 0, moved); return; }
        list.splice(before ? to : to + 1, 0, moved);
      }, { focus: false });
    });

    card.appendChild(h('div.vp-step-head',
      grip,
      h('button.vp-step-toggle', { type: 'button', 'aria-expanded': open ? 'true' : 'false', disabled: !known, title: open ? 'Close' : 'Open to edit', dataset: { vpk: id + ':t' }, onclick: function () { if (open) openSteps.delete(st); else openSteps.add(st); redraw(); } },
        h('span.vp-num', String(i + 1)), icon(def.icon), h('span.vp-sumwrap', h('span.vp-kind', def.label), sum), icon(open ? 'chevron-up' : 'chevron-down', 'sm')),
      flags,
      h('div.vp-acts',
        iconBtn('arrow-up', 'Move up', function () { moveStep(lc, st, -1); }, id + ':up', { disabled: i === 0 }),
        iconBtn('arrow-down', 'Move down', function () { moveStep(lc, st, 1); }, id + ':down', { disabled: i === count - 1 }),
        known ? iconBtn('copy', 'Duplicate', duplicate, id + ':dup') : null,
        iconBtn('trash', 'Remove', remove, id + ':rm', { danger: true }))));
    if (open) {
      card.appendChild(h('div.vp-step-body',
        live(h('div'), function (el) { VF.mount(el, issueRows(stepIssues(ctx, path))); }),
        stepFields(ctx, st)));
    }
    if (known && st.type === 'if') {
      ['then', 'else'].forEach(function (branch) {
        var sub = { key: id + ':' + branch, depth: lc.depth + 1, path: path + '.' + branch,
          read: function () { return asList(st[branch]); },
          get: function () { st[branch] = asList(st[branch]); return st[branch]; } };
        card.appendChild(h('div.vp-branch.' + branch,
          h('div.vp-branch-head', h('span.vp-tag.' + branch, branch === 'then' ? 'THEN' : 'ELSE'), h('span.small.muted', branch === 'then' ? 'when the condition is met' : 'when it is not met')),
          stepList(ctx, sub)));
      });
    }
    return card;
  }
  function openPalette(ctx, lc) {
    if (countSteps(ctx.item.program.steps) >= MAX_STEPS) { VF.toast('A program can have up to ' + MAX_STEPS + ' steps. Remove one before adding another.', 'warn'); return; }
    var allowed = schemaList('stepTypes'), closer = null;
    var body = h('div.vp-palette');
    PALETTE.forEach(function (g) {
      var tiles = g[1].filter(function (t) { return !allowed || allowed.indexOf(t) >= 0; }).map(function (type) {
        var def = STEP[type], blocked = type === 'if' && lc.depth >= MAX_NEST;
        return h('button.vp-tile', { type: 'button', disabled: blocked, onclick: function () { if (closer) closer(type); } }, icon(def.icon),
          h('span.col.tight', h('b', def.label), h('span.hint', blocked ? 'Not here: IF blocks nest ' + MAX_NEST + ' deep and this list is already ' + MAX_NEST + ' deep.' : def.hint)));
      });
      if (tiles.length) body.appendChild(h('div.vp-palette-group', h('h4', g[0]), h('div.vp-tiles', tiles)));
    });
    if (lc.depth >= MAX_NEST) body.appendChild(h('div.banner.warn', icon('alert', 'sm'), h('div.small', 'An IF / ELSE cannot be added here. The driver refuses IF blocks nested more than ' + MAX_NEST + ' deep, because a program that deep is too hard to follow and to test.')));
    VF.modal({ title: 'Add a step', icon: 'plus', wide: true, body: body, actions: [{ label: 'Cancel', kind: 'ghost', value: null }], onOpen: function (close) { closer = close; } }).then(function (type) {
      if (!type || !STEP[type]) return;
      commit('Add step', function () { var st = STEP[type].make(); lc.get().push(st); openSteps.add(st); }, { focus: false });
    });
  }
  function stepList(ctx, lc) {
    var steps = lc.read();
    var box = h('div.vp-steps');
    steps.forEach(function (st, i) { box.appendChild(stepCard(ctx, st, i, steps.length, lc)); });
    if (!steps.length) box.appendChild(h('div.vp-nosteps', lc.depth ? 'Nothing happens in this case. Add a step, or leave it empty.' : 'No steps yet. Add the first one.'));
    box.appendChild(h('div.row.wrap', btn('.outline', 'plus', lc.depth ? 'Add step here' : 'Add step', function () { openPalette(ctx, lc); }, lc.key + ':add')));
    return box;
  }

  /* ── WHEN (trigger) ──────────────────────────────────────────────────── */
  function defaultTrigger(type, rule) {
    switch (type) {
      case 'schedule': return { type: type, days: [1, 2, 3, 4, 5], time: '09:00' };
      case 'scene_activated': return { type: type };
      case 'c4_event': case 'external': return { type: type, name: String(rule.name || '').replace(/[^A-Za-z0-9 _-]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 40) || 'Event 1' };
      case 'device_state': return { type: type, entity: 'display', field: 'power' };
      case 'c4_variable': return { type: type, variable: '' };
      case 'venue_status': return { type: type, status: 'open' };
    }
    return { type: 'manual' };
  }
  function triggerFields(rule) {
    var t = rule.trigger, out = [], k = uid(rule) + ':tr';
    function full(fn) { commit('Change trigger', fn); }
    function softly(fn) { soft('Change trigger', fn); }
    function composerNote(kind) {
      return h('div.banner.info.vp-wide', icon('info', 'sm'), h('div.small',
        h('div', 'In Composer programming, add the VenueFlow command ', h('b', '"Trigger VenueFlow Event"'), ' with this name: ', live(h('span.kbd'), function (el) { el.textContent = isSet(rule.trigger.name) ? rule.trigger.name : '(type a name)'; }), '.'),
        h('div.muted', kind === 'external' ? 'Use this for events another system relays into Control4. The name is matched without regard to capitals.' : 'Put it under any Control4 event (a button press, a sensor, a time). The name is matched without regard to capitals.')));
    }
    switch (t.type) {
      case 'manual':
        out.push(h('div.banner.vp-wide', icon('info', 'sm'), h('div.small', 'Nothing starts this rule on its own. It runs only from Execute test below.')));
        break;
      case 'scene_activated':
        out.push(refPick('Scene', 'scenes', t.sceneId, function (v) { full(function () { if (v === undefined) delete t.sceneId; else t.sceneId = v; }); }, { hint: 'Runs after that scene, however it was started.' }));
        break;
      case 'schedule':
        out.push(timeField('Time', t.time, function (v) { softly(function () { if (v === undefined) delete t.time; else t.time = v; }); }, 'The controller\'s local time.'));
        out.push(group('Days', dayPicker(t.days, function (d) { full(function () { t.days = d; }); }, k), null, '.vp-span'));
        break;
      case 'c4_event': case 'external':
        out.push(textField('Event name', t.name, function (v) { softly(function () { t.name = v; }); }, { max: 40, hint: 'Letters, digits, spaces, dashes or underscores, up to 40.' }));
        out.push(composerNote(t.type));
        break;
      case 'device_state':
        out.push(S.select('Watch', [{ value: 'display', label: 'A display' }, { value: 'zone', label: 'An audio zone' }], t.entity, function (v) { full(function () { t.entity = v || 'display'; delete t.id; t.field = 'power'; delete t.equals; }); }));
        out.push(refPick(t.entity === 'zone' ? 'Audio zone' : 'Display', t.entity === 'zone' ? 'audioZones' : 'displays', t.id, function (v) { full(function () { if (v === undefined) delete t.id; else t.id = v; }); }));
        out.push(S.select('State', t.entity === 'zone' ? [{ value: 'power', label: 'Power' }, { value: 'source', label: 'Source' }, { value: 'muted', label: 'Mute' }] : [{ value: 'power', label: 'Power' }, { value: 'source', label: 'Source' }], t.field, function (v) { full(function () { t.field = v || 'power'; delete t.equals; }); }));
        out.push(stateValueControl(t, true));
        break;
      case 'c4_variable':
        out.push(numField('Control4 device id', t.deviceId, function (n) { softly(function () { if (n === undefined) delete t.deviceId; else t.deviceId = n; }); }, { min: 1, hint: 'The device that owns the variable (Composer shows the id).' }));
        out.push(textField('Variable name', t.variable, function (v) { softly(function () { t.variable = v; }); }, { placeholder: 'For example LIGHT_LEVEL' }));
        break;
      case 'venue_status':
        out.push(group('When the venue', seg([['open', 'Opens'], ['closed', 'Closes']], t.status, function (v) { full(function () { t.status = v; }); }, k + ':vs')));
        break;
    }
    return out;
  }
  function whenBlock(ctx) {
    var item = ctx.item;
    if (ctx.kind === 'scene') {
      return block('when', 'WHEN', live(h('div.vp-line'), function (el) { VF.mount(el, h('b', item.name || 'This scene'), ' is pressed, scheduled or run by another program'); }),
        h('p.hint', 'A scene has no trigger of its own. Operators press it, a schedule or a rule runs it, or Composer programming activates it.'));
    }
    var rule = item, allowed = schemaList('triggerTypes');
    var types = TRIGGER_ORDER.filter(function (t) { return !allowed || allowed.indexOf(t) >= 0; }).map(function (t) { return { value: t, label: TRIGGER_LABEL[t] }; });
    if (!TRIGGER_LABEL[rule.trigger.type]) types.unshift({ value: rule.trigger.type || '', label: '(unknown trigger)' });
    return block('when', 'WHEN',
      live(h('div.vp-line'), function (el) { VF.mount(el, partsNodes(describeTrigger(rule.trigger))); }),
      h('div.vp-fields',
        S.select('Start this rule when', types, rule.trigger.type, function (v) { if (!v || v === rule.trigger.type) return; commit('Change trigger', function () { rule.trigger = defaultTrigger(v, rule); }); }),
        triggerFields(rule)),
      live(h('div'), function (el) { VF.mount(el, issueRows(S.issuesFor('rule', rule.id).filter(function (i) { return /^trigger/.test(relPath(i.path)); }))); }));
  }
  function block(cls, tag) {
    var body = h('div.vp-block-body');
    for (var i = 2; i < arguments.length; i++) VF.append(body, arguments[i]);
    return h('section.vp-block.' + cls, h('div.vp-block-tag', h('span.vp-tag.' + cls, tag)), body);
  }
  function ifBlock(ctx) {
    var item = ctx.item;
    if (!item.condition || typeof item.condition !== 'object') {
      return block('if', 'IF',
        h('div.vp-line.muted', 'No condition: this ' + ctx.noun + ' always runs.'),
        h('div.row.wrap', btn('.outline', 'plus', 'Add an IF', function () { commit('Add condition', function () { item.condition = defaultCond('venue_status'); }); }, uid(item) + ':addif')));
    }
    return block('if', 'IF',
      h('div.row.between.top',
        live(h('div.vp-line.grow'), function (el) { VF.mount(el, partsNodes(describeCondition(item.condition))); }),
        btn('.ghost', 'trash', 'Remove the IF', function () { commit('Remove condition', function () { delete item.condition; }, { focus: false }); }, uid(item) + ':rmif')),
      condEditor({ get: function () { return item.condition; }, set: function (v) { if (v === undefined) delete item.condition; else item.condition = v; } }),
      h('p.hint', ctx.kind === 'scene' ? 'When this is not true the scene does nothing and the operator is told why. A fact that cannot be read counts as not true.' : 'When this is not true the rule does nothing. A fact that cannot be read counts as not true.'),
      live(h('div'), function (el) { VF.mount(el, issueRows(S.issuesFor(ctx.kind, item.id).filter(function (i) { return /^condition/.test(relPath(i.path)); }))); }));
  }
  function doBlock(ctx) {
    var item = ctx.item;
    var lc = { key: uid(item) + ':root', depth: 0, path: 'program.steps',
      read: function () { return asList(asMap(item.program).steps); },
      get: function () { item.program = asMap(item.program); item.program.steps = asList(item.program.steps); return item.program.steps; } };
    return block('do', 'DO',
      live(h('div.vp-line.muted.small'), function (el) { var n = countSteps(lc.read()); el.textContent = n ? plural(n, 'step') + ', run in order (limit ' + MAX_STEPS + ')' : 'Nothing to do yet'; }),
      stepList(ctx, lc));
  }

  /* ── testing panel ───────────────────────────────────────────────────── */
  function testState(key) { return tests[key] || (tests[key] = { tab: 'check', open: {}, skipIf: false, busy: null, validate: null, dry: null, run: null }); }
  function runChip(status) {
    if (status === 'settling') return h('span.chip.teal', h('span.dot.pulse'), 'Waiting for devices');
    if (status === 'running') return h('span.chip.teal', h('span.dot.pulse'), 'Running');
    return VF.outcomeChip(status);
  }
  function stepPathLabel(path) {
    if (path === 'condition') return 'IF';
    return String(path || '').split('.').map(function (p) { return p === 'then' ? 'THEN' : (p === 'else' ? 'ELSE' : p); }).join(' ');
  }
  /* An execution (a dry-run plan, a live run or a log entry) as a list of steps with chips. */
  function execView(exec, openMap, prefix, onToggle) {
    var steps = asList(exec.steps);
    var box = h('div.vp-exec');
    steps.forEach(function (s) {
      var results = asList(s.results);
      var k = prefix + exec.id + ':' + s.path;
      var bad = s.status === 'failed' || s.status === 'partial' || s.status === 'incomplete';
      var open = openMap[k] === undefined ? (bad && results.length > 0) : openMap[k];
      var row = h('div.vp-xstep' + (bad ? '.bad' : ''),
        h('span.vp-xpath', stepPathLabel(s.path)),
        h('div.grow',
          h('div', s.label || s.type),
          s.message ? h('div.small.muted', s.message) : null,
          bad && s.errorCode ? h('div.tiny.mono.muted', s.errorCode) : null,
          s.detail ? h('div.tiny.mono.muted', String(s.detail)) : null),
        runChip(s.status),
        results.length ? h('button.vp-ib', { type: 'button', title: open ? 'Hide the devices' : 'Show each device', 'aria-label': open ? 'Hide the devices' : 'Show each device', 'aria-expanded': open ? 'true' : 'false', dataset: { vpk: 'x:' + k }, onclick: function () { openMap[k] = !open; onToggle(); } }, icon(open ? 'chevron-up' : 'chevron-down')) : h('span.vp-ib-gap'));
      box.appendChild(row);
      if (open && results.length) {
        box.appendChild(h('div.vp-xresults', VF.outcomeList(results.map(function (r) {
          var extra = [r.errorCode, r.detail].filter(isSet).join(' · ');
          return Object.assign({}, r, { detail: extra || undefined });
        }))));
      }
    });
    if (!steps.length) box.appendChild(h('div.vp-nosteps', 'No step ran.'));
    return box;
  }
  function execHead(exec) {
    var bits = [];
    if (exec.origin) bits.push(exec.origin);
    if (exec.startedAt) bits.push('started ' + VF.fmtDateTime(exec.startedAt));
    if (exec.finishedAt && exec.startedAt) bits.push(Math.max(0, exec.finishedAt - exec.startedAt) + ' s');
    if (exec.cancelledBy || exec.cancelReason) bits.push('stopped' + (exec.cancelledBy ? ' by ' + exec.cancelledBy : '') + (exec.cancelReason ? ' (' + exec.cancelReason + ')' : ''));
    return h('div.vp-exec-head', h('div.row.wrap.tight', h('b.grow.ellipsis', exec.name || 'Program'), exec.dryRun ? h('span.chip.info', 'Dry run') : null, exec.kind ? h('span.chip', KIND_LABEL[exec.kind] || exec.kind) : null,
      exec.dryRun && exec.status === 'ok' ? h('span.chip.info', 'Nothing sent') : runChip(exec.status)),
      h('div.tiny.muted', bits.join(' · ')));
  }
  function payloadOf(ctx, t, withTrigger) {
    var item = ctx.item, p = { program: { steps: VF.clone(asList(asMap(item.program).steps)) } };
    if (item.condition && typeof item.condition === 'object' && !(t.skipIf && !withTrigger)) p.condition = VF.clone(item.condition);
    if (withTrigger && ctx.kind === 'rule' && item.trigger) p.trigger = VF.clone(item.trigger);
    if (!withTrigger) p.name = String(item.name || 'Test program').slice(0, 80);
    return p;
  }
  function replyProblem(r) {
    /* The driver plans and runs against the PUBLISHED configuration. */
    if (r.errorCode === 'VF_VALIDATION_FAILED' || r.errorCode === 'VF_NO_PUBLISHED_CONFIG') {
      return h('div.col.tight',
        h('div.banner.warn', icon('alert', 'sm'), h('div.small', h('b', 'Publish the draft first: '), 'this program uses something the published configuration does not have.', r.errorCode === 'VF_NO_PUBLISHED_CONFIG' ? ' Nothing has been published yet.' : '')),
        r.data && asList(r.data.issues).length ? issueRows(r.data.issues) : null,
        r.detail ? h('div.tiny.mono.muted', String(r.detail)) : null);
    }
    return h('div.banner.bad', icon('alert', 'sm'), h('div.small', h('div', r.message || 'That did not work.'), r.errorCode ? h('div.tiny.mono', r.errorCode) : null, r.detail ? h('div.tiny.mono', String(r.detail)) : null));
  }
  function conditionNote(exec, live_) {
    if (exec.conditionMet !== false) return null;
    return h('div.banner.warn', icon('info', 'sm'), h('div.small', 'The IF is not met right now, so ' + (live_ ? 'nothing was sent.' : 'nothing would run.') + ' Tick "Skip the IF" to test the steps anyway.'));
  }
  function paintTest(el, ctx, key) {
    var t = testState(key), item = ctx.item, noun = ctx.noun;
    var saved = S.issuesFor(ctx.kind, item.id);
    var simulation = !!(S.boot && S.boot.driver && S.boot.driver.simulation);
    function repaint() { refreshLive(); }
    function busy(name, promise) { t.busy = name; repaint(); return promise.then(function (r) { t.busy = null; return r; }); }

    function validate() {
      busy('validate', S.flush().then(function () { return VF.api('PROGRAM_VALIDATE', payloadOf(ctx, t, true), { since: false }); })).then(function (r) {
        t.validate = { at: Date.now(), reply: r, issues: asList(r.data && r.data.issues), summary: r.data && r.data.summary };
        repaint();
      });
    }
    function dryRun() {
      busy('dry', S.flush().then(function () { return VF.api('PROGRAM_DRY_RUN', payloadOf(ctx, t, false), { since: false }); })).then(function (r) {
        t.dry = { at: Date.now(), reply: r, execution: r.ok && r.data ? r.data.execution : null };
        repaint();
      });
    }
    function execute() {
      VF.modal({ title: 'Execute test', icon: 'alert', body: h('div.col',
        h('p', 'This sends live commands to the venue now. Displays, audio, lighting and shades named in "' + (item.name || noun) + '" will change.'),
        simulation ? h('div.banner.info', icon('info', 'sm'), h('div.small', 'This driver is in Simulation mode: the commands go to the simulator, not to Control4.')) : h('div.banner.warn', icon('alert', 'sm'), h('div.small', 'This driver is live. Guests and staff will see and hear the change.')),
        h('p.small.muted', 'It runs against the published configuration, and a running program that changes the same devices is stopped.')),
        actions: [{ label: 'Cancel', kind: 'ghost', value: null }, { label: 'Send live commands', kind: 'warn', value: true }] }).then(function (ok) {
        if (ok !== true) return;
        busy('run', S.flush().then(function () { return VF.api('PROGRAM_EXECUTE', Object.assign(payloadOf(ctx, t, false), { confirm: true, refKind: ctx.kind, refId: item.id }), { since: false }); })).then(function (r) {
          var exec = r.data && r.data.execution ? r.data.execution : null;
          t.run = { at: Date.now(), reply: r, execution: exec };
          repaint();
          if (exec && ACTIVE[exec.status]) startPoll(key); else loadRuns();
        });
      });
    }
    function stop() {
      var exec = t.run && t.run.execution; if (!exec) return;
      VF.api('EXECUTION_CANCEL', { executionId: exec.id }, { since: false }).then(function (r) { VF.toastReply(r, 'Stop sent'); loadRuns(); });
    }

    var lastRun = runs.data ? asMap(runs.data.lastRun)[ctx.kind + ':' + item.id] : null;
    var lastOk = runs.data ? asMap(runs.data.lastSuccess)[ctx.kind + ':' + item.id] : null;
    var tabs = [['check', 'Check', saved.length || null], ['dry', 'Dry run', null], ['run', 'Execute', null], ['log', 'Log', null]];
    var body = h('div.col');

    if (t.tab === 'check') {
      body.appendChild(h('h4', 'From the last save'));
      body.appendChild(saved.length ? issueRows(saved) : h('div.small.muted', 'No errors or warnings for this ' + noun + '.'));
      body.appendChild(h('div.row.wrap', btn('', 'check-circle', t.busy === 'validate' ? 'Checking...' : 'Validate', validate, 't:validate', !!t.busy),
        h('span.hint.grow', 'Saves the draft, then checks WHEN, IF and DO against it.')));
      if (t.validate) {
        var v = t.validate, errs = v.issues.filter(function (i) { return i.severity === 'error'; }).length;
        if (!v.reply.ok && !v.issues.length) body.appendChild(replyProblem(v.reply));
        else if (!v.issues.length) body.appendChild(h('div.banner.ok', icon('check-circle', 'sm'), h('div.small', 'Valid against the draft: no errors, no warnings.')));
        else {
          body.appendChild(h('div.small', h('b', plural(errs, 'error') + ', ' + plural(v.issues.length - errs, 'warning')), h('span.muted', ' · checked ' + VF.fmtTime(v.at / 1000))));
          body.appendChild(issueRows(v.issues));
        }
      }
    } else if (t.tab === 'dry' || t.tab === 'run') {
      var isRun = t.tab === 'run', res = isRun ? t.run : t.dry;
      body.appendChild(isRun
        ? h('div.banner.warn', icon('alert', 'sm'), h('div.small', h('b', 'Execute test sends live commands to the venue now.'), ' It runs against the published configuration.' + (simulation ? ' (Simulation mode: the simulator answers.)' : '')))
        : h('div.banner.info', icon('info', 'sm'), h('div.small', h('b', 'A dry run sends nothing to Control4.'), ' It plans every step against the PUBLISHED configuration and shows what would be done.')));
      if (item.condition) body.appendChild(S.check('Skip the IF for this test', t.skipIf, function (on) { t.skipIf = on; repaint(); }));
      var exec = res && res.execution;
      var running = isRun && exec && ACTIVE[exec.status];
      body.appendChild(h('div.row.wrap',
        isRun ? btn('.warn', 'zap', t.busy === 'run' ? 'Sending...' : 'Execute test', execute, 't:run', !!t.busy || !!running)
          : btn('.primary', 'play', t.busy === 'dry' ? 'Planning...' : 'Dry run', dryRun, 't:dry', !!t.busy),
        running ? btn('.danger', 'stop', 'Stop', stop, 't:stop') : null));
      if (res) {
        if (!exec) body.appendChild(replyProblem(res.reply));
        else {
          if (!res.reply.ok && res.reply.errorCode) body.appendChild(replyProblem(res.reply));
          body.appendChild(execHead(exec));
          VF.append(body, conditionNote(exec, isRun));
          body.appendChild(execView(exec, t.open, isRun ? 'r:' : 'd:', repaint));
          if (isRun) {
            body.appendChild(h('p.hint', running ? 'Sent is not done: each step turns to Done, Partly done or Failed when the devices confirm.' : 'Final: each step shows what the devices confirmed.'));
            if (running && !pollTimer) startPoll(key);
          } else body.appendChild(h('p.hint', '"Would run" means the step is valid for the published venue. Nothing was sent.'));
        }
      }
    } else {
      body.appendChild(h('div.row.between.wrap', h('h4', 'Recent runs on this controller'), btn('.ghost', 'refresh', runs.loading ? 'Reading...' : 'Refresh', function () { loadRuns(); }, 't:refresh', runs.loading)));
      var list = asList(runs.data && runs.data.executions);
      if (runs.error) body.appendChild(h('div.banner.bad', icon('alert', 'sm'), h('div.small', runs.error)));
      if (!runs.data && !runs.error) body.appendChild(h('div.small.muted', 'Reading the run history...'));
      else if (!list.length) body.appendChild(h('div.small.muted', 'Nothing has run since the driver started.'));
      list.slice(0, 20).forEach(function (x) {
        var k = 'log:' + x.id, open = !!t.open[k];
        body.appendChild(h('div.vp-logrow',
          h('button.vp-logtoggle', { type: 'button', 'aria-expanded': open ? 'true' : 'false', dataset: { vpk: 'l:' + x.id }, onclick: function () { t.open[k] = !open; repaint(); } }, execHead(x), icon(open ? 'chevron-up' : 'chevron-down', 'sm')),
          open ? execView(x, t.open, 'l:', repaint) : null));
      });
    }

    VF.mount(el,
      h('div.panel-head', icon('activity'), h('h3.grow', 'Test this ' + noun)),
      h('div.panel-body.col',
        h('div.vp-last',
          h('div', h('span.muted', 'Last run: '), lastRun ? h('span', VF.ago(lastRun.at) + ' ', runChip(lastRun.status)) : (runs.data ? 'never' : '...')),
          h('div', h('span.muted', 'Last successful run: '), lastOk ? VF.ago(lastOk) + ' (' + VF.fmtDateTime(lastOk) + ')' : (runs.data ? 'never' : '...')),
          h('div.hint', 'Counts runs from screens, schedules, rules and Composer. Tests made here are listed under Log.')),
        h('div.seg.vp-seg.vp-tabs', { role: 'tablist' }, tabs.map(function (tab) {
          return h('button' + (t.tab === tab[0] ? '.on' : ''), { type: 'button', role: 'tab', 'aria-selected': t.tab === tab[0] ? 'true' : 'false', dataset: { vpk: 'tab:' + tab[0] }, onclick: function () { t.tab = tab[0]; if (tab[0] === 'log') loadRuns(); repaint(); } }, tab[1], tab[2] ? h('span.chip.' + (saved.some(function (i) { return i.severity === 'error'; }) ? 'bad' : 'warn'), String(tab[2])) : null);
        })),
        body));
  }
  function testPanel(ctx) {
    var key = ctx.kind + ':' + ctx.item.id;
    return live(h('div.panel.vp-test'), function (el) { paintTest(el, ctx, key); });
  }

  /* ── the editor shell shared by scenes and rules ─────────────────────── */
  function testJump() {
    return btn('.outline', 'activity', 'Test', function () { var el = document.querySelector('#main .vp-test'); if (el && el.scrollIntoView) el.scrollIntoView({ block: 'start' }); }, 'e:test');
  }
  function editorLayout(ctx, head, meta) {
    return h('div.vp-editor', head,
      h('div.vp-cols',
        h('div.vp-main', meta, h('div.panel.vp-program', whenBlock(ctx), ifBlock(ctx), doBlock(ctx))),
        h('div.vp-side', testPanel(ctx))));
  }

  /* ── Scenes ──────────────────────────────────────────────────────────── */
  function switchesOff(steps) { var off = false; S.eachStep(asList(steps), function (st) { if (st.type === 'display_power' && st.power === 'off') off = true; }); return off; }
  function newSceneFrom(template, blankName) {
    var limit = limitOf('scenes', 64);
    if (S.list('scenes').length >= limit) { VF.toast('This venue already has ' + limit + ' scenes, the most the driver keeps.', 'warn'); return; }
    var scene;
    if (template) {
      scene = VF.clone(template);
      scene.program = asMap(scene.program); scene.program.steps = asList(scene.program.steps);
      if (Array.isArray(scene.condition) || !scene.condition) delete scene.condition;
    } else scene = { name: blankName || 'New scene', icon: 'zap', description: '', confirm: false, program: { steps: [] } };
    var taken = {}; S.list('scenes').forEach(function (s) { taken[String(s.name).toLowerCase()] = true; });
    var base = scene.name || 'Scene', name = base, n = 2;
    while (taken[name.toLowerCase()]) name = base + ' ' + (n++);
    scene.name = name; scene.confirm = scene.confirm === true;
    scene.id = S.freshId('scenes', name);
    view.scenes = scene.id;
    S.update('Add scene', function (c) { c.scenes.push(scene); });
    toTop();
  }
  function addSceneDialog() {
    var templates = asList(S.boot && S.boot.schema && S.boot.schema.sceneTemplates), closer = null;
    var body = h('div.vp-palette',
      h('div.vp-palette-group', h('h4', 'Start empty'), h('div.vp-tiles', h('button.vp-tile', { type: 'button', onclick: function () { closer({ blank: true }); } }, icon('plus'), h('span.col.tight', h('b', 'Blank scene'), h('span.hint', 'No steps. Build it from scratch.'))))),
      templates.length ? h('div.vp-palette-group', h('h4', 'From a template'), h('div.vp-tiles', templates.map(function (tpl) {
        return h('button.vp-tile', { type: 'button', onclick: function () { closer({ template: tpl }); } }, VF.sceneIcon(tpl.icon), h('span.col.tight', h('b', tpl.name), h('span.hint', tpl.description || '')));
      })), h('p.hint', 'A template is a starting point that uses "all displays". It never names a source: add your routes and levels.')) : null);
    VF.modal({ title: 'Add a scene', icon: 'plus', wide: true, body: body, actions: [{ label: 'Cancel', kind: 'ghost', value: null }], onOpen: function (close) { closer = close; } }).then(function (pick) {
      if (!pick) return;
      if (!pick.blank) { newSceneFrom(pick.template); return; }
      /* The name is asked first: the id is made from it once and never changes. */
      VF.prompt('Blank scene', 'Name (what the button says)', '', 'Add scene').then(function (name) { if (name) newSceneFrom(null, String(name).slice(0, 80)); });
    });
  }
  function duplicateItem(fieldName, item, viewKey) {
    var limit = limitOf(fieldName, fieldName === 'scenes' ? 64 : 96);
    if (S.list(fieldName).length >= limit) { VF.toast('The limit of ' + limit + ' is reached.', 'warn'); return; }
    var copy = VF.clone(item);
    copy.name = (String(item.name || '').slice(0, 74) + ' copy').trim();
    copy.id = S.freshId(fieldName, copy.name);
    if (fieldName === 'rules') copy.enabled = false;
    S.update('Duplicate', function (c) { var list = c[fieldName], i = list.indexOf(item); list.splice(i < 0 ? list.length : i + 1, 0, copy); });
    if (viewKey) { view[viewKey] = copy.id; redraw(); toTop(); }
    VF.toast(fieldName === 'rules' ? 'Copied. The copy is off until you switch it on.' : 'Copied as "' + copy.name + '".', 'ok');
  }
  function sceneList(container) {
    var scenes = S.list('scenes');
    var cards = h('div.cards.vp-cards');
    scenes.forEach(function (s) {
      var n = countSteps(asMap(s.program).steps);
      cards.appendChild(h('div.card.vp-card',
        h('button.vp-card-open', { type: 'button', dataset: { vpk: 'sc:' + s.id }, onclick: function () { view.scenes = s.id; redraw(); toTop(); } },
          h('span.vp-card-icon', VF.sceneIcon(s.icon, 'lg')),
          h('span.col.tight.grow', h('b.ellipsis', s.name), h('span.small.muted.vp-clamp', s.description || 'No description'))),
        h('div.row.wrap.tight',
          h('span.chip', plural(n, 'step')),
          s.condition ? h('span.chip.info', { title: 'IF ' + partsText(describeCondition(s.condition)) }, 'IF') : null,
          s.confirm ? h('span.chip.teal', 'Asks to confirm') : null,
          live(h('span.vp-inline'), function (el) { VF.mount(el, S.issueChip('scene', s.id)); })),
        h('div.row.end.tight',
          iconBtn('copy', 'Duplicate ' + s.name, function () { duplicateItem('scenes', s, null); }, 'sc:' + s.id + ':dup'),
          iconBtn('trash', 'Delete ' + s.name, function () { S.confirmRemove('scene', s.id, 'scene'); }, 'sc:' + s.id + ':rm', { danger: true }))));
    });
    VF.mount(container,
      S.sectionHead('Scenes', 'What a button does. Operators press a scene; schedules, rules and Composer programming can run one too.', [btn('.primary', 'plus', 'Add scene', addSceneDialog, 'sc:add')]),
      scenes.length ? cards : h('div.empty', h('p', 'No scenes yet.'), h('div', { style: { marginTop: '12px' } }, btn('.primary', 'plus', 'Add the first scene', addSceneDialog))));
  }
  function sceneEditor(container, scene) {
    var ctx = { kind: 'scene', item: scene, noun: 'scene' };
    var head = h('div.vp-ehead',
      btn('.ghost', 'arrow-left', 'All scenes', function () { view.scenes = null; redraw(); toTop(); }, 'e:back'),
      live(h('h1.grow.ellipsis'), function (el) { VF.mount(el, h('span.vp-title-icon', VF.sceneIcon(scene.icon, 'lg')), scene.name || 'Scene'); }),
      live(h('span.vp-inline'), function (el) { VF.mount(el, S.issueChip('scene', scene.id)); }),
      testJump(),
      btn('', 'copy', 'Duplicate', function () { duplicateItem('scenes', scene, 'scenes'); }, 'e:dup'),
      btn('.danger', 'trash', 'Delete', function () { S.confirmRemove('scene', scene.id, 'scene').then(function (ok) { if (ok) { view.scenes = null; toTop(); } }); }, 'e:rm'));
    var icons = h('div.vp-icons', { role: 'group', 'aria-label': 'Icon' }, Object.keys(VF.SCENE_ICON).map(function (key) {
      return h('button' + (scene.icon === key ? '.on' : ''), { type: 'button', title: key, 'aria-label': key, 'aria-pressed': scene.icon === key ? 'true' : 'false', dataset: { vpk: 'ic:' + key }, onclick: function () { commit('Change icon', function () { scene.icon = key; }); } }, VF.sceneIcon(key));
    }));
    var meta = h('div.panel.pad.col',
      h('div.form',
        textField('Name', scene.name, function (v) { if (!v) { VF.toast('A scene needs a name.', 'warn'); redraw(); return; } soft('Rename scene', function () { scene.name = v; }); }),
        textField('Description', scene.description, function (v) { soft('Change description', function () { scene.description = v; }); }, { max: 200, hint: 'Shown to operators under the button.' })),
      group('Icon', icons),
      S.toggle('Ask operators to confirm before it runs', scene.confirm === true, function (on) { commit('Change confirm', function () { scene.confirm = on; }); }, 'They are shown a preview first. Recommended for scenes that switch displays off.'),
      live(h('div'), function (el) { VF.mount(el, switchesOff(asMap(scene.program).steps) && !scene.confirm ? h('div.banner.warn', icon('alert', 'sm'), h('div.small', 'This scene switches displays off. Asking operators to confirm is recommended, so a slip of the finger does not black out the room.')) : null); }));
    VF.mount(container, editorLayout(ctx, head, meta));
  }
  function renderScenes(container, params) {
    enter('scenes', params);
    if (!S.hasDraft()) { S.emptyDraft(container); return; }
    var scene = view.scenes ? S.find('scenes', view.scenes) : null;
    if (scene) sceneEditor(container, scene); else { view.scenes = null; sceneList(container); }
  }

  /* ── Visual Programming (rules and variables) ────────────────────────── */
  function addRule() {
    var limit = limitOf('rules', 96);
    if (S.list('rules').length >= limit) { VF.toast('This venue already has ' + limit + ' rules, the most the driver keeps.', 'warn'); return; }
    /* The name is asked first: the id is made from it once and never changes. */
    VF.prompt('Add a rule', 'Name (for example "Lights down when the game starts")', '', 'Add rule').then(function (name) {
      if (!name) return;
      name = String(name).slice(0, 80);
      var rule = { id: S.freshId('rules', name), name: name, enabled: true, trigger: { type: 'manual' }, program: { steps: [] } };
      view.programming = rule.id;
      S.update('Add rule', function (c) { c.rules.push(rule); });
      toTop();
    });
  }
  function ruleRow(r, opts) {
    opts = opts || {};
    var n = countSteps(asMap(r.program).steps);
    return h('div.item.vp-rule' + (r.enabled === false ? '.off' : ''),
      h('button.toggle' + (r.enabled !== false ? '.on' : ''), { type: 'button', role: 'switch', 'aria-checked': r.enabled !== false ? 'true' : 'false', 'aria-label': 'Enabled: ' + r.name, title: r.enabled !== false ? 'On. Tap to switch this rule off.' : 'Off. Tap to switch this rule on.', dataset: { vpk: 'ru:' + r.id + ':en' }, onclick: function () { commit(r.enabled !== false ? 'Disable rule' : 'Enable rule', function () { r.enabled = r.enabled === false; }); } }),
      h('button.vp-rule-open.grow', { type: 'button', dataset: { vpk: 'ru:' + r.id }, onclick: opts.onOpen || function () { view.programming = r.id; redraw(); toTop(); } },
        h('b.ellipsis', r.name),
        h('span.small', h('span.vp-tag.when', 'WHEN'), ' ', partsNodes(describeTrigger(r.trigger))),
        opts.short ? null : h('span.small', h('span.vp-tag.if', 'IF'), ' ', r.condition ? partsNodes(describeCondition(r.condition)) : h('span.muted', 'always')),
        h('span.small.muted', h('span.vp-tag.do', 'DO'), ' ', n === 1 ? partsNodes(describeStep(asList(r.program.steps)[0])) : plural(n, 'step'))),
      live(h('span.vp-inline'), function (el) { VF.mount(el, r.enabled === false ? h('span.chip', 'Off') : null, S.issueChip('rule', r.id)); }),
      opts.actions || h('div.row.tight',
        iconBtn('copy', 'Duplicate ' + r.name, function () { duplicateItem('rules', r, null); }, 'ru:' + r.id + ':dup'),
        iconBtn('trash', 'Delete ' + r.name, function () { S.confirmRemove('rule', r.id, 'rule'); }, 'ru:' + r.id + ':rm', { danger: true })));
  }
  function variablesCard() {
    var vars = S.list('variables'), limit = limitOf('variables', 48);
    function add() {
      if (vars.length >= limit) { VF.toast('This venue already has ' + limit + ' variables, the most the driver keeps.', 'warn'); return; }
      VF.prompt('Add a variable', 'Name (for example "Big game on")', '', 'Add').then(function (name) {
        if (!name) return;
        S.update('Add variable', function (c) { c.variables.push({ id: S.freshId('variables', name), name: String(name).slice(0, 80), type: 'bool', initial: false }); });
      });
    }
    var rows = vars.map(function (v) {
      var types = (schemaList('variableTypes') || ['bool', 'number', 'string']).map(function (t) { return { value: t, label: t === 'bool' ? 'Yes / no' : (t === 'number' ? 'Number' : 'Text') }; });
      return h('div.vp-var',
        textField('Name', v.name, function (val_) { if (!val_) { VF.toast('A variable needs a name.', 'warn'); redraw(); return; } soft('Rename variable', function () { v.name = val_; }); }),
        S.select('Type', types, v.type, function (t) { commit('Change variable type', function () { v.type = t || 'bool'; v.initial = coerce(v.type, v.initial); }); }),
        valueField('Starts as', v.type, v.initial, function (x) { commit('Change variable', function () { v.initial = x; }); }, function (x) { soft('Change variable', function () { v.initial = x; }); }),
        h('div.lbl', 'Now', live(h('div.vp-var-now'), function (el) {
          var map = runs.data ? asMap(runs.data.variables) : null;
          var has = map && Object.prototype.hasOwnProperty.call(map, v.id);
          VF.mount(el, has ? h('span.chip.teal', String(map[v.id])) : h('span.small.muted', runs.data ? 'Not published yet' : '...'));
        })),
        h('div.vp-var-acts', live(h('span.vp-inline'), function (el) { VF.mount(el, S.issueChip('variable', v.id)); }),
          iconBtn('trash', 'Delete ' + v.name, function () { S.confirmRemove('variable', v.id, 'variable'); }, 'va:' + v.id + ':rm', { danger: true })));
    });
    return h('div.panel',
      h('div.panel-head', icon('sliders'), h('div.grow', h('h3', 'Variables'), h('p.small.muted', 'VenueFlow\'s own memory: a yes/no, a number or a text that steps set and conditions read. "Now" is the value in the running, published venue.')),
        btn('.outline', 'plus', 'Add variable', add, 'va:add')),
      h('div.panel-body.col', rows.length ? rows : h('div.vp-nosteps', 'No variables yet. Add one to remember something between programs, for example "Big game on".')));
  }
  function ruleList(container) {
    var rules = S.list('rules');
    VF.mount(container,
      S.sectionHead('Visual Programming', 'Rules run on their own: WHEN something happens, IF a condition holds, DO a list of steps.', [btn('.primary', 'plus', 'Add rule', addRule, 'ru:add')]),
      h('div.col',
        rules.length ? h('div.list', rules.map(function (r) { return ruleRow(r); })) : h('div.empty', h('p', 'No rules yet. A rule runs steps on a schedule, when a scene runs, when the venue opens, or on an event from Composer.'), h('div', { style: { marginTop: '12px' } }, btn('.primary', 'plus', 'Add the first rule', addRule))),
        variablesCard()));
  }
  function ruleEditor(container, rule) {
    var ctx = { kind: 'rule', item: rule, noun: 'rule' };
    var head = h('div.vp-ehead',
      btn('.ghost', 'arrow-left', 'All rules', function () { view.programming = null; redraw(); toTop(); }, 'e:back'),
      live(h('h1.grow.ellipsis'), function (el) { el.textContent = rule.name || 'Rule'; }),
      live(h('span.vp-inline'), function (el) { VF.mount(el, S.issueChip('rule', rule.id)); }),
      testJump(),
      btn('', 'copy', 'Duplicate', function () { duplicateItem('rules', rule, 'programming'); }, 'e:dup'),
      btn('.danger', 'trash', 'Delete', function () { S.confirmRemove('rule', rule.id, 'rule').then(function (ok) { if (ok) { view.programming = null; toTop(); } }); }, 'e:rm'));
    var meta = h('div.panel.pad.col',
      h('div.form',
        textField('Name', rule.name, function (v) { if (!v) { VF.toast('A rule needs a name.', 'warn'); redraw(); return; } soft('Rename rule', function () { rule.name = v; }); }),
        S.toggle('Enabled', rule.enabled !== false, function (on) { commit(on ? 'Enable rule' : 'Disable rule', function () { rule.enabled = on; }); }, 'When off, nothing starts this rule. Execute test still runs it.')));
    VF.mount(container, editorLayout(ctx, head, meta));
  }
  function renderProgramming(container, params) {
    enter('programming', params);
    if (!S.hasDraft()) { S.emptyDraft(container); return; }
    var rule = view.programming ? S.find('rules', view.programming) : null;
    if (rule) ruleEditor(container, rule); else { view.programming = null; ruleList(container); }
  }

  /* ── Scheduling ──────────────────────────────────────────────────────── */
  function scheduleRules() { return S.list('rules').filter(function (r) { return asMap(r.trigger).type === 'schedule'; }); }
  function openRule(id) { S.go('programming', { ruleId: id }); }
  function scheduleSceneDialog() {
    var scenes = S.list('scenes');
    if (!scenes.length) { VF.toast('Add a scene first: a schedule runs a scene.', 'warn'); return; }
    var limit = limitOf('rules', 96);
    if (S.list('rules').length >= limit) { VF.toast('This venue already has ' + limit + ' rules, the most the driver keeps.', 'warn'); return; }
    var form = { sceneId: scenes[0].id, days: [1, 2, 3, 4, 5], time: '09:00', name: '' };
    var body = h('div.col');
    function autoName() { var s = S.find('scenes', form.sceneId); return ((s ? s.name : 'Scene') + ' at ' + form.time).slice(0, 80); }
    function paint() {
      var nameInput = h('input.field', { type: 'text', value: form.name, maxlength: 80, placeholder: autoName() });
      var nameHint = h('span.hint');
      function hint() { nameInput.placeholder = autoName(); nameHint.textContent = 'Leave empty to call it "' + autoName() + '".'; }
      nameInput.addEventListener('change', function () { form.name = nameInput.value.trim(); });
      var timeInput = h('input.field', { type: 'time', value: form.time, placeholder: 'HH:MM' });
      timeInput.addEventListener('change', function () { form.time = String(timeInput.value || '').slice(0, 5); hint(); });
      hint();
      VF.mount(body,
        S.select('Scene to run', S.entityOptions('scenes'), form.sceneId, function (v) { form.sceneId = v; form.name = nameInput.value.trim(); paint(); }),
        h('div.vp-group', h('span.vp-group-label', 'Days'), dayPicker(form.days, function (d) { form.days = d; form.name = nameInput.value.trim(); paint(); })),
        field('Time (the controller\'s local time)', timeInput),
        h('label.lbl', 'Name of the schedule', nameInput, nameHint),
        h('p.hint', 'This adds a rule with a schedule trigger and one "Run scene" step. Open it under Visual Programming to add an IF or more steps. It starts running once the draft is published.'));
    }
    paint();
    VF.modal({ title: 'Schedule a scene', icon: 'calendar', body: body, actions: [{ label: 'Cancel', kind: 'ghost', value: null }, { label: 'Add schedule', kind: 'primary', value: function () {
      var active_ = document.activeElement; if (active_ && body.contains(active_) && active_.blur) active_.blur();
      if (!/^\d\d:\d\d$/.test(form.time)) { VF.toast('Choose a time as HH:MM.', 'warn'); return false; }
      if (!form.days.length) { VF.toast('Choose at least one day.', 'warn'); return false; }
      return 'add';
    } }] }).then(function (v) {
      if (v !== 'add') return;
      var name = form.name || autoName();
      S.update('Schedule a scene', function (c) {
        c.rules.push({ id: S.freshId('rules', name), name: name, enabled: true, trigger: { type: 'schedule', days: form.days.slice(), time: form.time }, program: { steps: [{ type: 'run_scene', sceneId: form.sceneId }] } });
      });
      VF.toast('Schedule added to the draft. It runs after you publish.', 'ok');
    });
  }
  function weekView(rules) {
    var grid = h('div.vp-week');
    DAY.forEach(function (name, i) {
      var d = i + 1;
      var list = rules.filter(function (r) { return asList(r.trigger.days).indexOf(d) >= 0; }).sort(function (a, b) { return String(a.trigger.time || '').localeCompare(String(b.trigger.time || '')) || String(a.name).localeCompare(String(b.name)); });
      grid.appendChild(h('div.vp-day',
        h('div.vp-day-name', h('span.vp-day-long', DAY_LONG[i]), h('span.vp-day-short', name)),
        list.length ? list.map(function (r) {
          return h('button.vp-slot' + (r.enabled === false ? '.off' : ''), { type: 'button', title: r.name + (r.enabled === false ? ' (off)' : ''), dataset: { vpk: 'wk:' + d + ':' + r.id }, onclick: function () { openRule(r.id); } },
            h('span.vp-slot-time', r.trigger.time || '--:--'), h('span.vp-slot-name', r.name), r.enabled === false ? h('span.tiny.muted', 'Off') : null);
        }) : h('div.vp-day-empty', 'Nothing')));
    });
    return grid;
  }
  function renderScheduling(container, params) {
    enter('scheduling', params);
    if (!S.hasDraft()) { S.emptyDraft(container); return; }
    var rules = scheduleRules();
    var ctl = asMap(S.boot && S.boot.controller);
    var clock = h('div.panel.pad.col',
      h('div.row.wrap',
        h('div.stat', icon('globe', 'lg'), h('div.col.tight', h('span.small.muted', 'Controller time zone'), h('b', ctl.timeZone || 'Not reported'))),
        h('div.stat', icon('clock', 'lg'), h('div.col.tight', h('span.small.muted', 'Controller local time (when this Studio loaded)'), h('b', ctl.localTime || 'Not reported')))),
      h('ul.vp-facts',
        h('li', 'Schedules follow the controller\'s clock and time zone (Composer, Project Settings), not this device\'s.'),
        h('li', 'When clocks go forward, a schedule inside the skipped hour runs once, right after the change.'),
        h('li', 'When clocks go back, a schedule in the repeated hour runs once.'),
        h('li', 'A schedule missed while the controller was off is not run late.')));
    var overlaps = live(h('div'), function (el) {
      var list = S.issues().filter(function (i) { return i.code === 'SCHEDULE_OVERLAP'; });
      VF.mount(el, list.length ? h('div.col.tight', list.map(function (i) {
        return h('div.banner.warn', icon('alert', 'sm'), h('div.small.grow', i.message), i.entity && i.entity.kind === 'rule' ? btn('.ghost', 'edit', 'Open', function () { openRule(i.entity.id); }) : null);
      })) : null);
    });
    var upcoming = live(h('div.col.tight'), function (el) {
      var list = asList(runs.data && runs.data.upcoming);
      if (!runs.data) { VF.mount(el, h('div.small.muted', runs.error || 'Reading the next runs...')); return; }
      if (!list.length) { VF.mount(el, h('div.small.muted', S.published ? 'No enabled schedule in the published configuration.' : 'Nothing is published yet, so nothing is scheduled.')); return; }
      VF.mount(el, list.map(function (u) {
        var known = S.find('rules', u.ruleId);
        return h('div.item.vp-next',
          h('span.vp-slot-time', u.time),
          h('div.grow', h('div.ellipsis', u.name), h('div.small.muted', (u.inDays === 0 ? 'Today' : (u.inDays === 1 ? 'Tomorrow' : 'In ' + u.inDays + ' days')) + ', ' + (DAY_LONG[u.weekday - 1] || ''))),
          known ? btn('.ghost', 'edit', 'Edit', function () { openRule(u.ruleId); }) : h('span.chip', { title: 'This schedule is in the published configuration but no longer in the draft.' }, 'Not in the draft'));
      }));
    });
    var list = rules.length ? h('div.list', rules.slice().sort(function (a, b) { return String(a.trigger.time || '').localeCompare(String(b.trigger.time || '')); }).map(function (r) {
      return ruleRow(r, { short: true, onOpen: function () { openRule(r.id); }, actions: h('div.row.tight',
        btn('.ghost', 'edit', 'Edit', function () { openRule(r.id); }, 'sd:' + r.id + ':ed'),
        iconBtn('trash', 'Delete ' + r.name, function () { S.confirmRemove('rule', r.id, 'rule'); }, 'sd:' + r.id + ':rm', { danger: true })) });
    })) : h('div.empty', h('p', 'No schedules yet. "Schedule a scene" runs a scene at a time of day on the days you choose.'));
    VF.mount(container,
      S.sectionHead('Scheduling', 'Rules that start at a time of day. Each one is a rule you can open and extend under Visual Programming.', [btn('.primary', 'plus', 'Schedule a scene', scheduleSceneDialog, 'sd:add')]),
      h('div.col',
        clock, overlaps,
        h('div.panel', h('div.panel-head', icon('calendar'), h('h3.grow', 'Week'), h('span.small.muted', 'From the draft. Tap a schedule to edit it.')), h('div.panel-body', weekView(rules))),
        h('div.vp-sched-cols',
          h('div.panel', h('div.panel-head', icon('list'), h('h3.grow', 'Schedules'), h('span.chip', String(rules.length))), h('div.panel-body', list)),
          h('div.panel', h('div.panel-head', icon('clock'), h('h3.grow', 'Next runs'), btn('.ghost', 'refresh', 'Refresh', function () { loadRuns(); }, 'sd:refresh')),
            h('div.panel-body.col', h('p.small.muted', 'From the published configuration, as the controller will run them. Publish the draft to include your changes.'), upcoming)))));
  }

  /* ── registration ────────────────────────────────────────────────────── */
  function countIssues(kind) { var n = S.issues().filter(function (i) { return i.entity && i.entity.kind === kind; }).length; return n || null; }
  function kindOfBadge(kind) { return S.issues().some(function (i) { return i.entity && i.entity.kind === kind && i.severity === 'error'; }) ? 'bad' : 'warn'; }
  S.register({ id: 'scenes', title: 'Scenes', icon: 'play', group: 'Automation', order: 1, render: renderScenes, dispose: leave, onIssues: refreshLive,
    badge: function () { return countIssues('scene'); }, badgeKind: function () { return kindOfBadge('scene'); } });
  S.register({ id: 'programming', title: 'Visual Programming', icon: 'code', group: 'Automation', order: 2, render: renderProgramming, dispose: leave, onIssues: refreshLive,
    badge: function () { return countIssues('rule'); }, badgeKind: function () { return kindOfBadge('rule'); } });
  S.register({ id: 'scheduling', title: 'Scheduling', icon: 'calendar', group: 'Automation', order: 3, render: renderScheduling, dispose: leave, onIssues: refreshLive });
})();
