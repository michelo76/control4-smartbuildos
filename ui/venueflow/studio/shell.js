/* Installer Studio shell: sign-in, navigation, the draft model with autosave,
   and the helpers every section uses. Sections register themselves with
   Studio.register({...}) from their own files (sec-*.js).

   The DRAFT lives in the driver. This page holds a working copy, sends the whole
   document back after each change (debounced) with the revision it started
   from, and shows the driver's validation of it. Nothing here is stored in the
   browser except the session token (sessionStorage, gone when the tab closes). */
var Studio = (function () {
  'use strict';
  var h = VF.h, icon = VF.icon;
  var S = {};
  var sections = [];
  var current = null, currentParams = null;
  var config = null, revision = null, issues = [], summary = { errors: 0, warnings: 0 };
  var dirty = false, saving = false, saveTimer = null, saveError = null, stale = false;
  var els = {};
  var listeners = {};

  S.boot = null;
  S.api = VF.api;
  S.on = function (name, fn) { (listeners[name] = listeners[name] || []).push(fn); };
  function emit(name, a) { (listeners[name] || []).slice().forEach(function (fn) { try { fn(a); } catch (e) { console.error(e); } }); }

  /* ── section registry ────────────────────────────────────────────────── */
  /* def = { id, title, icon, group: 'Setup'|'Venue'|'Automation'|'Access'|'System', order,
            render(container, params), dispose?(), badge?() -> string|number|null } */
  S.register = function (def) { sections.push(def); };
  var GROUPS = ['Setup', 'Venue', 'Automation', 'Access', 'System'];

  /* ── draft model ─────────────────────────────────────────────────────── */
  S.config = function () { return config; };
  S.hasDraft = function () { return config !== null; };
  S.revision = function () { return revision; };
  S.issues = function () { return issues; };
  S.summary = function () { return summary; };
  /* Issues about one entity. The driver's kinds: floor, area, source, display, audioZone, group, lighting,
     shade, room, scene, rule, variable, profile, station ('zone' is accepted for audioZone). An issue that
     names a second entity (the other display in a shared Control4 room) is returned for both. */
  S.issuesFor = function (kind, id) {
    if (kind === 'zone') kind = 'audioZone';
    return issues.filter(function (i) { return (i.entity && i.entity.kind === kind && i.entity.id === id) || (i.related && i.related.kind === kind && i.related.id === id); });
  };
  S.list = function (field) { return config ? VF.asList(config[field]) : []; };
  S.find = function (field, id) { return VF.byId(S.list(field), id); };
  S.nameOf = function (field, id, fallback) { var x = S.find(field, id); return x ? x.name : (fallback !== undefined ? fallback : (id ? '(missing)' : '—')); };

  /* Applies a change to the working copy and schedules a save.
     fn receives the config and mutates it in place. Lists the driver sent as {} are normalised first. */
  S.update = function (label, fn, opts) {
    if (!config) return;
    try { fn(config); } catch (e) { console.error(e); VF.toast('That change could not be applied.', 'bad'); return; }
    normalise(config);
    dirty = true; saveError = null;
    paintSave();
    emit('config', { label: label });
    if (!(opts && opts.silent)) rerender();
    clearTimeout(saveTimer);
    saveTimer = setTimeout(save, opts && opts.immediate ? 0 : 900);
  };
  S.replace = function (label, next, opts) { S.update(label, function (c) { Object.keys(c).forEach(function (k) { delete c[k]; }); Object.assign(c, VF.clone(next)); }, opts); };
  /* Resolves true once everything changed so far is saved (waits for a save in flight,
     then saves what was changed meanwhile), false when a save failed. */
  S.flush = function () {
    clearTimeout(saveTimer);
    if (inflight) return inflight.then(function (ok) { return dirty ? S.flush() : ok; });
    return dirty ? save().then(function (ok) { return (ok && dirty) ? S.flush() : ok; }) : Promise.resolve(saveError === null);
  };

  var LISTS = ['floors', 'areas', 'sources', 'displays', 'audioZones', 'groups', 'lighting', 'shades', 'rooms', 'scenes', 'rules', 'variables', 'profiles', 'stations'];
  function normalise(c) {
    LISTS.forEach(function (k) { c[k] = VF.asList(c[k]); });
    c.layout = VF.asMap(c.layout); c.layout.labels = VF.asList(c.layout.labels); c.layout.sceneButtons = VF.asList(c.layout.sceneButtons);
    c.venue = VF.asMap(c.venue); c.venue.subsystems = VF.asMap(c.venue.subsystems);
    c.displays.forEach(function (d) { if (d.sources !== 'all') d.sources = VF.asList(d.sources); d.route = VF.asMap(d.route); if (!d.route.strategy) d.route.strategy = 'room'; });
    c.audioZones.forEach(function (z) { if (z.sources !== 'all') z.sources = VF.asList(z.sources); z.presets = VF.asList(z.presets); z.can = VF.asMap(z.can); });
    c.groups.forEach(function (g) { g.displayIds = VF.asList(g.displayIds); });
    c.lighting.forEach(function (l) { l.presets = VF.asList(l.presets); l.presets.forEach(function (p) { p.params = VF.asMap(p.params); }); });
    c.rooms.forEach(function (r) { r.buttons = VF.asList(r.buttons); r.shadeIds = VF.asList(r.shadeIds); if (r.displayIds) r.displayIds = VF.asList(r.displayIds); });
    c.scenes.forEach(function (s) { s.program = VF.asMap(s.program); s.program.steps = VF.asList(s.program.steps); });
    c.rules.forEach(function (r) { r.program = VF.asMap(r.program); r.program.steps = VF.asList(r.program.steps); r.trigger = VF.asMap(r.trigger); if (r.trigger.days) r.trigger.days = VF.asList(r.trigger.days); });
    c.profiles.forEach(function (p) {
      p.interfaces = VF.asList(p.interfaces); p.permissions = VF.asMap(p.permissions);
      ['floors', 'areas', 'sources', 'zones', 'sceneIds'].forEach(function (k) { if (p.permissions[k] !== 'all') p.permissions[k] = VF.asList(p.permissions[k]); });
    });
    return c;
  }
  S.normalise = normalise;

  function applyDraft(draft) {
    if (!draft) { config = null; revision = null; issues = []; summary = { errors: 0, warnings: 0 }; return; }
    config = normalise(draft.config); revision = draft.revision; issues = VF.asList(draft.issues); summary = draft.summary || { errors: 0, warnings: 0 };
    dirty = false; stale = false; saveError = null;
  }

  var inflight = null;
  function save() {
    if (!config) return Promise.resolve(false);
    if (inflight) return inflight.then(function () { return dirty ? save() : saveError === null; });
    saving = true; dirty = false; paintSave();
    var sent = VF.clone(config);
    inflight = VF.api('DRAFT_SAVE', { config: sent, baseRevision: revision === null ? undefined : revision }, { since: false }).then(function (r) {
      saving = false; inflight = null;
      if (r.ok) {
        revision = r.data.revision; issues = VF.asList(r.data.issues); summary = r.data.summary || summary; saveError = null;
        emit('saved'); emit('issues');
        paintSave(); paintNav(); refreshIssueMarks();
        return true;
      }
      dirty = true;
      if (r.errorCode === 'VF_STALE_DRAFT') { stale = true; saveError = 'The draft was changed in another window.'; }
      else if (r.errorCode === 'VF_UNAUTHENTICATED') { saveError = 'Signed out.'; showLogin('Your session ended. Sign in again; unsaved changes on this screen are kept until you reload.'); }
      else saveError = r.message || 'Not saved.';
      paintSave();
      return false;
    });
    return inflight;
  }

  /* ── entity helpers ──────────────────────────────────────────────────── */
  S.freshId = function (field, base) { return VF.freshId(base, field === 'labels' || field === 'sceneButtons' ? config.layout[field] : config[field]); };

  function dropFromList(list, id) { if (list === 'all' || !list) return list; return VF.asList(list).filter(function (x) { return x !== id; }); }
  function eachStep(steps, fn) { VF.asList(steps).forEach(function (st) { fn(st); if (st.type === 'if') { eachStep(st.then, fn); eachStep(st['else'], fn); } }); }
  function eachCondition(cond, fn) { if (!cond || typeof cond !== 'object') return; fn(cond); VF.asList(cond.items).forEach(function (c) { eachCondition(c, fn); }); if (cond.item) eachCondition(cond.item, fn); }
  function eachProgram(c, fn) { c.scenes.forEach(function (s) { fn(s, 'scene'); }); c.rules.forEach(function (r) { fn(r, 'rule'); }); }
  S.eachStep = eachStep; S.eachCondition = eachCondition;

  /* Where an entity is used, as readable lines. kind: floor|area|source|display|zone|group|lighting|shade|scene|variable|profile|room */
  S.references = function (kind, id) {
    var out = [], c = config;
    function add(text) { if (out.indexOf(text) < 0) out.push(text); }
    if (kind === 'floor') { c.areas.forEach(function (a) { if (a.floorId === id) add('Area ' + a.name); }); c.displays.forEach(function (d) { if (d.floorId === id) add('Display ' + d.name); }); }
    if (kind === 'area') { c.displays.forEach(function (d) { if (d.areaId === id) add('Display ' + d.name); }); c.audioZones.forEach(function (z) { if (z.areaId === id) add('Audio zone ' + z.name); }); c.rooms.forEach(function (r) { if (r.areaId === id) add('Room panel ' + r.name); }); }
    var tail = [];
    if (kind === 'source') {
      var defaults = c.displays.filter(function (d) { return d.defaultSourceId === id; });
      if (defaults.length === 1) tail.push('Default source of ' + defaults[0].name);
      else if (defaults.length > 1) tail.push('Default source of ' + defaults.length + ' displays');
      var limited = c.displays.filter(function (d) { return d.sources !== 'all' && VF.asList(d.sources).indexOf(id) >= 0; }).length;
      if (limited) tail.push('Supported source list of ' + limited + ' display' + (limited === 1 ? '' : 's'));
    }
    if (kind === 'zone') { c.displays.forEach(function (d) { if (d.audioZoneId === id) add('Display ' + d.name); }); c.rooms.forEach(function (r) { if (r.volumeZoneId === id) add('Room panel ' + r.name); }); }
    if (kind === 'display') { c.groups.forEach(function (g) { if (g.displayIds.indexOf(id) >= 0) add('Group ' + g.name); }); }
    if (kind === 'scene') { c.rooms.forEach(function (r) { r.buttons.forEach(function (b) { if (b.sceneId === id) add('Button on room panel ' + r.name); }); }); c.layout.sceneButtons.forEach(function (b) { if (b.sceneId === id) add('Scene button on the floor plan'); }); c.rules.forEach(function (r) { if (r.trigger.type === 'scene_activated' && r.trigger.sceneId === id) add('Trigger of rule ' + r.name); }); }
    if (kind === 'lighting') { c.rooms.forEach(function (r) { if (r.lightingId === id) add('Room panel ' + r.name); }); }
    if (kind === 'shade') { c.rooms.forEach(function (r) { if (r.shadeIds.indexOf(id) >= 0) add('Room panel ' + r.name); }); }
    if (kind === 'profile') { if (c.defaultProfileId === id) add('The profile a tile opens with'); c.stations.forEach(function (st) { if (st.profileId === id) add('Station ' + st.name); }); }
    eachProgram(c, function (owner, ownerKind) {
      var label = (ownerKind === 'scene' ? 'Scene ' : 'Rule ') + owner.name;
      eachStep(owner.program.steps, function (st) {
        var t = st.target || {};
        if ((kind === 'source' && st.sourceId === id) || (kind === 'zone' && st.zoneId === id) || (kind === 'scene' && st.type === 'run_scene' && st.sceneId === id) ||
          (kind === 'lighting' && st.lightingId === id) || (kind === 'shade' && st.shadeId === id) || (kind === 'variable' && st.variableId === id) ||
          (kind === 'display' && VF.asList(t.displayIds).indexOf(id) >= 0) || (kind === 'group' && VF.asList(t.groupIds).indexOf(id) >= 0) || (kind === 'area' && VF.asList(t.areaIds).indexOf(id) >= 0)) add(label);
        if (st.type === 'if') eachCondition(st.condition, function (cd) { if (refInCondition(cd, kind, id)) add(label); });
      });
      eachCondition(owner.condition, function (cd) { if (refInCondition(cd, kind, id)) add(label); });
    });
    /* Scenes and rules first: they are what an installer most needs to see before deleting. */
    var programs = out.filter(function (t) { return /^(Scene|Rule) /.test(t); });
    var rest = out.filter(function (t) { return !/^(Scene|Rule) /.test(t); });
    return programs.concat(rest, tail);
  };
  function refInCondition(cd, kind, id) {
    return (kind === 'display' && cd.displayId === id) || (kind === 'zone' && cd.zoneId === id) || (kind === 'source' && (cd.sourceId === id || (cd.field === 'source' && cd.equals === id))) || (kind === 'variable' && cd.variableId === id) || (kind === 'area' && cd.areaId === id);
  }

  var FIELD_OF = { floor: 'floors', area: 'areas', source: 'sources', display: 'displays', zone: 'audioZones', group: 'groups', lighting: 'lighting', shade: 'shades', room: 'rooms', scene: 'scenes', rule: 'rules', variable: 'variables', profile: 'profiles', station: 'stations' };
  S.FIELD_OF = FIELD_OF;

  /* Removes an entity from a config AND every reference to it, so the result still validates
     structurally. Steps that lose their subject become "not chosen" (the driver reports them as incomplete). */
  S.removeFrom = function (c, kind, id) {
    var field = FIELD_OF[kind];
    c[field] = c[field].filter(function (x) { return x.id !== id; });
    if (kind === 'floor') {
      c.areas.filter(function (a) { return a.floorId === id; }).forEach(function (a) { S.removeFrom(c, 'area', a.id); });
      c.displays.filter(function (d) { return d.floorId === id; }).forEach(function (d) { S.removeFrom(c, 'display', d.id); });
      c.layout.labels = c.layout.labels.filter(function (l) { return l.floorId !== id; });
      c.layout.sceneButtons = c.layout.sceneButtons.filter(function (b) { return b.floorId !== id; });
      c.audioZones.forEach(function (z) { if (z.floorId === id) delete z.floorId; });
      c.profiles.forEach(function (p) { p.permissions.floors = dropFromList(p.permissions.floors, id); });
    }
    if (kind === 'area') {
      c.displays.forEach(function (d) { if (d.areaId === id) delete d.areaId; });
      c.audioZones.forEach(function (z) { if (z.areaId === id) delete z.areaId; });
      c.lighting.forEach(function (l) { if (l.areaId === id) delete l.areaId; });
      c.shades.forEach(function (s) { if (s.areaId === id) delete s.areaId; });
      c.rooms.forEach(function (r) { if (r.areaId === id) delete r.areaId; });
      c.profiles.forEach(function (p) { p.permissions.areas = dropFromList(p.permissions.areas, id); });
    }
    if (kind === 'source') {
      c.displays.forEach(function (d) { d.sources = dropFromList(d.sources, id); if (d.defaultSourceId === id) delete d.defaultSourceId; });
      c.audioZones.forEach(function (z) { z.sources = dropFromList(z.sources, id); });
      c.profiles.forEach(function (p) { p.permissions.sources = dropFromList(p.permissions.sources, id); });
    }
    if (kind === 'display') {
      c.groups.forEach(function (g) { g.displayIds = dropFromList(g.displayIds, id); });
      c.rooms.forEach(function (r) { if (r.displayIds) r.displayIds = dropFromList(r.displayIds, id); });
    }
    if (kind === 'zone') {
      c.displays.forEach(function (d) { if (d.audioZoneId === id) delete d.audioZoneId; });
      c.rooms.forEach(function (r) { if (r.volumeZoneId === id) delete r.volumeZoneId; });
      c.profiles.forEach(function (p) { p.permissions.zones = dropFromList(p.permissions.zones, id); });
    }
    if (kind === 'lighting') c.rooms.forEach(function (r) { if (r.lightingId === id) delete r.lightingId; });
    if (kind === 'shade') c.rooms.forEach(function (r) { r.shadeIds = dropFromList(r.shadeIds, id); });
    if (kind === 'scene') {
      c.rooms.forEach(function (r) { r.buttons = r.buttons.filter(function (b) { return b.sceneId !== id; }); });
      c.layout.sceneButtons = c.layout.sceneButtons.filter(function (b) { return b.sceneId !== id; });
      c.profiles.forEach(function (p) { p.permissions.sceneIds = dropFromList(p.permissions.sceneIds, id); });
      c.rules.forEach(function (r) { if (r.trigger.type === 'scene_activated' && r.trigger.sceneId === id) { r.trigger = { type: 'manual' }; r.enabled = false; } });
    }
    if (kind === 'profile') { if (c.defaultProfileId === id) delete c.defaultProfileId; c.stations = c.stations.filter(function (st) { return st.profileId !== id; }); }
    eachProgram(c, function (owner) {
      eachStep(owner.program.steps, function (st) {
        if (kind === 'source' && st.sourceId === id) delete st.sourceId;
        if (kind === 'zone' && st.zoneId === id) delete st.zoneId;
        if (kind === 'scene' && st.type === 'run_scene' && st.sceneId === id) delete st.sceneId;
        if (kind === 'lighting' && st.lightingId === id) { delete st.lightingId; delete st.presetId; }
        if (kind === 'shade' && st.shadeId === id) delete st.shadeId;
        if (kind === 'variable' && st.variableId === id) delete st.variableId;
        if (st.target) {
          if (kind === 'display') st.target.displayIds = dropFromList(st.target.displayIds, id);
          if (kind === 'group') st.target.groupIds = dropFromList(st.target.groupIds, id);
          if (kind === 'area') st.target.areaIds = dropFromList(st.target.areaIds, id);
        }
        if (st.type === 'if') eachCondition(st.condition, function (cd) { scrubCondition(cd, kind, id); });
      });
      eachCondition(owner.condition, function (cd) { scrubCondition(cd, kind, id); });
    });
  };
  function scrubCondition(cd, kind, id) {
    if (kind === 'display' && cd.displayId === id) delete cd.displayId;
    if (kind === 'zone' && cd.zoneId === id) delete cd.zoneId;
    if (kind === 'source') { if (cd.sourceId === id) delete cd.sourceId; if (cd.field === 'source' && cd.equals === id) delete cd.equals; }
    if (kind === 'variable' && cd.variableId === id) delete cd.variableId;
    if (kind === 'area' && cd.areaId === id) delete cd.areaId;
  }

  /* Asks, listing what else changes, then removes. Deleting anything here only edits the
     VenueFlow configuration; nothing in the Control4 project is touched. Returns Promise(bool). */
  S.confirmRemove = function (kind, id, noun) {
    var item = S.find(FIELD_OF[kind], id); if (!item) return Promise.resolve(false);
    var refs = S.references(kind, id);
    var body = h('div.col',
      h('p', 'Delete ' + (noun || kind) + ' "' + item.name + '" from this configuration?'),
      refs.length ? h('div.banner.warn', icon('alert'), h('div', h('div', 'It is used in ' + refs.length + ' place' + (refs.length === 1 ? '' : 's') + '. Those references will be cleared:'), h('ul.small', { style: { margin: '6px 0 0', paddingLeft: '18px' } }, refs.slice(0, 8).map(function (r) { return h('li', r); }), refs.length > 8 ? h('li', 'and ' + (refs.length - 8) + ' more') : null))) : null,
      h('p.small.muted', 'This changes the VenueFlow draft only. No Control4 device, room or connection is deleted or changed.'));
    return VF.modal({ title: 'Delete ' + (noun || kind), icon: 'trash', body: body, actions: [{ label: 'Cancel', kind: 'ghost', value: false }, { label: 'Delete', kind: 'danger', value: true }] }).then(function (ok) {
      if (ok !== true) return false;
      S.update('Delete ' + (noun || kind), function (c) { S.removeFrom(c, kind, id); });
      return true;
    });
  };

  /* ── form helpers (return DOM) ───────────────────────────────────────── */
  S.text = function (label, value, onChange, opts) {
    opts = opts || {};
    var input = h(opts.multiline ? 'textarea.field' : 'input.field', { type: opts.type || 'text', value: value === undefined || value === null ? '' : value, placeholder: opts.placeholder, maxlength: opts.max || 80, disabled: opts.disabled, inputmode: opts.inputmode });
    input.addEventListener('change', function () { onChange(input.value.trim()); });
    return h('label.lbl', label, input, opts.hint ? h('span.hint', opts.hint) : null);
  };
  S.number = function (label, value, onChange, opts) {
    opts = opts || {};
    var input = h('input.field', { type: 'number', value: value === undefined || value === null ? '' : value, min: opts.min, max: opts.max, step: opts.step || 1, placeholder: opts.placeholder, disabled: opts.disabled });
    input.addEventListener('change', function () {
      if (input.value === '') { onChange(undefined); return; }
      var n = Number(input.value); if (isNaN(n)) return;
      if (opts.min !== undefined) n = Math.max(opts.min, n); if (opts.max !== undefined) n = Math.min(opts.max, n);
      onChange(n);
    });
    return h('label.lbl', label, input, opts.hint ? h('span.hint', opts.hint) : null);
  };
  /* options: [{value, label}] or ['a','b']; opts.none adds an empty first option with that label */
  S.select = function (label, options, value, onChange, opts) {
    opts = opts || {};
    var sel = h('select.field', { disabled: opts.disabled });
    if (opts.none !== undefined) sel.appendChild(h('option', { value: '' }, opts.none));
    options.forEach(function (o) { var v = typeof o === 'object' ? o.value : o, l = typeof o === 'object' ? o.label : o; sel.appendChild(h('option', { value: v, selected: String(v) === String(value === undefined || value === null ? '' : value) }, l)); });
    sel.addEventListener('change', function () { onChange(sel.value === '' ? undefined : sel.value); });
    return label ? h('label.lbl', label, sel, opts.hint ? h('span.hint', opts.hint) : null) : sel;
  };
  S.entityOptions = function (field) { return S.list(field).map(function (x) { return { value: x.id, label: x.name }; }); };
  S.toggle = function (label, value, onChange, hint) {
    var btn = h('button.toggle' + (value ? '.on' : ''), { type: 'button', role: 'switch', 'aria-checked': value ? 'true' : 'false', 'aria-label': label, onclick: function () { onChange(!value); } });
    return h('div.row.between', { style: { minHeight: '44px' } }, h('div.col.tight', h('span', label), hint ? h('span.hint', hint) : null), btn);
  };
  S.check = function (label, value, onChange) {
    var input = h('input', { type: 'checkbox', checked: !!value }); input.addEventListener('change', function () { onChange(input.checked); });
    return h('label.check', input, h('span', label));
  };
  /* "all" or a list of ids, as checkboxes. value: 'all' | [ids]. allowAll adds the "All" switch. */
  S.idPicker = function (label, field, value, onChange, opts) {
    opts = opts || {};
    var items = opts.items || S.list(field);
    var all = value === 'all';
    var chosen = all ? [] : VF.asList(value);
    var box = h('div.col.tight');
    if (opts.allowAll !== false) box.appendChild(S.check(opts.allLabel || 'All (including ones added later)', all, function (on) { onChange(on ? 'all' : items.map(function (x) { return x.id; })); }));
    if (!all) {
      var grid = h('div', { style: { display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(160px, 1fr))', gap: '2px 10px' } });
      items.forEach(function (x) { grid.appendChild(S.check(x.name, chosen.indexOf(x.id) >= 0, function (on) { var next = chosen.filter(function (i) { return i !== x.id; }); if (on) next.push(x.id); onChange(next); })); });
      if (!items.length) grid.appendChild(h('span.hint', 'Nothing to choose from yet.'));
      box.appendChild(grid);
    }
    return h('div.col.tight', label ? h('span.small', { style: { color: 'var(--ink-2)', fontWeight: 550 } }, label) : null, box);
  };
  S.issueList = function (list) {
    if (!list || !list.length) return null;
    return h('div.col.tight', list.map(function (i) { return h('div.banner.' + (i.severity === 'error' ? 'bad' : 'warn'), icon('alert', 'sm'), h('div.small', i.message)); }));
  };
  S.issueChip = function (kind, id) {
    var list = S.issuesFor(kind, id); if (!list.length) return null;
    var errors = list.filter(function (i) { return i.severity === 'error'; }).length;
    return h('span.chip.' + (errors ? 'bad' : 'warn'), { title: list.map(function (i) { return i.message; }).join('\n') }, icon('alert', 'sm'), String(list.length));
  };
  S.sectionHead = function (title, subtitle, actions) {
    return h('div.row.between.wrap', { style: { marginBottom: '14px' } }, h('div.col.tight', h('h1', title), subtitle ? h('p.muted', subtitle) : null), h('div.row.wrap', actions || null));
  };
  S.emptyDraft = function (container) {
    VF.mount(container, S.sectionHead('No draft yet', 'Start with the Setup Wizard: pick a business type and VenueFlow fills in sensible defaults.'),
      h('div.empty', h('p', 'This driver has no configuration yet.'), h('div', { style: { marginTop: '12px' } }, h('button.btn.primary', { type: 'button', onclick: function () { S.go('wizard'); } }, icon('zap'), 'Open the Setup Wizard'))));
  };

  /* ── navigation ──────────────────────────────────────────────────────── */
  S.go = function (id, params) {
    var def = sections.filter(function (s) { return s.id === id; })[0]; if (!def) return;
    if (current && current.dispose) { try { current.dispose(); } catch (e) { console.error(e); } }
    current = def; currentParams = params || null;
    try { history.replaceState(null, '', '#' + id); } catch (e) { /* ignore */ }
    paintNav(); rerender(); els.main.scrollTop = 0;
  };
  S.currentSection = function () { return current ? current.id : null; };
  function rerender() {
    if (!current || !els.main) return;
    var keep = els.main.scrollTop;
    var host = h('div.sec');
    try { current.render(host, currentParams); } catch (e) { console.error(e); VF.mount(host, h('div.banner.bad', icon('alert'), h('div', 'This section failed to draw: ' + e.message))); }
    VF.mount(els.main, wizardBar(), host);
    els.main.scrollTop = keep;
  }
  S.refresh = rerender;
  /* A section opened from the Setup Wizard (S.go(id, {wizard: {step, title}})) gets a bar to go back or on. */
  function wizardBar() {
    var w = currentParams && currentParams.wizard; if (!w || !current || current.id === 'wizard') return null;
    return h('div.wizbar.panel', h('span.chip.teal', icon('zap', 'sm'), 'Setup Wizard'), h('span.grow', 'Step ' + w.step + ' of 6: ' + (w.title || '')),
      h('button.btn.sm.ghost', { type: 'button', onclick: function () { S.go('wizard', { step: w.step }); } }, icon('arrow-left'), 'Back to wizard'),
      h('button.btn.sm.primary', { type: 'button', onclick: function () { S.go('wizard', { step: Math.min(6, w.step + 1) }); } }, 'Next step', icon('arrow-right')));
  }
  /* For commands that change the draft ON THE DRIVER (PROFILE_PIN_SET, TEMPLATE_APPLY, BACKUP_RESTORE,
     DRAFT_DISCARD ...): saves pending edits, runs the command with the current revision, reloads.
     Returns Promise(reply). */
  S.serverEdit = function (command, payload) {
    return S.flush().then(function (saved) {
      if (!saved && config) return { ok: false, status: 'failed', errorCode: 'VF_STALE_DRAFT', message: saveError || 'Your last changes could not be saved, so this was not done.' };
      var body = Object.assign({}, payload || {});
      if (command === 'PROFILE_PIN_SET' && revision !== null) body.baseRevision = revision;
      return VF.api(command, body, { since: false }).then(function (r) { return S.reload().then(function () { return r; }); });
    });
  };
  function refreshIssueMarks() { if (current && current.onIssues) { try { current.onIssues(); } catch (e) { console.error(e); } } }

  function paintNav() {
    if (!els.nav) return;
    VF.clear(els.nav);
    GROUPS.forEach(function (g) {
      var list = sections.filter(function (s) { return s.group === g; }).sort(function (a, b) { return (a.order || 0) - (b.order || 0); });
      if (!list.length) return;
      els.nav.appendChild(h('h4', g));
      list.forEach(function (s) {
        var badge = s.badge ? s.badge() : null;
        els.nav.appendChild(h('button.navitem' + (current === s ? '.on' : ''), { type: 'button', onclick: function () { S.go(s.id); }, 'aria-current': current === s ? 'page' : null },
          icon(s.icon || 'square'), h('span.grow', s.title), badge !== null && badge !== undefined && badge !== '' ? h('span.chip' + (s.badgeKind ? '.' + s.badgeKind() : ''), String(badge)) : null));
      });
    });
  }

  function paintSave() {
    if (!els.save) return;
    var text, cls = '';
    if (!config) { text = 'No draft'; }
    else if (stale) { text = 'Draft changed elsewhere'; cls = 'bad'; }
    else if (saveError) { text = saveError; cls = 'bad'; }
    else if (saving) { text = 'Saving…'; cls = 'teal'; }
    else if (dirty) { text = 'Unsaved changes'; cls = 'warn'; }
    else { text = 'Saved · revision ' + revision; cls = 'ok'; }
    VF.mount(els.save, h('span.chip.' + (cls || 'x'), h('span.dot' + (saving ? '.pulse' : '')), text), stale ? h('button.btn.sm.warn', { type: 'button', onclick: function () { S.reload(); } }, icon('refresh'), 'Reload draft') : null);
    VF.mount(els.issues, !config ? null : h('button.btn.sm' + (summary.errors ? '.danger' : (summary.warnings ? '.warn' : '.ghost')), { type: 'button', title: 'Open Publish and Rollback', onclick: function () { S.go('publish'); } },
      icon(summary.errors || summary.warnings ? 'alert' : 'check-circle'), summary.errors ? summary.errors + ' error' + (summary.errors === 1 ? '' : 's') : (summary.warnings ? summary.warnings + ' to review' : 'No issues')));
  }

  /* ── boot ────────────────────────────────────────────────────────────── */
  S.reload = function () {
    return VF.api('STUDIO_BOOTSTRAP', {}, { since: false }).then(function (r) {
      if (!r.ok) { if (r.errorCode === 'VF_UNAUTHENTICATED' || r.errorCode === 'VF_STUDIO_DISABLED') showLogin(r.errorCode === 'VF_STUDIO_DISABLED' ? r.message : null); else VF.toast(r.message, 'bad'); return false; }
      S.boot = r.data;
      S.published = r.data.published || null;
      S.history = VF.asList(r.data.history);
      applyDraft(r.data.draft || null);
      emit('boot');
      paintChrome(); paintNav(); paintSave(); rerender();
      return true;
    });
  };

  function paintChrome() {
    var b = S.boot;
    VF.mount(els.venue, h('span.ellipsis', config && config.venue.name ? config.venue.name : 'New venue'));
    VF.mount(els.mode, b.driver.simulation ? h('span.chip.warn', h('span.dot'), 'Simulation') : h('span.chip.ok', h('span.dot'), 'Live'),
      S.published ? h('span.chip', 'Published ' + S.published.versionId) : h('span.chip.warn', 'Not published'));
    els.sim.classList.toggle('hidden', !b.driver.simulation);
  }
  S.on('config', function () { if (els.venue && config) VF.mount(els.venue, h('span.ellipsis', config.venue.name || 'New venue')); });

  function showLogin(message) {
    VF.session.clear();
    var pass = h('input.field', { type: 'password', autocomplete: 'current-password', placeholder: 'Installer Passcode' });
    var err = h('div.small', { style: { color: 'var(--bad)', minHeight: '18px' } }, message || '');
    var btn = h('button.btn.primary.block.lg', { type: 'submit' }, icon('unlock'), 'Open Installer Studio');
    var form = h('form.col', { onsubmit: function (e) {
      e.preventDefault(); btn.disabled = true;
      VF.api('STUDIO_LOGIN', { passcode: pass.value }, { since: false }).then(function (r) {
        btn.disabled = false;
        if (!r.ok) { err.textContent = (r.errorCode === 'VF_BAD_PASSCODE' || r.errorCode === 'VF_BAD_PIN') ? 'That passcode is not right.' : (r.message || 'Sign-in failed.'); pass.value = ''; pass.focus(); return; }
        VF.session.set(r.data.session); els.login.classList.add('hidden'); els.app.classList.remove('hidden');
        S.reload().then(function () { if (!current) S.go((location.hash || '').slice(1) || (config ? 'overview' : 'wizard')); });
      });
    } }, h('label.lbl', 'Installer Passcode', pass), err, btn,
      h('p.small.muted', 'The passcode is the driver property "Installer Passcode" in Composer Pro. With no passcode set, Installer Studio stays off.'));
    VF.mount(els.login, h('div.login-card.panel.pad', h('div.row', { style: { marginBottom: '14px' } }, brand(), h('span.muted', 'Installer Studio')), form));
    els.login.classList.remove('hidden'); els.app.classList.add('hidden');
    setTimeout(function () { try { pass.focus(); } catch (e) { /* ignore */ } }, 50);
  }
  function brand() { return h('div.brand', h('span.brandmark', icon('bars')), h('span', 'Venue', h('b', 'Flow'))); }
  S.brand = brand;

  S.signOut = function () { S.flush().then(function () { VF.api('LOGOUT', {}, { since: false }).then(function () { showLogin(); }); }); };

  S.start = function () {
    VF.session.use('studio');
    els.login = document.getElementById('login'); els.app = document.getElementById('app'); els.nav = document.getElementById('nav'); els.main = document.getElementById('main');
    els.save = document.getElementById('save'); els.issues = document.getElementById('issues'); els.venue = document.getElementById('venue'); els.mode = document.getElementById('mode'); els.sim = document.getElementById('sim');
    VF.mount(document.getElementById('brand'), brand());
    document.getElementById('signout').addEventListener('click', S.signOut);
    document.getElementById('openop').addEventListener('click', function () { S.flush().then(function () { window.open((VF.transport.relay || '') + '/app?as=studio', '_blank'); }); });
    document.getElementById('navtoggle').addEventListener('click', function () { els.app.classList.toggle('navopen'); });
    els.nav.addEventListener('click', function () { els.app.classList.remove('navopen'); });
    window.addEventListener('beforeunload', function (e) { if (dirty || saving) { e.preventDefault(); e.returnValue = ''; } });
    VF.on('online', function (on) { document.getElementById('offline').classList.toggle('hidden', on); });
    if (!VF.session.get()) { showLogin(); return; }
    els.app.classList.remove('hidden');
    S.reload().then(function (ok) { if (ok && !current) S.go((location.hash || '').slice(1) || (config ? 'overview' : 'wizard')); });
  };

  return S;
})();
