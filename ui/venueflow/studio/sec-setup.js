/* Installer Studio: the Setup group (Overview, Setup Wizard) and the System
   group (Diagnostics, Licensing, Configuration Backup, Publish and Rollback).

   Everything here reads the working copy through Studio.config() and changes it
   only through Studio.update / Studio.serverEdit. Wizard progress is derived
   from the draft and the driver's validation of it on every draw; nothing about
   it is stored. Selectors of this file's CSS (css/setup.css) start with "su-". */
(function () {
  'use strict';
  var h = VF.h, icon = VF.icon;

  /* ── small helpers ───────────────────────────────────────────────────── */
  function cfg() { return Studio.config(); }
  function boot() { return Studio.boot || {}; }
  function schema() { return VF.asMap(boot().schema); }
  function isSim() { return !!(boot().driver && boot().driver.simulation); }
  function has(v) { return v !== undefined && v !== null && v !== ''; }
  function count(n, one, many) { return n + ' ' + (n === 1 ? one : (many || one + 's')); }
  function when(epoch) { return epoch ? VF.fmtDateTime(epoch) + ' (' + VF.ago(epoch) + ')' : 'time not recorded'; }
  function wait(ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); }
  function onSection(id) { return Studio.currentSection() === id; }
  function words(text) { return String(text || '').replace(/_/g, ' ').replace(/\b[a-z]/g, function (ch) { return ch.toUpperCase(); }); }
  function kb(bytes) { return bytes >= 1024 * 1024 ? (bytes / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(bytes / 1024)) + ' kB'; }
  function scrollTop() { var m = document.getElementById('main'); if (m) m.scrollTop = 0; }
  function panel(title, ic, actions, children) {
    return h('section.panel', h('div.panel-head', ic ? icon(ic) : null, h('h2.grow', title), actions || null), h('div.panel-body.col', children));
  }
  function kv(rows) {
    var dl = h('dl.su-kv');
    rows.forEach(function (r) { if (!r) return; dl.appendChild(h('dt', r[0])); dl.appendChild(h('dd', r[1])); });
    return dl;
  }
  function banner(kind, ic, content) { return h('div.banner.' + kind, icon(ic), h('div.grow', content)); }
  /* A field built by Studio.text / Studio.number / Studio.select with an empty label: name it for screen readers. */
  function bare(node, label) {
    var field = node.matches && node.matches('input, select, textarea') ? node : node.querySelector('input, select, textarea');
    if (field) field.setAttribute('aria-label', label);
    return node;
  }

  /* A Cancel action with the literal value false does not close a VF.modal (shared/vf.js treats
     false as "keep the dialog open"), so every dialog here cancels with null. */
  var CANCEL = { label: 'Cancel', kind: 'ghost', value: null };
  /* Promise(true | false). body: text or a node. */
  function ask(title, body, okLabel, kind, ic) {
    return VF.modal({ title: title, icon: ic || (kind === 'danger' ? 'alert' : 'help'), body: body, actions: [CANCEL, { label: okLabel || 'Confirm', kind: kind || 'primary', value: true }] })
      .then(function (v) { return v === true; });
  }

  /* Studio.flush() answers at once while a save is still on its way (and answers
     "not saved" when more edits wait behind one). Before a command that reads the
     STORED draft, also check that the driver holds the revision this page holds.
     Promise(true | false). */
  function settleDraft(tries) {
    if (!cfg()) return Promise.resolve(true);
    tries = tries === undefined ? 8 : tries;
    return Studio.flush().then(function (saved) {
      return VF.api('DRAFT_VALIDATE', {}, { since: false }).then(function (r) {
        if (saved !== false && r.ok && r.data && r.data.revision === Studio.revision()) return true;
        if (tries <= 0) return false;
        return wait(300).then(function () { return settleDraft(tries - 1); });
      });
    });
  }

  /* ── does the draft differ from what is published? ───────────────────── */
  /* The driver gives no comparison, so this only says "same" when it is certain:
     the draft is based on the published version and was not saved after it, or
     this page itself just published or discarded. Everything else is "may differ". */
  var edits = 0, bootEdits = 0, known = null, savedHere = 0, bootSeen = null;
  /* Studio.reload() draws the section BEFORE it emits "boot", so a fresh load is noticed
     by the identity of the bootstrap data: on that event, and again whenever it is read. */
  function syncBoot() { if (Studio.boot !== bootSeen) { bootSeen = Studio.boot; bootEdits = edits; savedHere = 0; } }
  Studio.on('boot', syncBoot);
  Studio.on('config', function () { syncBoot(); edits++; });
  Studio.on('saved', function () { syncBoot(); savedHere = Math.floor(Date.now() / 1000); });
  /* When the draft was last saved: by this page since it loaded, else what the driver said at load. */
  function draftSavedAt() { syncBoot(); return savedHere || (boot().draft && boot().draft.savedAt) || 0; }
  function relation() {
    syncBoot();
    var p = Studio.published, d = boot().draft;
    if (!cfg() || !d) return { key: 'nodraft' };
    if (!p) return { key: 'unpublished' };
    if (edits !== bootEdits) return { key: 'edited', text: 'The draft was changed on this screen since it was loaded: it may differ from ' + p.versionId + '.' };
    /* The driver compares the two documents exactly when the Studio loads. */
    if (typeof d.matchesPublished === 'boolean' && !(known && known.versionId === p.versionId && known.revision === Studio.revision())) {
      return d.matchesPublished ? { key: 'same' } : { key: 'differs', text: 'The draft has changes that are not in ' + p.versionId + '. Publish to use them.' };
    }
    if (d.basedOn !== p.versionId) return { key: 'other', text: 'The draft ' + (d.basedOn ? 'is based on ' + d.basedOn : 'was not started from a published version') + ', and ' + p.versionId + ' is published: it may differ.' };
    if (known && known.versionId === p.versionId && known.revision === Studio.revision()) return { key: 'same' };
    if (d.savedAt && p.publishedAt && d.savedAt < p.publishedAt) return { key: 'same' };
    return { key: 'maybe', text: 'The draft was saved at or after the time ' + p.versionId + ' was published: it may differ.' };
  }
  function relationChip() {
    var r = relation(), p = Studio.published;
    if (r.key === 'nodraft') return h('span.chip', 'No draft');
    if (r.key === 'unpublished') return h('span.chip.warn', h('span.dot'), 'Not published');
    if (r.key === 'same') return h('span.chip.ok', h('span.dot'), 'Draft matches ' + p.versionId);
    if (r.key === 'differs') return h('span.chip.warn', h('span.dot'), 'Draft differs from ' + p.versionId);
    return h('span.chip.warn', h('span.dot'), 'Draft may differ from ' + p.versionId);
  }

  /* ── issues: which section fixes one ─────────────────────────────────── */
  /* The titles the other section files register under (sec-entities.js, sec-layout.js, sec-programming.js). */
  var SECTION_LABEL = { devices: 'Devices', sources: 'Sources', zones: 'Audio Zones', groups: 'Display Groups', ambient: 'Lighting and Shades', rooms: 'Room Panels', profiles: 'Staff Profiles', scenes: 'Scenes', programming: 'Visual Programming', layout: 'Layout Designer', wizard: 'Setup Wizard', publish: 'Publish' };
  /* entity.kind -> section. The driver's name checks report the kind as a label
     ("Display", "Audio zone", "Staff profile"), so the lookup is by lower-case text. */
  var KIND_SECTION = {
    display: 'devices', source: 'sources', audiozone: 'zones', 'audio zone': 'zones', zone: 'zones',
    group: 'groups', 'display group': 'groups', lighting: 'ambient', 'lighting control': 'ambient', shade: 'ambient',
    room: 'rooms', 'room panel': 'rooms', profile: 'profiles', 'staff profile': 'profiles',
    scene: 'scenes', rule: 'programming', variable: 'programming', area: 'wizard', floor: 'wizard'
  };
  /* The parameter each of those sections reads to open on one entity (ignored where it is not known). */
  var KIND_PARAM = {
    display: 'displayId', source: 'sourceId', audiozone: 'zoneId', 'audio zone': 'zoneId', zone: 'zoneId',
    group: 'groupId', 'display group': 'groupId', lighting: 'lightingId', 'lighting control': 'lightingId', shade: 'shadeId',
    room: 'roomId', 'room panel': 'roomId', profile: 'profileId', 'staff profile': 'profileId', scene: 'sceneId', rule: 'ruleId'
  };
  function kindOf(i) { return i && i.entity && i.entity.kind ? String(i.entity.kind).toLowerCase() : ''; }
  function issueTarget(i) {
    var id = KIND_SECTION[kindOf(i)], path = String(i.path || '');
    if (!id && !i.entity) {
      /* No entity: the driver means the venue as a whole. Where the path names the place, go there. */
      if (/^(venue|floors|areas)\b/.test(path)) id = 'wizard';
      else if (/^(profiles|defaultProfileId)\b/.test(path)) id = 'profiles';
      else if (/^layout\b/.test(path)) id = 'layout';
    }
    id = id || 'publish';
    var params = null, key = KIND_PARAM[kindOf(i)];
    if (id === 'wizard') params = { step: 1 };
    else if (key && i.entity && has(i.entity.id)) { params = {}; params[key] = i.entity.id; }
    return { id: id, params: params };
  }
  function isError(i) { return i.severity === 'error'; }
  function isVenueIssue(i) { var k = kindOf(i); return k === 'floor' || k === 'area' || (!i.entity && /^(venue|floors|areas)\b/.test(String(i.path || ''))); }
  function isMappingIssue(i) { var k = kindOf(i); return k === 'display' || k === 'source' || k === 'audiozone' || k === 'audio zone'; }
  function isProfileIssue(i) { var k = kindOf(i); return k === 'profile' || k === 'staff profile' || (!i.entity && /^(profiles|defaultProfileId)\b/.test(String(i.path || ''))); }
  function isLayoutIssue(i) { return i.code === 'LAYOUT_INVALID' || /^layout\b/.test(String(i.path || '')); }

  /* opts: { noLink, path, extra } */
  function issueRow(i, opts) {
    opts = opts || {};
    var t = issueTarget(i), bad = isError(i);
    var link = !opts.noLink && t.id !== 'publish';
    return h('div.su-issue.' + (bad ? 'bad' : 'warn'), icon('alert', 'sm'),
      h('div.grow', h('div', i.message), opts.path && i.path ? h('div.path', i.path) : null, opts.extra || null),
      link ? h('button.btn.sm', { type: 'button', onclick: function () { Studio.go(t.id, t.params); } }, (bad ? 'Fix in ' : 'Open ') + (SECTION_LABEL[t.id] || t.id), icon('arrow-right', 'sm')) : null);
  }
  function issueRows(list, opts, max) {
    max = max || list.length;
    var rows = list.slice(0, max).map(function (i) { return issueRow(i, opts); });
    if (list.length > max) rows.push(h('p.small.muted', 'and ' + (list.length - max) + ' more. Publish and Rollback lists every one.'));
    return h('div.col.tight', rows);
  }

  /* ── what is mapped and placed (derived from the draft) ──────────────── */
  function displayMapped(d) {
    var r = VF.asMap(d.route);
    if (r.strategy === 'room' || d.power === 'room' || d.feedback === 'room') return has(d.c4RoomId);
    if (r.strategy === 'command') return !!(r.command && has(r.command.deviceId));
    return has(d.c4DeviceId);
  }
  function mapStats(c) {
    function part(list, test) { var m = list.filter(test).length; return { total: list.length, mapped: m, unmapped: list.length - m }; }
    var s = {
      displays: part(c.displays, displayMapped),
      sources: part(c.sources, function (x) { return has(x.c4DeviceId); }),
      zones: part(c.audioZones, function (x) { return has(x.c4RoomId); })
    };
    s.total = s.displays.total + s.sources.total + s.zones.total;
    s.mapped = s.displays.mapped + s.sources.mapped + s.zones.mapped;
    s.unmapped = s.total - s.mapped;
    return s;
  }
  function placed(c, d) { var l = d.layout; return !!(l && typeof l === 'object' && typeof l.x === 'number' && typeof l.y === 'number' && VF.byId(c.floors, d.floorId)); }
  function layoutStats(c) {
    var n = 0, hidden = 0;
    c.displays.forEach(function (d) { if (placed(c, d)) { n++; if (d.layout.hidden) hidden++; } });
    return { total: c.displays.length, placed: n, hidden: hidden };
  }

  function openOperator() { Studio.flush().then(function () { window.open((VF.transport.relay || '') + '/app?as=studio', '_blank'); }); }

  /* ════════════════════════════════════════════════════════════════════════
     1. Overview
     ════════════════════════════════════════════════════════════════════════ */
  function tile(n, label, ic, sub, warn, go) {
    return h('button.su-tile' + (warn ? '.warn' : ''), { type: 'button', onclick: go }, h('div.row.between', { style: { width: '100%' } }, h('span.n', String(n)), icon(ic)), h('span.l', label), h('span.s', sub || ' '));
  }
  function renderOverview(container) {
    var c = cfg();
    if (!c) { Studio.emptyDraft(container); return; }
    var b = boot(), m = mapStats(c), list = Studio.issues();
    var errors = list.filter(isError), warnings = list.filter(function (i) { return !isError(i); });
    function go(id, params) { return function () { Studio.go(id, params || null); }; }
    function mapNote(p) { return !p.total ? '' : (p.unmapped ? p.unmapped + ' not mapped' : 'all mapped'); }

    var tiles = h('div.su-tiles',
      tile(c.floors.length, 'Floors', 'layers', '', false, go('wizard', { step: 1 })),
      tile(c.areas.length, 'Areas', 'grid', '', false, go('wizard', { step: 1 })),
      tile(c.displays.length, 'Displays', 'tv', mapNote(m.displays), m.displays.unmapped > 0, go('devices')),
      tile(c.sources.length, 'Sources', 'route', mapNote(m.sources), m.sources.unmapped > 0, go('sources')),
      tile(c.audioZones.length, 'Audio zones', 'volume', mapNote(m.zones), m.zones.unmapped > 0, go('zones')),
      tile(c.groups.length, 'Display groups', 'copy', '', false, go('groups')),
      tile(c.scenes.length, 'Scenes', 'sparkles', '', false, go('scenes')),
      tile(c.rules.length, 'Rules', 'calendar', c.rules.length ? c.rules.filter(function (r) { return r.enabled !== false; }).length + ' enabled' : '', false, go('programming')),
      tile(c.profiles.length, 'Staff profiles', 'users', c.profiles.length ? c.profiles.filter(function (p) { return p.hasPin; }).length + ' with a PIN' : '', false, go('profiles')));

    var p = Studio.published, rel = relation();
    var publication = panel('Publication', 'upload', relationChip(), [
      kv([
        ['Published', p ? h('span', h('b', p.versionId), ', ' + when(p.publishedAt)) : 'Not published. The venue has no configuration until you publish.'],
        p && p.note ? ['Note', p.note] : null,
        ['Draft', 'Revision ' + Studio.revision() + (draftSavedAt() ? ', last saved ' + when(draftSavedAt()) : '')],
        ['Compared', rel.key === 'same' ? 'No changes since ' + p.versionId + ' was published.' : (rel.key === 'unpublished' ? 'Nothing is published yet.' : rel.text)],
        VF.asList(Studio.history).length ? ['Earlier versions', VF.asList(Studio.history).length + ' kept for rollback'] : null
      ]),
      h('div.row.wrap', h('button.btn.sm.primary', { type: 'button', onclick: go('publish') }, icon('upload'), 'Review and publish'))
    ]);

    var validation = panel('Validation', errors.length || warnings.length ? 'alert' : 'check-circle',
      errors.length ? h('span.chip.bad', count(errors.length, 'error')) : (warnings.length ? h('span.chip.warn', warnings.length + ' to review') : h('span.chip.ok', 'No issues')), [
        !list.length ? banner('ok', 'check-circle', 'The driver found nothing to fix in this draft.') : null,
        errors.length ? h('div.col.tight', h('h4', 'Errors: must be fixed before publishing'), issueRows(errors, null, 8)) : null,
        warnings.length ? h('div.col.tight', h('h4', 'Warnings: fix, or acknowledge when publishing'), issueRows(warnings, null, 8)) : null
      ]);

    var info = VF.asMap(b.info), lic = VF.asMap(b.license), drv = VF.asMap(b.driver), ctl = VF.asMap(b.controller);
    var INFO_LABEL = { relay: 'Relay', host: 'Relay host', port: 'Relay port', url: 'Relay address', address: 'Relay address' };
    var rows = [
      ['Time zone', ctl.timeZone || 'Not reported by the controller'],
      ['Local time', (ctl.localTime || 'Not reported') + ' (when this screen loaded)'],
      ['Control mode', drv.simulation ? h('span.chip.warn', h('span.dot'), 'Simulation') : h('span.chip.ok', h('span.dot'), 'Live')],
      ['Driver version', has(drv.version) ? String(drv.version) : 'Not reported']
    ];
    var first = ['relay', 'host', 'port'];
    Object.keys(info).sort(function (a, b) { var x = first.indexOf(a), y = first.indexOf(b); return (x < 0 ? 9 : x) - (y < 0 ? 9 : y) || (a < b ? -1 : 1); }).forEach(function (k) { var v = info[k]; rows.push([INFO_LABEL[k] || words(k), typeof v === 'object' ? JSON.stringify(v) : String(v)]); });
    if (!Object.keys(info).length) rows.push(['Relay', 'Not reported']);
    rows.push(['Venue status', words(b.venueStatus || 'unknown')]);
    rows.push(['Licence', h('div.row.wrap.tight', h('span', lic.label || 'Not reported'), lic.restricted ? h('span.chip.bad', 'Features restricted') : null,
      h('button.btn.sm.ghost', { type: 'button', onclick: go('licensing') }, 'Details'))]);
    var controller = panel('Controller', 'settings', h('button.btn.sm.ghost', { type: 'button', title: 'Read again from the controller', onclick: function () { Studio.reload(); } }, icon('refresh'), 'Refresh'), [kv(rows)]);

    VF.mount(container,
      Studio.sectionHead('Overview', c.venue.name || 'New venue', [
        h('button.btn.sm', { type: 'button', onclick: go('wizard') }, icon('zap'), 'Setup Wizard'),
        h('button.btn.sm.outline', { type: 'button', onclick: openOperator }, icon('monitor'), 'Operator view'),
        h('button.btn.sm.primary', { type: 'button', onclick: go('publish') }, icon('upload'), 'Publish')]),
      h('div.col', tiles, h('div.su-two', h('div.col', publication, controller), validation)));
  }

  /* ════════════════════════════════════════════════════════════════════════
     3. Publish and Rollback (also step 6 of the wizard)
     ════════════════════════════════════════════════════════════════════════ */
  var ACK_MAX = 256;      /* the protocol accepts at most 256 ids in one list */
  var pub = { acks: {}, note: '', busy: false, refused: null, blocking: null, noteEl: null };
  /* Issue ids hold a list position (displays[24]); pairing the id with the message keeps
     a tick from moving to another entity when something above it is deleted. */
  function ackKey(i) { return i.id + '|' + i.message; }

  function doPublish() {
    if (pub.busy) return;
    pub.busy = true; pub.refused = null; pub.blocking = null;
    Studio.refresh();
    settleDraft().then(function (saved) {
      if (!saved) { pub.busy = false; pub.refused = 'The draft on the controller is not the one on this screen (not saved yet, or changed in another window), so nothing was published. Check the save indicator at the top.'; Studio.refresh(); return; }
      /* The save may have changed the issues: send what is ticked AND still listed. */
      var acked = Studio.issues().filter(function (i) { return !isError(i) && pub.acks[ackKey(i)]; }).map(function (i) { return i.id; });
      var payload = { acknowledged: acked }, note = pub.note.trim();
      if (note) payload.note = note;
      var revision = Studio.revision();
      return VF.api('PUBLISH', payload, { since: false }).then(function (r) {
        pub.busy = false;
        if (r.ok && r.data) {
          pub.acks = {}; pub.note = '';
          known = { versionId: r.data.versionId, revision: revision };
          VF.toast('Published ' + r.data.versionId + '. The venue runs on it now.', 'ok');
          return Studio.reload();
        }
        pub.refused = (r.message || 'Not published.') + (r.detail ? ' (' + r.detail + ')' : '');
        if (r.errorCode === 'VF_VALIDATION_FAILED') { pub.blocking = VF.asList(r.data && r.data.blocking); return Studio.reload(); }
        Studio.refresh();
      });
    });
  }

  function doRollback(v) {
    var p = Studio.published;
    VF.modal({
      title: 'Roll back to ' + v.versionId + '?', icon: 'history',
      body: h('div.col',
        h('p', 'The venue switches back to version ' + v.versionId + ' (published ' + when(v.publishedAt) + (v.note ? ', "' + v.note + '"' : '') + ') at once.'),
        h('p.small.muted', 'It is published again under a new version number' + (p ? ', and ' + p.versionId + ' moves to the earlier versions' : '') + '. Every staff session ends. The draft is not changed.')),
      actions: [CANCEL, { label: 'Roll back to ' + v.versionId, kind: 'warn', icon: 'history', value: true }]
    }).then(function (ok) {
      if (ok !== true) return;
      VF.api('ROLLBACK', { versionId: v.versionId, confirm: true }, { since: false }).then(function (r) {
        if (!r.ok || !r.data) { VF.toast((r.message || 'The rollback did not happen.') + (r.detail ? ' (' + r.detail + ')' : ''), 'bad'); return; }
        VF.toast('Rolled back to ' + v.versionId + '. It is published as ' + r.data.versionId + '.', 'ok');
        Studio.reload();
      });
    });
  }

  function doDiscard() {
    var p = Studio.published;
    VF.modal({
      title: 'Discard draft changes?', icon: 'trash',
      body: h('div.col',
        h('p', p ? 'The draft is reset to what is published (' + p.versionId + '). Every change made since is lost.' : 'Nothing is published, so the whole draft is deleted and setup starts again from the wizard.'),
        h('p.small.muted', p ? 'This changes the draft only. The venue keeps running on ' + p.versionId + '.' : 'Nothing changes for the venue: it has no configuration yet.')),
      actions: [CANCEL, { label: 'Discard draft changes', kind: 'danger', value: true }]
    }).then(function (ok) {
      if (ok !== true) return;
      Studio.serverEdit('DRAFT_DISCARD', { confirm: true }).then(function (r) {
        if (!r.ok) { VF.toastReply(r); return; }
        pub.acks = {}; pub.refused = null; pub.blocking = null;
        if (Studio.published && cfg()) known = { versionId: Studio.published.versionId, revision: Studio.revision() };
        VF.toast(Studio.published ? 'The draft is what is published again.' : 'The draft was deleted.', 'ok');
        Studio.refresh();
      });
    });
  }

  function reviewPanel() {
    var list = Studio.issues();
    var errors = list.filter(isError), warnings = list.filter(function (i) { return !isError(i); });
    var lic = VF.asMap(boot().license);
    var button = h('button.btn.primary.lg', { type: 'button', onclick: doPublish }, icon('upload'), 'Publish');
    var hint = h('span.small.muted');
    var ackAll = h('button.btn.sm', { type: 'button' }, icon('check'), 'Acknowledge all warnings');
    var boxes = [];
    function gate() {
      var open = warnings.filter(function (i) { return !pub.acks[ackKey(i)]; }).length;
      var why = '';
      if (errors.length) why = 'Fix the ' + count(errors.length, 'error') + ' first.';
      else if (warnings.length > ACK_MAX) why = 'There are more warnings than one publish can acknowledge (' + ACK_MAX + '). Fix some first.';
      else if (open) why = count(open, 'warning') + ' still to tick.';
      button.disabled = pub.busy || !!why;
      VF.mount(button, icon('upload'), pub.busy ? 'Publishing' : (Studio.published ? 'Publish as a new version' : 'Publish'));
      hint.textContent = pub.busy ? 'Saving the draft, then publishing.' : (why || 'Ready. The venue switches to this configuration at once.');
      ackAll.classList.toggle('hidden', !open);
    }
    ackAll.addEventListener('click', function () {
      warnings.forEach(function (i) { pub.acks[ackKey(i)] = true; });
      boxes.forEach(function (b) { b.checked = true; });
      gate();
    });
    var warningRows = warnings.map(function (i) {
      var input = h('input', { type: 'checkbox', checked: !!pub.acks[ackKey(i)] });
      input.addEventListener('change', function () { if (input.checked) pub.acks[ackKey(i)] = true; else delete pub.acks[ackKey(i)]; gate(); });
      boxes.push(input);
      return issueRow(i, { path: true, extra: h('label.check', input, h('span', 'I have checked this')) });
    });
    var note = h('input.field', { type: 'text', maxlength: 200, value: pub.note, placeholder: 'For example: patio displays added' });
    note.addEventListener('input', function () { pub.note = note.value; });
    pub.noteEl = note;
    gate();
    return panel('Review', 'check-circle',
      errors.length ? h('span.chip.bad', count(errors.length, 'error')) : (warnings.length ? h('span.chip.warn', count(warnings.length, 'warning')) : h('span.chip.ok', 'No issues')), [
        banner('info', 'info', h('div', h('div', 'Publishing makes this draft the live configuration. The venue switches to it at once.'),
          h('div.small', 'Staff signed in with a profile that was removed, or whose PIN changed, are signed out. The version running now is kept for rollback.'))),
        lic.restricted ? banner('bad', 'shield', h('div', 'Features are restricted by the licence (' + (lic.label || 'no label') + '). Publishing and rollback need a SmartBuildOS licence. ',
          h('button.btn.sm', { type: 'button', onclick: function () { Studio.go('licensing'); } }, 'Open Licensing'))) : null,
        !list.length ? banner('ok', 'check-circle', 'The driver found nothing to fix in this draft.') : null,
        errors.length ? h('div.col.tight', h('h4', 'Errors: must be fixed'), errors.map(function (i) { return issueRow(i, { path: true }); })) : null,
        warnings.length ? h('div.col.tight', h('div.row.between.wrap', h('h4', 'Warnings: fix them, or tick each one you have checked'), ackAll), warningRows) : null,
        pub.refused ? banner('bad', 'alert', h('div', h('div', pub.refused),
          pub.blocking && pub.blocking.length ? h('ul.small.su-ul', pub.blocking.slice(0, 12).map(function (i) { return h('li', i.message || i.id); }), pub.blocking.length > 12 ? h('li', 'and ' + (pub.blocking.length - 12) + ' more') : null) : null)) : null,
        h('label.lbl', 'Note for this version (optional)', note),
        h('div.row.wrap', button, hint)
      ]);
  }

  function versionsPanel() {
    var p = Studio.published, history = VF.asList(Studio.history);
    return panel('Versions', 'history', null, [
      p ? h('div.item.sel', h('div.grow', h('div.row.tight.wrap', h('b', p.versionId), h('span.chip.ok', h('span.dot'), 'Published')), h('div.small.muted', when(p.publishedAt)), p.note ? h('div.small', p.note) : null))
        : h('div.empty', 'Not published. The venue has no configuration until you publish.'),
      history.length ? h('div.col.tight', h('h4', 'Earlier versions'), h('div.list', history.map(function (v) {
        return h('div.item', h('div.grow', h('b', v.versionId), h('div.small.muted', when(v.publishedAt) + (v.by ? ', by ' + v.by : '')), v.note ? h('div.small', v.note) : null),
          h('button.btn.sm.warn', { type: 'button', onclick: function () { doRollback(v); } }, icon('history'), 'Roll back'));
      }))) : (p ? h('p.small.muted', 'No earlier version yet. The driver keeps up to five for rollback.') : null),
      history.length ? h('p.small.muted', 'A rollback switches the venue to that version at once and ends every staff session. The driver keeps up to five earlier versions.') : null
    ]);
  }

  function draftPanel() {
    var rel = relation(), p = Studio.published;
    return panel('Draft', 'edit', relationChip(), [
      kv([
        ['Revision', String(Studio.revision())],
        draftSavedAt() ? ['Last saved', when(draftSavedAt())] : null,
        ['Compared', rel.key === 'same' ? 'No changes since ' + p.versionId + ' was published.' : (rel.key === 'unpublished' ? 'Nothing is published yet.' : rel.text)]
      ]),
      h('div.row.wrap', h('button.btn.sm.danger', { type: 'button', onclick: doDiscard }, icon('trash'), 'Discard draft changes')),
      h('p.small.muted', p ? 'Discarding resets the draft to ' + p.versionId + '.' : 'Nothing is published: discarding deletes the draft.')
    ]);
  }

  function publishPanel(embedded) {
    var c = cfg();
    return h('div.su-pub' + (embedded ? '.embedded' : ''),
      c ? reviewPanel() : h('div.empty', 'There is no draft to publish. Start one in the Setup Wizard, or restore a backup.'),
      h('div.col', versionsPanel(), c ? draftPanel() : null));
  }
  function renderPublish(container) {
    if (!cfg() && !Studio.published && !VF.asList(Studio.history).length) { Studio.emptyDraft(container); return; }
    VF.mount(container, Studio.sectionHead('Publish and Rollback', 'Review the draft, make it live, or go back to an earlier version.'), publishPanel(false));
  }
  /* A redraw that keeps what is being typed in the note. */
  function refreshKeepingNote() {
    var el = pub.noteEl, focused = el && document.activeElement === el, a = focused ? el.selectionStart : 0, b = focused ? el.selectionEnd : 0;
    Studio.refresh();
    if (focused && pub.noteEl) { try { pub.noteEl.focus(); pub.noteEl.setSelectionRange(a, b); } catch (e) { /* ignore */ } }
  }

  /* ════════════════════════════════════════════════════════════════════════
     2. Setup Wizard
     ════════════════════════════════════════════════════════════════════════ */
  var STEPS = [
    { title: 'Venue', icon: 'building' },
    { title: 'Discover Devices', icon: 'search' },
    { title: 'Map Control4 Devices', icon: 'link' },
    { title: 'Layout Design', icon: 'map' },
    { title: 'Staff Profiles', icon: 'users' },
    { title: 'Review and Publish', icon: 'upload' }
  ];
  var wiz = { step: 0, params: undefined, discover: null, discovering: false, tplType: null, tplName: '', showTemplates: false, stepper: null, issuesHost: null };
  var IFACE_LABEL = { floorplan: 'Visual Floor Plan', command: 'Command Center', room: 'Simplified Room Control', manager: 'Manager Overview' };
  var TYPE_ICON = { sports_bar: 'football', restaurant: 'utensils', corporate_office: 'building', conference_center: 'users', hotel: 'key', fitness_center: 'activity', retail: 'package', custom: 'sliders' };
  var SUBSYSTEMS = [
    { id: 'video', label: 'Video', hint: 'Displays and video routing' },
    { id: 'audio', label: 'Audio', hint: 'Audio zones, volume and mute' },
    { id: 'lighting', label: 'Lighting', hint: 'Lighting presets' },
    { id: 'shades', label: 'Shades', hint: 'Open and close' }
  ];
  var AREA_COLORS = ['#2dd4bf', '#60a5fa', '#a78bfa', '#f59e0b', '#f472b6', '#34d399', '#f87171', '#38bdf8', '#fb923c', '#e879f9', '#a3e635', '#94a3b8'];

  function stepDone(n) {
    var c = cfg(); if (!c) return false;
    var list = Studio.issues();
    function errorsOf(test) { return list.some(function (i) { return isError(i) && test(i); }); }
    if (n === 1) return has(String(c.venue.name || '').trim()) && c.floors.length > 0 && !errorsOf(isVenueIssue);
    if (n === 2) return !!(wiz.discover && wiz.discover.ok) || mapStats(c).mapped > 0;
    if (n === 3) { var m = mapStats(c); return m.total > 0 && m.unmapped === 0 && !errorsOf(isMappingIssue); }
    if (n === 4) { var l = layoutStats(c); return l.total > 0 && l.placed === l.total && !errorsOf(isLayoutIssue); }
    if (n === 5) return c.profiles.length > 0 && !errorsOf(isProfileIssue);
    return relation().key === 'same';
  }
  function setStep(n) { wiz.step = VF.clamp(n, 1, 6); Studio.refresh(); scrollTop(); }
  function paintStepper() {
    if (!wiz.stepper) return;
    var c = cfg();
    VF.mount(wiz.stepper, STEPS.map(function (s, i) {
      var n = i + 1, done = stepDone(n), cur = n === wiz.step;
      return h('button.su-step' + (done ? '.done' : '') + (cur ? '.cur' : ''), { type: 'button', disabled: !c && n > 1, 'aria-current': cur ? 'step' : null, onclick: function () { setStep(n); } },
        h('span.num', done ? icon('check', 'sm') : String(n)),
        h('span.grow', h('span.t', s.title), h('span.s', cur ? (done ? 'Current step, done' : 'Current step') : (done ? 'Done' : 'To do'))));
    }));
  }
  /* The issues that belong to the step on screen, as its own strip (redrawn after every save). */
  function paintStepIssues() {
    if (!wiz.issuesHost) return;
    var test = wiz.step === 1 ? isVenueIssue : null;
    var list = test ? Studio.issues().filter(test) : [];
    VF.mount(wiz.issuesHost, list.length ? issueRows(list, { noLink: true }) : null);
  }

  /* ── step 1: venue ───────────────────────────────────────────────────── */
  function applyTemplate(venueType, name, sample, label) {
    var hasDraft = !!cfg();
    var ask = !hasDraft ? Promise.resolve(true) : VF.modal({
      title: 'Replace the whole draft?', icon: 'alert',
      body: h('div.col',
        h('p', 'Starting from ' + label + ' replaces the WHOLE draft' + (cfg().venue.name ? ' of "' + cfg().venue.name + '"' : '') + ': its floors, areas, devices, scenes, rules, room panels and staff profiles (with their PINs) are removed from the draft.'),
        banner('info', 'info', Studio.published ? 'The venue keeps running on ' + Studio.published.versionId + ' until you publish. A backup of the current draft can be made first in Configuration Backup.' : 'Nothing is published, so nothing changes for the venue.')),
      actions: [CANCEL, { label: 'Replace the draft', kind: 'danger', value: true }]
    }).then(function (v) { return v === true; });
    ask.then(function (ok) {
      if (!ok) return;
      var payload = { venueType: venueType };
      if (name) payload.name = name;
      if (sample) payload.sample = true;
      if (hasDraft) payload.confirm = true;
      Studio.serverEdit('TEMPLATE_APPLY', payload).then(function (r) {
        if (r.ok) {
          wiz.showTemplates = false; wiz.tplName = ''; pub.acks = {};
          VF.toast('The draft now holds ' + label + '.', 'ok');
          if (onSection('wizard')) { wiz.step = 1; Studio.refresh(); scrollTop(); }
        } else if (r.errorCode === 'VF_CONFIRM_REQUIRED') VF.toast('A draft exists now (made in another window). Nothing was replaced.', 'warn');
        else VF.toast((r.message || 'The template was not applied.') + (r.detail ? ' (' + r.detail + ')' : ''), 'bad');
      });
    });
  }

  function templateChooser() {
    var s = schema(), types = VF.asList(s.venueTypes), sceneName = {}, roleName = {};
    VF.asList(s.sceneTemplates).forEach(function (x) { if (x && x.template) sceneName[x.template] = x.name; });
    VF.asList(s.profileTemplates).forEach(function (x) { if (x && x.role) roleName[x.role] = x.name; });
    var cards = [], start = h('button.btn.primary', { type: 'button' }, icon('zap'), 'Start from this template');
    function chosen() { return VF.byId(types, wiz.tplType); }
    function paint() {
      cards.forEach(function (x) { x.el.classList.toggle('sel', x.id === wiz.tplType); x.el.setAttribute('aria-pressed', x.id === wiz.tplType ? 'true' : 'false'); });
      start.disabled = !chosen();
    }
    function line(label, list, names) { return h('div.small', h('span.muted', label + ': '), VF.asList(list).map(function (k) { return (names && names[k]) || words(k); }).join(', ') || 'none'); }
    var grid = h('div.su-types', types.map(function (t) {
      var el = h('button.su-type', { type: 'button', onclick: function () { wiz.tplType = t.id; paint(); } },
        h('div.row.tight', icon(TYPE_ICON[t.id] || 'building', 'lg'), h('h3', t.label)),
        line('Areas', t.areas), line('Scenes', t.scenes, sceneName), line('Profiles', t.profiles, roleName));
      cards.push({ id: t.id, el: el });
      return el;
    }));
    var name = h('input.field', { type: 'text', maxlength: 80, value: wiz.tplName, placeholder: 'For example: Riverside Sports Bar' });
    name.addEventListener('input', function () { wiz.tplName = name.value; });
    start.addEventListener('click', function () { var t = chosen(); if (t) applyTemplate(t.id, wiz.tplName.trim(), false, 'the ' + t.label + ' template'); });
    paint();
    return h('div.col',
      h('p.muted', 'Pick the business type. Its template brings one floor with these areas, scenes and staff profiles; devices are added in the next steps and everything can be changed later.'),
      grid,
      h('div.su-start', h('label.lbl.grow', 'Venue name', name), start),
      isSim() ? h('div.card.col.tight',
        h('div.row.tight', h('span.chip.warn', 'Simulation mode only'), h('span.small.muted', 'Complete sample venues with invented Control4 ids, for trying VenueFlow without a project.')),
        h('div.row.wrap',
          h('button.btn.sm.outline', { type: 'button', onclick: function () { applyTemplate('sports_bar', '', true, 'the sample sports bar'); } }, icon('football'), 'Load the sample sports bar'),
          h('button.btn.sm.outline', { type: 'button', onclick: function () { applyTemplate('conference_center', '', true, 'the sample conference centre'); } }, icon('users'), 'Load the sample conference centre'))) : null);
  }

  /* A rectangle for a new area that does not cover another area of that floor. */
  function freeSpot(c, floorId, skipId) {
    var f = VF.byId(c.floors, floorId) || {};
    var W = Number(f.width) || 1200, H = Number(f.height) || 800, g = Math.max(5, Number(f.grid) || 20);
    function snap(n) { return Math.max(g, Math.round(n / g) * g); }
    var m = snap(Math.min(40, Math.min(W, H) / 10)), gap = g;
    var w = snap(Math.min(260, Math.max(g * 3, (W - 2 * m - gap) / 2))), hh = snap(Math.min(200, Math.max(g * 3, (H - 2 * m - gap) / 2)));
    var taken = c.areas.filter(function (a) { return a.floorId === floorId && a.id !== skipId && a.layout && typeof a.layout.x === 'number' && typeof a.layout.y === 'number'; }).map(function (a) { return a.layout; });
    for (var y = m; y + hh <= H - m; y += hh + gap) {
      for (var x = m; x + w <= W - m; x += w + gap) {
        var hit = false;
        for (var i = 0; i < taken.length && !hit; i++) { var t = taken[i]; hit = x < t.x + (t.w || 0) && x + w > t.x && y < t.y + (t.h || 0) && y + hh > t.y; }
        if (!hit) return { x: x, y: y, w: w, h: hh };
      }
    }
    var n = taken.length % 8;   /* the floor is full: step down the diagonal so it is at least visible */
    return { x: m + n * g, y: m + n * g, w: w, h: hh };
  }
  function freshName(list, base) { var n = list.length + 1, names = list.map(function (x) { return x.name; }); while (names.indexOf(base + ' ' + n) >= 0) n++; return base + ' ' + n; }
  function limitOf(field, fallback) { var l = VF.asMap(schema().limits)[field]; return typeof l === 'number' ? l : fallback; }
  function mirrorFloorName(id, name) {
    var nodes = document.querySelectorAll('[data-su-floor]');
    for (var i = 0; i < nodes.length; i++) if (nodes[i].dataset.suFloor === id) nodes[i].textContent = name || '(no name)';
  }

  function venuePanel(c) {
    var s = schema(), type = VF.byId(VF.asList(s.venueTypes), c.venue.type);
    var ifaces = VF.asList(s.interfaces).map(function (i) { return { value: i, label: IFACE_LABEL[i] || words(i) }; });
    return panel('Venue', 'building', h('span.chip', (type && type.label) || words(c.venue.type)), [
      h('div.form',
        Studio.text('Venue name', c.venue.name, function (v) { Studio.update('Venue name', function (x) { x.venue.name = v; }, { silent: true }); }, { hint: 'Shown at the top of every screen.' }),
        Studio.select('Default interface', ifaces, c.venue.defaultInterface, function (v) { if (v) Studio.update('Default interface', function (x) { x.venue.defaultInterface = v; }); }, { hint: 'What a screen opens with when a profile has no interface of its own.' })),
      h('div.col.tight', h('h4', 'Subsystems'), h('div.su-toggles', SUBSYSTEMS.map(function (k) {
        return Studio.toggle(k.label, c.venue.subsystems[k.id] === true, function (on) { Studio.update('Subsystem ' + k.label, function (x) { x.venue.subsystems[k.id] = on; }); }, k.hint);
      })))
    ]);
  }

  function floorsPanel(c) {
    var limit = limitOf('floors', 12);
    function sizeField(f, key) {
      var lbl = Studio.number('', f[key], function (n) {
        var input = lbl.querySelector('input');
        if (n === undefined) { input.value = f[key]; return; }
        input.value = n;
        Studio.update('Floor ' + key, function (x) { var t = VF.byId(x.floors, f.id); if (t) t[key] = n; }, { silent: true });
      }, { min: 100, max: 20000 });
      return bare(lbl, 'Floor ' + key + ' of ' + f.name);
    }
    var grid = h('div.su-table.su-floors', h('span.su-colhead', 'Name'), h('span.su-colhead', 'Width'), h('span.su-colhead', 'Height'), h('span'));
    c.floors.forEach(function (f) {
      var areas = c.areas.filter(function (a) { return a.floorId === f.id; }).length, displays = c.displays.filter(function (d) { return d.floorId === f.id; }).length;
      grid.appendChild(h('div.col.tight',
        bare(Studio.text('', f.name, function (v) { Studio.update('Rename floor', function (x) { var t = VF.byId(x.floors, f.id); if (t) t.name = v; }, { silent: true }); mirrorFloorName(f.id, v); }), 'Floor name'),
        h('span.hint', count(areas, 'area') + ', ' + count(displays, 'display') + (f.image ? ', floor plan picture' : ''))));
      grid.appendChild(sizeField(f, 'width'));
      grid.appendChild(sizeField(f, 'height'));
      grid.appendChild(h('button.btn.icon.ghost', { type: 'button', title: 'Delete floor', 'aria-label': 'Delete floor ' + f.name, onclick: function () { Studio.confirmRemove('floor', f.id, 'floor'); } }, icon('trash')));
    });
    return panel('Floors', 'layers', h('button.btn.sm', { type: 'button', disabled: c.floors.length >= limit, title: c.floors.length >= limit ? 'The limit is ' + limit + ' floors' : null, onclick: function () {
      Studio.update('Add floor', function (x) { var name = freshName(x.floors, 'Floor'); x.floors.push({ id: VF.freshId(name, x.floors), name: name, width: 1200, height: 800, grid: 20 }); });
    } }, icon('plus'), 'Add floor'), [
      c.floors.length ? grid : h('div.empty', 'No floor yet. A venue needs at least one.'),
      h('p.small.muted', 'Width and height are the floor plan canvas, in units from 100 to 20000. Deleting a floor also removes its areas and displays from the draft.')
    ]);
  }

  function pickColour(area) {
    var closer = null, current = /^#[0-9a-f]{6}$/i.test(area.color || '') ? area.color : AREA_COLORS[0];
    var custom = h('input.su-colorinput', { type: 'color', value: current, 'aria-label': 'Any colour' });
    VF.modal({
      title: 'Colour of ' + (area.name || 'area'), icon: 'palette',
      body: h('div.col', h('div.su-swatches', AREA_COLORS.map(function (col) {
        return h('button.su-swatch' + (col === area.color ? '.on' : ''), { type: 'button', style: { background: col }, 'aria-label': 'Colour ' + col, onclick: function () { if (closer) closer(col); } });
      })), h('label.lbl', 'Or a custom colour', custom)),
      actions: [CANCEL, { label: 'Use this custom colour', kind: 'primary', value: function () { return custom.value; } }],
      onOpen: function (close) { closer = close; }
    }).then(function (col) {
      if (typeof col !== 'string' || !/^#[0-9a-f]{6}$/i.test(col) || col === area.color) return;
      Studio.update('Area colour', function (x) { var t = VF.byId(x.areas, area.id); if (t) t.color = col; });
    });
  }

  function moveArea(areaId, floorId) {
    var c = cfg(), a = VF.byId(c.areas, areaId), floor = VF.byId(c.floors, floorId);
    if (!a || !floor || a.floorId === floorId) { Studio.refresh(); return; }
    var displays = c.displays.filter(function (d) { return d.areaId === areaId; }).length;
    function apply() {
      Studio.update('Move area', function (x) {
        var t = VF.byId(x.areas, areaId); if (!t) return;
        t.floorId = floorId; t.layout = freeSpot(x, floorId, areaId);
        /* a display must be on its area's floor (the driver refuses a mismatch) */
        x.displays.forEach(function (d) { if (d.areaId === areaId) d.floorId = floorId; });
        x.audioZones.forEach(function (z) { if (z.areaId === areaId && has(z.floorId)) z.floorId = floorId; });
      });
    }
    if (!displays) { apply(); return; }
    ask('Move ' + (a.name || 'area') + ' to ' + (floor.name || 'that floor') + '?', 'Its ' + count(displays, 'display') + ' move to that floor with it. Their positions on the plan are kept: check them in the Layout Designer.', 'Move area')
      .then(function (ok) { if (ok) apply(); else Studio.refresh(); });
  }

  function areasPanel(c) {
    var limit = limitOf('areas', 64), full = c.areas.length >= limit;
    var floorOptions = c.floors.map(function (f) { return { value: f.id, label: f.name || '(no name)' }; });
    function addArea(floorId) {
      Studio.update('Add area', function (x) {
        var name = freshName(x.areas, 'Area');
        x.areas.push({ id: VF.freshId(name, x.areas), name: name, floorId: floorId, color: AREA_COLORS[x.areas.length % AREA_COLORS.length], layout: freeSpot(x, floorId) });
      });
    }
    function rows(list, orphan) {
      var grid = h('div.su-table.su-areas');
      list.forEach(function (a) {
        var colour = /^#[0-9a-f]{3,8}$/i.test(a.color || '') ? a.color : '#64748b';
        var sel = Studio.select('', floorOptions, orphan ? '' : a.floorId, function (v) { moveArea(a.id, v); }, orphan ? { none: 'Choose a floor' } : null);
        var opts = sel.querySelectorAll('option');
        for (var i = 0; i < opts.length; i++) if (opts[i].value) opts[i].dataset.suFloor = opts[i].value;
        grid.appendChild(h('button.su-swatchbtn', { type: 'button', title: 'Change colour', 'aria-label': 'Colour of ' + a.name, onclick: function () { pickColour(a); } }, h('span', { style: { background: colour } })));
        grid.appendChild(bare(Studio.text('', a.name, function (v) { Studio.update('Rename area', function (x) { var t = VF.byId(x.areas, a.id); if (t) t.name = v; }, { silent: true }); }), 'Area name'));
        grid.appendChild(bare(sel, 'Floor of ' + a.name));
        grid.appendChild(h('button.btn.icon.ghost', { type: 'button', title: 'Delete area', 'aria-label': 'Delete area ' + a.name, onclick: function () { Studio.confirmRemove('area', a.id, 'area'); } }, icon('trash')));
      });
      return grid;
    }
    var groups = c.floors.map(function (f) {
      var list = c.areas.filter(function (a) { return a.floorId === f.id; });
      return h('div.col.tight',
        h('div.row.between', h('h3', { dataset: { suFloor: f.id } }, f.name || '(no name)'),
          h('button.btn.sm', { type: 'button', disabled: full, title: full ? 'The limit is ' + limit + ' areas' : null, onclick: function () { addArea(f.id); } }, icon('plus'), 'Add area')),
        list.length ? rows(list, false) : h('p.small.muted', 'No area on this floor yet.'));
    });
    var orphans = c.areas.filter(function (a) { return !VF.byId(c.floors, a.floorId); });
    return panel('Areas', 'grid', h('span.chip', c.areas.length + ' of ' + limit), [
      c.floors.length ? groups : h('div.empty', 'Add a floor first: every area is on a floor.'),
      orphans.length ? h('div.col.tight', h('h3', 'Not on a floor'), rows(orphans, true)) : null,
      h('p.small.muted', 'A new area is put in a free spot on its floor plan, or on top of the others when the floor is full. Move and resize it in the Layout Designer. Deleting an area leaves its displays in the draft, without an area.')
    ]);
  }

  function stepVenue(body, c) {
    if (!c) {
      VF.append(body, panel('Start a new venue', 'zap', null, [templateChooser()]));
      return;
    }
    wiz.issuesHost = h('div');
    VF.append(body, [wiz.issuesHost, venuePanel(c), floorsPanel(c), areasPanel(c),
      panel('Start again from a template', 'zap', h('button.btn.sm.ghost', { type: 'button', 'aria-expanded': wiz.showTemplates ? 'true' : 'false', onclick: function () { wiz.showTemplates = !wiz.showTemplates; Studio.refresh(); } }, icon(wiz.showTemplates ? 'chevron-up' : 'chevron-down'), wiz.showTemplates ? 'Hide' : 'Show templates'),
        wiz.showTemplates ? [banner('warn', 'alert', 'A template replaces the WHOLE draft. You are asked to confirm before anything is replaced.'), templateChooser()]
          : [h('p.small.muted', 'This draft started as ' + ((VF.byId(VF.asList(schema().venueTypes), c.venue.type) || {}).label || words(c.venue.type)) + '. Another template, or a sample venue in Simulation mode, replaces the whole draft.')])]);
    paintStepIssues();
  }

  /* ── step 2: discover ────────────────────────────────────────────────── */
  var CATEGORY_ORDER = ['room', 'display', 'projector', 'video_switch', 'av_over_ip', 'source', 'audio', 'amplifier', 'light', 'lighting_scene', 'shade', 'other'];
  var CATEGORY_LABEL = { room: 'Rooms', display: 'Displays', projector: 'Projectors', video_switch: 'Video switches', av_over_ip: 'AV over IP', source: 'Sources', audio: 'Audio', amplifier: 'Amplifiers', light: 'Lights', lighting_scene: 'Lighting scenes', shade: 'Shades', other: 'Other devices' };
  var CAP_LABEL = { readable: 'Readable', power: 'Power', volume: 'Volume', mute: 'Mute', video: 'Video', audio: 'Audio', linkState: 'Link state' };
  function basisLabel(b) {
    if (b === 'adapter') return isSim() ? 'the simulated project' : 'the Control4 project';
    if (b === 'proxy') return 'its proxy type';
    if (b === 'driver file name') return 'its driver file name';
    if (b === 'none') return 'nothing (not recognised)';
    return String(b || 'not stated');
  }
  function runDiscover() {
    if (wiz.discovering) return;
    wiz.discovering = true; Studio.refresh();
    VF.api('DISCOVER', {}, { since: false }).then(function (r) {
      wiz.discovering = false;
      wiz.discover = { at: Math.floor(Date.now() / 1000), ok: r.ok === true, message: r.message, detail: r.detail, data: VF.asMap(r.data) };
      if (onSection('wizard')) Studio.refresh();
    });
  }
  /* Control4 id -> what the draft already uses it for. */
  function usage(c) {
    var rooms = {}, devices = {};
    function add(map, id, text) { if (!has(id)) return; var l = map[id] = map[id] || []; if (l.indexOf(text) < 0) l.push(text); }
    if (c) {
      c.displays.forEach(function (d) { add(rooms, d.c4RoomId, 'Display ' + d.name); add(devices, d.c4DeviceId, 'Display ' + d.name); var cmd = VF.asMap(d.route).command; if (cmd) add(devices, cmd.deviceId, 'Route of ' + d.name); });
      c.audioZones.forEach(function (z) { add(rooms, z.c4RoomId, 'Audio zone ' + z.name); });
      c.sources.forEach(function (s) { add(devices, s.c4DeviceId, 'Source ' + s.name); });
      c.lighting.forEach(function (l) { l.presets.forEach(function (p) { add(devices, p.deviceId, 'Lighting ' + l.name); }); });
      c.shades.forEach(function (s) { add(devices, s.deviceId, 'Shade ' + s.name); });
    }
    return { rooms: rooms, devices: devices };
  }
  function deviceCard(d, used) {
    var caps = VF.asMap(d.capabilities), list = (d.category === 'room' ? used.rooms : used.devices)[d.id] || [];
    var chips = Object.keys(caps).filter(function (k) { return caps[k] === true; }).map(function (k) { return h('span.chip', CAP_LABEL[k] || words(k)); });
    if (caps.readable === false) chips.push(h('span.chip.warn', 'Not readable'));
    return h('div.su-dev',
      h('div.row.tight', h('b.grow.ellipsis', d.name || 'Device ' + d.id), h('span.mono.muted', '#' + d.id),
        d.online === true ? h('span.chip.ok', h('span.dot'), 'Online') : (d.online === false ? h('span.chip.bad', h('span.dot'), 'Offline') : null)),
      h('div.small.muted', (d.room ? 'Room: ' + d.room : 'No room') + ' · Driver: ' + (d.driverFile || 'not reported')),
      h('div.small.muted', 'Classified from ' + basisLabel(d.basis)),
      chips.length ? h('div.row.wrap.tight', chips) : null,
      h('div.small', list.length ? h('span', { style: { color: 'var(--teal)' } }, 'In this draft: ' + list.slice(0, 2).join(', ') + (list.length > 2 ? ' and ' + (list.length - 2) + ' more' : '')) : h('span.muted', 'Not used in this draft')));
  }
  function stepDiscover(body, c) {
    var d = wiz.discover, data = d ? d.data : null, devices = data ? VF.asList(data.devices) : [];
    VF.append(body, [
      banner('info', 'info', h('div', h('div', 'Discovery lists the devices of the Control4 project and sorts them into categories.'),
        h('div.small', 'The category is a suggestion, taken from the proxy type or the driver file name. Any device can be mapped by hand to any role in the next step.'))),
      h('div.row.wrap',
        h('button.btn.primary', { type: 'button', disabled: wiz.discovering, onclick: runDiscover }, icon('search'), wiz.discovering ? 'Looking' : (d ? 'Discover again' : 'Discover')),
        d ? h('span.small.muted', 'Last run ' + VF.fmtTime(d.at) + ': ' + count(devices.length, 'device') + '. Kept until this page is closed.') : h('span.small.muted', 'Nothing in the Control4 project is changed by this.'))
    ]);
    if (!d) return;
    if (!d.ok) VF.append(body, banner('bad', 'alert', (d.message || 'The device list could not be read.') + (d.detail ? ' (' + d.detail + ')' : '')));
    if (!devices.length) {
      if (d.ok) VF.append(body, h('div.empty', h('p', 'The project reported no devices.'), isSim() ? h('p.small', 'In Simulation mode the simulated project is built from the published configuration: publish once and discover again.') : null));
      return;
    }
    var used = usage(c), by = {};
    devices.forEach(function (x) { (by[x.category || 'other'] = by[x.category || 'other'] || []).push(x); });
    var order = CATEGORY_ORDER.concat(Object.keys(by).filter(function (k) { return CATEGORY_ORDER.indexOf(k) < 0; }).sort());
    var present = order.filter(function (k) { return by[k]; });
    VF.append(body, h('div.row.wrap.tight', present.map(function (k) { return h('span.chip', (CATEGORY_LABEL[k] || words(k)) + ' ' + by[k].length); })));
    present.forEach(function (k) {
      VF.append(body, h('details.su-cat.panel', { open: true },
        h('summary', icon('chevron-right', 'sm'), h('h3.grow', CATEGORY_LABEL[k] || words(k)), h('span.chip', String(by[k].length))),
        h('div.su-devs', by[k].map(function (x) { return deviceCard(x, used); }))));
    });
  }

  /* ── steps 3, 4, 5: summaries that open the other sections ───────────── */
  function summaryRow(ic, title, text, chip, button) {
    return h('div.item.su-sum', icon(ic, 'lg'), h('div.grow', h('div', h('b', title)), h('div.small.muted', text)), chip || null, button || null);
  }
  function fromWizard(section, step, title) { return function () { Studio.go(section, { wizard: { step: step, title: title } }); }; }
  function partChip(p) { return !p.total ? h('span.chip', 'None yet') : (p.unmapped ? h('span.chip.warn', p.unmapped + ' not mapped') : h('span.chip.ok', 'All mapped')); }

  function stepMap(body, c) {
    var m = mapStats(c), related = Studio.issues().filter(isMappingIssue);
    VF.append(body, [
      h('p.muted', 'Tell VenueFlow which Control4 room or device each display, source and audio zone is. Mapping only records ids in the draft: nothing in the Control4 project is changed.'),
      h('div.list',
        summaryRow('tv', 'Displays', m.displays.mapped + ' mapped, ' + m.displays.unmapped + ' not mapped, of ' + m.displays.total, partChip(m.displays),
          h('button.btn.primary', { type: 'button', onclick: fromWizard('devices', 3, 'Map devices') }, 'Open device mapping', icon('arrow-right'))),
        summaryRow('route', 'Sources', m.sources.mapped + ' of ' + m.sources.total + ' mapped to a Control4 device', partChip(m.sources),
          h('button.btn', { type: 'button', onclick: fromWizard('sources', 3, 'Map devices') }, 'Open sources', icon('arrow-right'))),
        summaryRow('volume', 'Audio zones', m.zones.mapped + ' of ' + m.zones.total + ' mapped to a Control4 room', partChip(m.zones),
          h('button.btn', { type: 'button', onclick: fromWizard('zones', 3, 'Map devices') }, 'Open audio zones', icon('arrow-right')))),
      h('div.col.tight', h('h4', 'Issues that concern mapping'),
        related.length ? issueRows(related, null, 12) : h('p.small.muted', 'None reported by the driver.'))
    ]);
  }

  function stepLayout(body, c) {
    var l = layoutStats(c), related = Studio.issues().filter(isLayoutIssue);
    VF.append(body, [
      h('p.muted', 'Place the displays, areas, labels and scene buttons on each floor plan. Moving an icon never changes what it is mapped to.'),
      h('div.list', summaryRow('map', 'Displays on a floor plan', l.placed + ' of ' + l.total + ' placed' + (l.hidden ? ', ' + l.hidden + ' of them hidden' : ''),
        !l.total ? h('span.chip', 'None yet') : (l.placed === l.total ? h('span.chip.ok', 'All placed') : h('span.chip.warn', (l.total - l.placed) + ' not placed')),
        h('button.btn.primary', { type: 'button', onclick: fromWizard('layout', 4, 'Layout design') }, 'Open Layout Designer', icon('arrow-right')))),
      c.floors.length ? h('div.col.tight', h('h4', 'By floor'), h('div.list', c.floors.map(function (f) {
        var on = c.displays.filter(function (d) { return d.floorId === f.id; }), put = on.filter(function (d) { return placed(c, d); }).length;
        return h('div.item', icon('layers'), h('div.grow', h('div', f.name || '(no name)'), h('div.small.muted', f.width + ' by ' + f.height + ' units, ' + count(c.areas.filter(function (a) { return a.floorId === f.id; }).length, 'area') + (f.image ? ', floor plan picture set' : ', no floor plan picture'))),
          h('span.chip' + (on.length && put === on.length ? '.ok' : (on.length ? '.warn' : '')), put + ' of ' + on.length + ' displays placed'));
      }))) : null,
      related.length ? h('div.col.tight', h('h4', 'Layout issues'), issueRows(related, null, 12)) : null
    ]);
  }

  function stepProfiles(body, c) {
    var related = Studio.issues().filter(isProfileIssue), opens = VF.byId(c.profiles, c.defaultProfileId);
    VF.append(body, [
      h('p.muted', 'A staff profile decides which interfaces a person sees and what they may control. A profile with a PIN is opened from the sign-in pad.'),
      banner(opens ? 'info' : 'warn', 'monitor', opens ? 'A Navigator tile opens as ' + opens.name + ', without a PIN.' : (has(c.defaultProfileId) ? 'The profile a tile opens with no longer exists.' : 'No profile is chosen for the tile: every screen starts at the sign-in pad.')),
      c.profiles.length ? h('div.list', c.profiles.map(function (p) {
        var mine = related.filter(function (i) { return i.entity && i.entity.id === p.id; });
        var errs = mine.filter(isError).length;
        return h('div.item.su-sum', icon('user', 'lg'),
          h('div.grow', h('div.row.tight.wrap', h('b', p.name || '(no name)'), h('span.chip', words(p.role)), c.defaultProfileId === p.id ? h('span.chip.teal', 'Tile opens with this') : null),
            h('div.small.muted', 'Interfaces: ' + (VF.asList(p.interfaces).map(function (i) { return (IFACE_LABEL[i] || words(i)) + (i === p.defaultInterface ? ' (opens first)' : ''); }).join(', ') || 'none'))),
          mine.length ? h('span.chip.' + (errs ? 'bad' : 'warn'), { title: mine.map(function (i) { return i.message; }).join('\n') }, icon('alert', 'sm'), String(mine.length)) : null,
          p.hasPin ? h('span.chip.ok', icon('lock', 'sm'), 'PIN set') : h('span.chip', 'No PIN'));
      })) : h('div.empty', 'No staff profile yet. A venue needs at least one.'),
      h('div.row.wrap', h('button.btn.primary', { type: 'button', onclick: fromWizard('profiles', 5, 'Staff profiles') }, 'Open Staff Profiles', icon('arrow-right'))),
      h('div.col.tight', h('h4', 'Issues that concern profiles'), related.length ? issueRows(related, null, 12) : h('p.small.muted', 'None reported by the driver.'))
    ]);
  }

  var STEP_BODY = [stepVenue, stepDiscover, stepMap, stepLayout, stepProfiles, function (body) { VF.append(body, publishPanel(true)); }];

  function renderWizard(container, params) {
    var c = cfg();
    if (params !== wiz.params) { wiz.params = params; if (params && params.step) wiz.step = VF.clamp(Math.round(Number(params.step)) || 1, 1, 6); }
    if (!c) wiz.step = 1;
    else if (!wiz.step) { wiz.step = 6; for (var n = 1; n <= 6; n++) if (!stepDone(n)) { wiz.step = n; break; } }
    var step = STEPS[wiz.step - 1], body = h('div.col');
    wiz.issuesHost = null;
    wiz.stepper = h('nav.su-stepper', { 'aria-label': 'Setup steps' });
    STEP_BODY[wiz.step - 1](body, c);
    var foot = h('div.su-wizfoot.panel',
      h('button.btn', { type: 'button', disabled: wiz.step === 1, onclick: function () { setStep(wiz.step - 1); } }, icon('arrow-left'), 'Back'),
      h('span.grow'),
      h('button.btn', { type: 'button', disabled: !c, onclick: function () {
        settleDraft().then(function (ok) { VF.toast(ok ? 'Draft saved on the controller, revision ' + Studio.revision() + '.' : 'The draft is not saved yet. See the indicator at the top.', ok ? 'ok' : 'warn'); });
      } }, icon('save'), 'Save Draft'),
      wiz.step < 6 ? h('button.btn.primary', { type: 'button', disabled: !c, onclick: function () { setStep(wiz.step + 1); } }, 'Continue', icon('arrow-right'))
        : h('button.btn', { type: 'button', onclick: function () { Studio.go('overview'); } }, 'Go to Overview', icon('arrow-right')));
    VF.mount(container,
      Studio.sectionHead('Setup Wizard', c ? 'Six steps from a template to a published venue. Any step can be opened again.' : 'This driver has no configuration yet. Start with the business type.'),
      h('div.su-wiz', wiz.stepper,
        /* With no draft there is nowhere to go and nothing to save: the template chooser is the whole step. */
        h('div.col', h('div.su-stephead', icon(step.icon, 'lg'), h('h2', 'Step ' + wiz.step + ' of 6: ' + step.title)), body, c ? foot : null)));
    paintStepper();
  }

  /* ════════════════════════════════════════════════════════════════════════
     4. Configuration Backup
     ════════════════════════════════════════════════════════════════════════ */
  /* The largest request the relay reads (protocol.lua MAX_REQUEST_BYTES, sent in the bootstrap schema). */
  var RELAY_MAX_BODY = 4 * 1024 * 1024;
  Studio.on('boot', function () { var n = Studio.boot && Studio.boot.schema && Studio.boot.schema.requestBytes; if (typeof n === 'number' && n > 0) RELAY_MAX_BODY = n; });
  var bk = { busy: false, last: null, file: null, which: 'published', restoring: false, result: null };
  function hasConfig(x) { return !!(x && typeof x === 'object' && x.config && typeof x.config === 'object' && !Array.isArray(x.config)); }
  function download(name, text) {
    var url = URL.createObjectURL(new Blob([text], { type: 'application/json' }));
    var a = h('a', { href: url, download: name, style: { display: 'none' } });
    document.body.appendChild(a); a.click();
    setTimeout(function () { if (a.parentNode) a.parentNode.removeChild(a); URL.revokeObjectURL(url); }, 4000);
  }
  function backupName(doc) {
    var src = hasConfig(doc.draft) ? doc.draft : (hasConfig(doc.published) ? doc.published : null);
    var venue = src && src.config.venue && src.config.venue.name, d = new Date();
    function two(n) { return (n < 10 ? '0' : '') + n; }
    return 'venueflow-' + VF.slug(venue || 'venue') + '-' + d.getFullYear() + '-' + two(d.getMonth() + 1) + '-' + two(d.getDate()) + '.json';
  }
  function doExport() {
    if (bk.busy) return;
    bk.busy = true; Studio.refresh();
    settleDraft().then(function (saved) {
      if (!saved) VF.toast('The latest changes on this screen are not saved yet: the backup holds the draft as last saved.', 'warn');
      return VF.api('BACKUP_EXPORT', {}, { since: false });
    }).then(function (r) {
      bk.busy = false;
      if (!r.ok || !r.data || !r.data.backup) bk.last = { error: (r.message || 'The backup could not be made.') + (r.detail ? ' (' + r.detail + ')' : '') };
      else {
        var text = JSON.stringify(r.data.backup, null, 2), name = backupName(r.data.backup);
        try { download(name, text); bk.last = { name: name, bytes: new Blob([text]).size, at: Math.floor(Date.now() / 1000) }; }
        catch (e) { bk.last = { error: 'This browser could not save the file. Open Installer Studio in a computer browser to export.' }; }
      }
      if (onSection('backup')) Studio.refresh();
    });
  }
  function readBackup(file) {
    bk.result = null;
    function done(doc, error) {
      bk.file = { name: file.name, size: file.size, doc: error ? null : doc, error: error };
      if (!error) bk.which = hasConfig(doc.published) ? 'published' : 'draft';
      if (onSection('backup')) Studio.refresh();
    }
    if (file.size > 16 * 1024 * 1024) { done(null, 'This file is too large to be a VenueFlow backup.'); return; }
    var reader = new FileReader();
    reader.onerror = function () { done(null, 'The file could not be read.'); };
    reader.onload = function () {
      var doc = null;
      try { doc = JSON.parse(String(reader.result)); } catch (e) { done(null, 'This file is not JSON, so it is not a VenueFlow backup.'); return; }
      if (!doc || typeof doc !== 'object' || doc.format !== 'venueflow-backup') { done(null, 'This file is not a VenueFlow backup.'); return; }
      if (!hasConfig(doc.published) && !hasConfig(doc.draft)) { done(null, 'This backup holds no configuration.'); return; }
      done(doc, null);
    };
    reader.readAsText(file);
  }
  function configCounts(config) {
    var parts = [['floors', 'floor'], ['areas', 'area'], ['displays', 'display'], ['sources', 'source'], ['audioZones', 'audio zone'], ['groups', 'display group'], ['scenes', 'scene'], ['rules', 'rule'], ['profiles', 'staff profile']];
    return parts.map(function (p) { return count(VF.asList(config[p[0]]).length, p[1]); }).join(', ');
  }
  /* Pictures never travel inside the restore request (the driver's JSON decoder is very slow on
     long strings): they are uploaded one by one first, and the request carries the rest. */
  function restorePayload() { return { backup: Object.assign({}, bk.file.doc, { images: {} }), which: bk.which, confirm: true }; }
  /* Uploads the backup's pictures in turn. Resolves { sent, refused: [reason], unreachable: bool }. */
  function uploadBackupPictures(doc) {
    var images = VF.asMap(doc.images), keys = Object.keys(images), out = { sent: 0, refused: [], unreachable: false };
    function next(i) {
      if (i >= keys.length) return Promise.resolve(out);
      var data = images[keys[i]];
      if (typeof data !== 'string' || !data) return next(i + 1);
      return VF.upload(data).then(function (r) {
        if (r.ok) out.sent++;
        else if (r.errorCode === 'VF_NETWORK' || r.errorCode === 'VF_UNAUTHENTICATED') { out.unreachable = true; out.message = r.message; return out; }
        else out.refused.push(r.message || 'A floor plan picture was refused.');
        return next(i + 1);
      });
    }
    return next(0);
  }
  function doRestore() {
    var f = bk.file, p = Studio.published, part = f.doc[bk.which], venue = (part.config.venue && part.config.venue.name) || 'a venue with no name';
    VF.modal({
      title: 'Restore this backup into the draft?', icon: 'upload',
      body: h('div.col',
        h('p', (cfg() ? 'The current draft is replaced by ' : 'The draft is filled with ') + 'the ' + (bk.which === 'published' ? 'published configuration' : 'draft') + ' of "' + venue + '" from ' + f.name + '.'),
        banner('info', 'info', p ? 'The venue keeps running on ' + p.versionId + '. Nothing changes for staff until you publish the restored draft.' : 'Nothing is published. The venue gets this configuration only when you publish the restored draft.')),
      actions: [CANCEL, { label: 'Restore into the draft', kind: cfg() ? 'danger' : 'primary', value: true }]
    }).then(function (ok) {
      if (ok !== true) return;
      bk.restoring = true; Studio.refresh();
      var payload = restorePayload();
      uploadBackupPictures(f.doc).then(function (up) {
        if (up.unreachable) return { ok: false, message: 'The floor plan pictures could not be sent, so nothing was restored. ' + (up.message || '') };
        return Studio.serverEdit('BACKUP_RESTORE', payload).then(function (r) { r.pictures = up; return r; });
      }).then(function (r) {
        bk.restoring = false;
        if (r.ok) {
          var lost = r.pictures && r.pictures.refused.length;
          bk.result = { ok: true, text: 'The backup of "' + venue + '" is now the draft. Review it, then publish to make it live.' + (lost ? ' ' + lost + ' floor plan picture' + (lost === 1 ? ' was' : 's were') + ' refused by the controller and left out: upload ' + (lost === 1 ? 'it' : 'them') + ' again in the Layout Designer.' : '') };
          bk.file = null; pub.acks = {};
        }
        else bk.result = { ok: false, text: (r.message || 'The backup was not restored.') + (r.detail ? ' (' + r.detail + ')' : '') };
        if (onSection('backup')) Studio.refresh();
      });
    });
  }
  function renderBackup(container) {
    var c = cfg(), p = Studio.published, f = bk.file;
    var picker = h('input', { type: 'file', accept: '.json,application/json', class: 'hidden', 'aria-hidden': 'true', tabindex: '-1' });
    picker.addEventListener('change', function () { if (picker.files && picker.files[0]) readBackup(picker.files[0]); });

    var exportPanel = panel('Export', 'download', null, [
      h('p.muted', 'Saves the draft, the published version and the floor plan pictures as one .json file, named after the venue and today\'s date.'),
      h('div.row.wrap', h('button.btn.primary', { type: 'button', disabled: bk.busy || (!c && !p), onclick: doExport }, icon('download'), bk.busy ? 'Preparing' : 'Export backup'),
        !c && !p ? h('span.small.muted', 'There is nothing to export yet.') : null),
      bk.last ? (bk.last.error ? banner('bad', 'alert', bk.last.error)
        : banner('ok', 'check-circle', h('div', h('div', 'The driver made the backup and this browser was given ', h('b', bk.last.name), ' (' + kb(bk.last.bytes) + ') at ' + VF.fmtTime(bk.last.at) + '.'), h('div.small', 'Check the downloads folder. A touch screen cannot save files: export from a computer browser.')))) : null
    ]);

    var summary = null;
    if (f && f.error) summary = banner('bad', 'alert', h('div', h('b', f.name), ': ' + f.error));
    else if (f) {
      var doc = f.doc, images = Object.keys(VF.asMap(doc.images)).length, mine = schema().version;
      var bytes = new Blob([JSON.stringify({ requestId: 'r0000000000-000', command: 'BACKUP_RESTORE', payload: restorePayload(), ts: 1700000000, session: VF.session.get() })]).size;
      var tooBig = bytes > RELAY_MAX_BODY;
      var choices = [['published', 'The published configuration' + (doc.published && doc.published.versionId ? ' (' + doc.published.versionId + (doc.published.publishedAt ? ', ' + VF.fmtDateTime(doc.published.publishedAt) : '') + ')' : '')], ['draft', 'The draft that was being edited']]
        .filter(function (ch) { return hasConfig(doc[ch[0]]); });
      summary = h('div.col',
        h('h4', 'What this file holds'),
        kv([
          ['File', f.name + ' (' + kb(f.size) + ')'],
          ['Exported', doc.exportedAt ? when(doc.exportedAt) : 'Not recorded'],
          ['Schema', 'Version ' + (has(doc.schema) ? doc.schema : 'not recorded') + (has(mine) ? ' (this driver uses version ' + mine + ')' : '') + ', backup format ' + (has(doc.version) ? doc.version : 'not recorded')],
          ['Floor plan pictures', String(images)]
        ]),
        h('div.col.tight', choices.map(function (ch) {
          var cfgOf = doc[ch[0]].config, venue = VF.asMap(cfgOf.venue);
          var radio = h('input', { type: 'radio', name: 'su-which', checked: bk.which === ch[0], disabled: choices.length < 2 });
          radio.addEventListener('change', function () { if (radio.checked) { bk.which = ch[0]; Studio.refresh(); } });
          return h('label.item.su-choice' + (bk.which === ch[0] ? '.sel' : ''), radio, h('div.grow', h('div', h('b', ch[1])), h('div', (venue.name || '(no name)') + ', ' + words(venue.type || 'custom')), h('div.small.muted', configCounts(cfgOf))));
        })),
        tooBig ? banner('bad', 'alert', 'This backup is ' + kb(bytes) + ' as a request. The controller reads requests up to ' + kb(RELAY_MAX_BODY) + ', so it cannot be restored from this screen. The floor plan pictures are the large part.') : null,
        h('div.row.wrap', h('button.btn.primary', { type: 'button', disabled: tooBig || bk.restoring, onclick: doRestore }, icon('upload'), bk.restoring ? 'Restoring' : 'Restore into the draft'),
          h('button.btn.ghost', { type: 'button', onclick: function () { bk.file = null; Studio.refresh(); } }, 'Forget this file')));
    }
    var restorePanel = panel('Restore', 'upload', null, [
      banner('info', 'info', h('div', h('div', 'A restore fills the DRAFT only.'), h('div.small', p ? 'The venue keeps running on ' + p.versionId + ' until you publish the restored draft.' : 'The venue gets the configuration only when you publish the restored draft.'))),
      picker,
      h('div.row.wrap', h('button.btn', { type: 'button', onclick: function () { picker.value = ''; picker.click(); } }, icon('upload'), f ? 'Choose another file' : 'Choose a backup file'), !f ? h('span.small.muted', 'A .json file exported from VenueFlow.') : null),
      bk.result ? banner(bk.result.ok ? 'ok' : 'bad', bk.result.ok ? 'check-circle' : 'alert', h('div', h('div', bk.result.text),
        bk.result.ok ? h('div.row.wrap', { style: { marginTop: '8px' } }, h('button.btn.sm.primary', { type: 'button', onclick: function () { Studio.go('publish'); } }, 'Review and publish'), h('button.btn.sm', { type: 'button', onclick: function () { Studio.go('overview'); } }, 'Open Overview')) : null)) : null,
      summary
    ]);

    var about = panel('What a backup holds', 'shield', null, [
      h('div.su-two',
        h('div.col.tight', h('h4', 'Contains'), h('ul.su-ul', h('li', 'The configuration: the draft and the published version'), h('li', 'The floor plan pictures they use'), h('li', 'Staff PIN hashes, so a restore keeps the PINs'))),
        h('div.col.tight', h('h4', 'Never contains'), h('ul.su-ul', h('li', 'The Installer Passcode'), h('li', 'Sessions: nobody is signed in by a restore'), h('li', 'Earlier versions kept for rollback')))),
      banner('warn', 'lock', 'Keep the file private. It describes the venue\'s system and holds PIN hashes.')
    ]);

    VF.mount(container, Studio.sectionHead('Configuration Backup', 'Export the configuration to a file, or restore one into the draft.'),
      h('div.col', h('div.su-two', exportPanel, restorePanel), about));
  }

  /* ════════════════════════════════════════════════════════════════════════
     5. Licensing
     ════════════════════════════════════════════════════════════════════════ */
  var lic = { data: null, at: 0, busy: false, error: null, fresh: false, host: null };
  function licenseFetch(command) {
    if (lic.busy) return;
    lic.busy = true; lic.error = null; paintLicense();
    VF.api(command, {}, { since: false }).then(function (r) {
      lic.busy = false; lic.fresh = true;
      if (r.ok && r.data && r.data.license) { lic.data = r.data.license; lic.at = Math.floor(Date.now() / 1000); if (command === 'LICENSE_REFRESH') VF.toast('Licence checked again.', 'ok'); }
      else lic.error = (r.message || 'The licence state could not be read.') + (r.detail ? ' (' + r.detail + ')' : '');
      paintLicense();
    });
  }
  function paintLicense() {
    if (!lic.host || !lic.host.isConnected && !onSection('licensing')) return;
    var l = VF.asMap(lic.data || boot().license), policy = VF.asMap(l.policy);
    var LABELS = { status: 'Status code', source: 'Source', tier: 'Tier', company: 'Company', agent: 'Agent' };
    var other = Object.keys(l).filter(function (k) { return k !== 'label' && k !== 'restricted' && k !== 'policy'; }).sort();
    VF.mount(lic.host,
      Studio.sectionHead('Licensing', 'What the SmartBuildOS Agent reports for this driver.', [
        h('button.btn.sm', { type: 'button', disabled: lic.busy, onclick: function () { licenseFetch('LICENSE_REFRESH'); } }, icon('refresh'), lic.busy ? 'Checking' : 'Check again')]),
      h('div.col',
        lic.error ? banner('bad', 'alert', lic.error) : null,
        h('div.su-two',
          panel('Status', 'shield', l.restricted ? h('span.chip.bad', h('span.dot'), 'Features restricted') : h('span.chip.ok', h('span.dot'), 'Nothing restricted'), [
            h('div.su-big', l.label || 'Not reported'),
            l.restricted ? banner('bad', 'alert', 'Scenes, rules, schedules, publishing and rollback are off until the licence is in order. Manual control keeps working.')
              : h('p.muted', 'Every feature is available.'),
            other.length ? kv(other.map(function (k) { var v = l[k]; return [LABELS[k] || words(k), v !== null && typeof v === 'object' ? JSON.stringify(v) : String(v)]; })) : null,
            h('p.small.muted', lic.at ? 'Read from the driver at ' + VF.fmtTime(lic.at) + '.' : 'As loaded with this page. Reading it again now.')
          ]),
          panel('Licence policy', 'info', null, [
            kv([
              ['Always works', policy.always || 'Not stated by the driver'],
              ['Needs a licence', policy.licensed || 'Not stated by the driver']
            ]),
            policy.note ? banner('info', 'info', policy.note) : null
          ]))));
  }
  function renderLicensing(container) {
    lic.host = container;
    paintLicense();
    if (!lic.fresh && !lic.busy) licenseFetch('LICENSE_GET');
  }

  /* ════════════════════════════════════════════════════════════════════════
     6. Diagnostics
     ════════════════════════════════════════════════════════════════════════ */
  var dg = { level: '', category: '', data: null, error: null, busy: false, again: null, auto: false, timer: null, open: {}, sig: null, stats: null, log: null, refreshBtn: null, faults: {}, faultsHost: null, target: '', room: '', volume: 30 };
  var LEVELS = [['', 'All levels'], ['info', 'Info, warnings and errors'], ['warning', 'Warnings and errors'], ['error', 'Errors only']];
  var LEVEL_CHIP = { error: 'bad', warning: 'warn', info: 'info', debug: '' };
  var FAULTS = [
    ['offline', 'Offline', 'Commands are refused; a device shows as offline'],
    ['silent', 'Silent', 'Commands are accepted and nothing ever changes'],
    ['wrong', 'Wrong', 'The room switches to another source than the one asked'],
    ['slow', 'Slow', 'Feedback arrives much later than normal']
  ];
  function stamp(epoch) {
    if (!epoch) return '';
    var d = new Date(epoch * 1000), now = new Date();
    var t = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    return d.toDateString() === now.toDateString() ? t : d.toLocaleDateString([], { month: 'short', day: 'numeric' }) + ' ' + t;
  }
  function diagFetch(force) {
    /* One read at a time. A request made meanwhile (a filter changed) runs right after, with the filters as they are then. */
    if (dg.busy) { if (force) dg.again = 'force'; return Promise.resolve(); }
    var p = { limit: 400 };
    if (dg.level) p.level = dg.level;
    if (dg.category) p.category = dg.category;
    dg.busy = true; paintDiagBusy();
    return VF.api('DIAG_GET', p, { since: false }).then(function (r) {
      dg.busy = false; paintDiagBusy();
      if (r.ok && r.data) { dg.data = r.data; dg.error = null; }
      else {
        dg.error = (r.message || 'The log could not be read.') + (r.detail ? ' (' + r.detail + ')' : '');
        if (r.errorCode === 'VF_UNAUTHENTICATED') stopAuto();
      }
      paintDiag(force);
      if (dg.again) { var f = dg.again === 'force'; dg.again = null; return diagFetch(f); }
    });
  }
  function stopAuto() { if (dg.timer) clearInterval(dg.timer); dg.timer = null; }
  function startAuto() {
    stopAuto();
    dg.timer = setInterval(function () { if (!onSection('diagnostics')) { stopAuto(); return; } if (!document.hidden) diagFetch(false); }, 3000);
  }
  function paintDiagBusy() { if (dg.refreshBtn) dg.refreshBtn.disabled = dg.busy; }
  function paintDiag(force) {
    if (!dg.log || !onSection('diagnostics')) return;
    var d = dg.data || {}, entries = VF.asList(d.entries), counts = VF.asMap(d.counts), sessions = VF.asMap(d.sessions);
    /* An automatic refresh that brought nothing new leaves the table alone (a redraw would swallow a tap in progress). */
    var sig = JSON.stringify([dg.error, dg.level, dg.category, entries.length, entries.length ? entries[0].seq : 0, d.size, counts, sessions, d.queue]);
    if (!force && sig === dg.sig) return;
    dg.sig = sig;
    VF.mount(dg.stats,
      dg.error ? banner('bad', 'alert', dg.error) : null,
      !dg.data ? null : h('div.su-stats',
        h('div.card', h('h4', 'Since the driver started'), h('div.row.wrap.tight', ['error', 'warning', 'info', 'debug'].map(function (k) { return h('span.chip' + (LEVEL_CHIP[k] && counts[k] ? '.' + LEVEL_CHIP[k] : ''), words(k) + ' ' + (counts[k] || 0)); }))),
        h('div.card', h('h4', 'Log size'), h('div', (d.size || 0) + ' of ' + (d.max || 0) + ' entries'), h('div.small.muted', 'The oldest entry is dropped when it is full.')),
        h('div.card', h('h4', 'Live sessions'), h('div', count(sessions.profile || 0, 'staff session') + ', ' + count(sessions.installer || 0, 'installer session'))),
        h('div.card', h('h4', 'Command queue'), h('div', count(d.queue || 0, 'command') + ' waiting'))));
    if (!dg.data) { VF.mount(dg.log, dg.error ? null : h('div.empty', 'Reading the log.')); return; }
    if (!entries.length) { VF.mount(dg.log, h('div.empty', dg.level || dg.category ? 'No entry matches these filters.' : 'The log is empty.')); return; }
    var body = h('tbody');
    entries.forEach(function (e) {
      var hasData = e.data !== undefined && e.data !== null && !(Array.isArray(e.data) && !e.data.length);
      var detail = null;
      var toggle = hasData ? h('button.btn.sm.ghost', { type: 'button', 'aria-expanded': dg.open[e.seq] ? 'true' : 'false', onclick: function () {
        if (dg.open[e.seq]) delete dg.open[e.seq]; else dg.open[e.seq] = true;
        detail.classList.toggle('hidden', !dg.open[e.seq]); toggle.setAttribute('aria-expanded', dg.open[e.seq] ? 'true' : 'false');
      } }, icon('code', 'sm'), 'Data') : null;
      body.appendChild(h('tr', h('td.nowrap.mono', stamp(e.at)), h('td', h('span.chip' + (LEVEL_CHIP[e.level] ? '.' + LEVEL_CHIP[e.level] : ''), words(e.level))), h('td', words(e.category || '')),
        h('td.mono', e.code || ''), h('td.msg', e.message || ''), h('td', toggle)));
      if (hasData) {
        detail = h('tr.su-data' + (dg.open[e.seq] ? '' : '.hidden'), h('td', { colspan: 6 }, h('pre.su-pre', JSON.stringify(e.data, null, 2))));
        body.appendChild(detail);
      }
    });
    VF.mount(dg.log,
      h('p.small.muted', 'Newest first: ' + count(entries.length, 'entry', 'entries') + (dg.level || dg.category ? ' matching the filters' : '') + '. Read at ' + stamp(Math.floor(Date.now() / 1000)) + '.'),
      h('div.su-logwrap.scroll', h('table.tbl.su-log', h('thead', h('tr', h('th', 'Time'), h('th', 'Level'), h('th', 'Category'), h('th', 'Code'), h('th', 'Message'), h('th', ''))), body)));
  }

  function simTargets(c) {
    var rooms = [], devices = [];
    if (c) {
      c.displays.forEach(function (d) {
        if (has(d.c4RoomId)) rooms.push({ key: 'r' + d.c4RoomId + ':' + d.id, id: Number(d.c4RoomId), label: d.name + ' (display, room ' + d.c4RoomId + ')' });
        if (has(d.c4DeviceId)) devices.push({ key: 'd' + d.c4DeviceId + ':' + d.id, id: Number(d.c4DeviceId), label: d.name + ' (display device ' + d.c4DeviceId + ')' });
      });
      c.audioZones.forEach(function (z) { if (has(z.c4RoomId)) rooms.push({ key: 'r' + z.c4RoomId + ':' + z.id, id: Number(z.c4RoomId), label: z.name + ' (audio zone, room ' + z.c4RoomId + ')' }); });
    }
    return { rooms: rooms, devices: devices };
  }
  function paintFaults() {
    if (!dg.faultsHost) return;
    var ids = Object.keys(dg.faults);
    VF.mount(dg.faultsHost, ids.length ? h('div.col.tight', h('h4', 'Faults set from this screen'), h('div.row.wrap.tight', ids.map(function (id) { return h('span.chip.warn', dg.faults[id].label + ': ' + dg.faults[id].fault); })),
      h('p.small.muted', 'The driver does not report its faults, so this lists only what was set here since the page opened.')) : null);
  }
  function simulatorPanel() {
    var c = cfg(), t = simTargets(c), all = t.rooms.concat(t.devices);
    if (!VF.byId(all.map(function (x) { return { id: x.key }; }), dg.target)) dg.target = all.length ? all[0].key : '';
    if (!VF.byId(t.rooms.map(function (x) { return { id: x.key }; }), dg.room)) dg.room = t.rooms.length ? t.rooms[0].key : '';
    function find(list, key) { for (var i = 0; i < list.length; i++) if (list[i].key === key) return list[i]; return null; }
    function options(sel, label, list, chosen) { if (!list.length) return; sel.appendChild(h('optgroup', { label: label }, list.map(function (x) { return h('option', { value: x.key, selected: x.key === chosen }, x.label); }))); }
    var targetSel = h('select.field'); options(targetSel, 'Rooms (routing, power, volume)', t.rooms, dg.target); options(targetSel, 'Display devices (link state)', t.devices, dg.target);
    targetSel.addEventListener('change', function () { dg.target = targetSel.value; });
    var roomSel = h('select.field'); options(roomSel, 'Rooms', t.rooms, dg.room);
    roomSel.addEventListener('change', function () { dg.room = roomSel.value; });
    function fault(name) {
      var x = find(all, dg.target); if (!x) { VF.toast('Choose a display or an audio zone first.', 'warn'); return; }
      var payload = { targetId: x.id }; if (name) payload.fault = name;
      VF.api('SIM_FAULT', payload, { since: false }).then(function (r) {
        if (!r.ok) { VF.toastReply(r); return; }
        if (name) dg.faults[x.id] = { fault: name, label: x.label }; else delete dg.faults[x.id];
        VF.toast(name ? 'Simulator: ' + x.label + ' is now ' + name + '.' : 'Simulator: fault cleared on ' + x.label + '.', 'ok');
        paintFaults(); diagFetch(true);
      });
    }
    function external(changes, text) {
      var x = find(t.rooms, dg.room); if (!x) { VF.toast('Choose a room first.', 'warn'); return; }
      VF.api('SIM_EXTERNAL', { roomId: x.id, changes: changes }, { since: false }).then(function (r) {
        if (!r.ok) { VF.toastReply(r); return; }
        VF.toast('Simulator: ' + text + ' in ' + x.label + ', as if from a Control4 remote.', 'ok');
      });
    }
    var vol = h('input.field', { type: 'number', min: 0, max: 100, step: 1, value: dg.volume, 'aria-label': 'Volume level' });
    vol.addEventListener('change', function () { var n = Number(vol.value); dg.volume = isNaN(n) ? 30 : VF.clamp(Math.round(n), 0, 100); vol.value = dg.volume; });
    dg.faultsHost = h('div');
    var p = panel('Simulator', 'wrench', h('span.chip.warn', 'Simulator only'), [
      banner('warn', 'info', h('div', h('div', 'These controls act on the simulated Control4 project of Simulation mode. On a real controller the driver refuses them.'),
        h('div.small', 'Rooms and devices are listed from the draft. One added since the last publish is not in the running simulator yet.'))),
      !all.length ? h('div.empty', 'No mapped display or audio zone to act on.') : h('div.su-two',
        h('div.col', h('h3', 'Set a fault'),
          h('label.lbl', 'Display or audio zone', targetSel),
          h('div.row.wrap.tight', FAULTS.map(function (f) { return h('button.btn.sm.warn', { type: 'button', onclick: function () { fault(f[0]); } }, f[1]); }),
            h('button.btn.sm', { type: 'button', onclick: function () { fault(''); } }, icon('x', 'sm'), 'Clear')),
          h('ul.small.muted.su-ul', FAULTS.map(function (f) { return h('li', h('b', f[1]), ': ' + f[2]); })),
          dg.faultsHost),
        h('div.col', h('h3', 'Change a room behind VenueFlow\'s back'),
          t.rooms.length ? [
            h('label.lbl', 'Control4 room', roomSel),
            h('div.row.wrap.tight',
              h('button.btn.sm', { type: 'button', onclick: function () { external({ power: true }, 'power turned on'); } }, icon('power', 'sm'), 'Power on'),
              h('button.btn.sm', { type: 'button', onclick: function () { external({ power: false }, 'power turned off'); } }, 'Power off'),
              h('button.btn.sm', { type: 'button', onclick: function () { external({ muted: true }, 'sound muted'); } }, icon('volume-x', 'sm'), 'Mute'),
              h('button.btn.sm', { type: 'button', onclick: function () { external({ muted: false }, 'sound unmuted'); } }, 'Unmute')),
            h('div.row.tight', h('div', { style: { width: '110px' } }, vol), h('button.btn.sm', { type: 'button', onclick: function () { external({ volume: dg.volume }, 'volume set to ' + dg.volume); } }, icon('volume', 'sm'), 'Set volume')),
            h('p.small.muted', 'As if someone used a Control4 remote. Watch the Operator view to see VenueFlow notice it.')
          ] : h('p.small.muted', 'No mapped room.')))
    ]);
    paintFaults();
    return p;
  }

  function renderDiagnostics(container) {
    var cats = VF.asList(schema().diagCategories);
    var level = h('select.field', LEVELS.map(function (l) { return h('option', { value: l[0], selected: l[0] === dg.level }, l[1]); }));
    level.addEventListener('change', function () { dg.level = level.value; diagFetch(true); });
    if (dg.category && cats.indexOf(dg.category) < 0) dg.category = '';
    var category = h('select.field', h('option', { value: '' }, 'All categories'), cats.map(function (k) { return h('option', { value: k, selected: k === dg.category }, words(k)); }));
    category.addEventListener('change', function () { dg.category = category.value; diagFetch(true); });
    dg.refreshBtn = h('button.btn.sm', { type: 'button', onclick: function () { diagFetch(true); } }, icon('refresh'), 'Refresh');
    var auto = h('button.toggle' + (dg.auto ? '.on' : ''), { type: 'button', role: 'switch', 'aria-checked': dg.auto ? 'true' : 'false', 'aria-label': 'Refresh every 3 seconds' });
    auto.addEventListener('click', function () {
      dg.auto = !dg.auto; auto.classList.toggle('on', dg.auto); auto.setAttribute('aria-checked', dg.auto ? 'true' : 'false');
      if (dg.auto) { startAuto(); diagFetch(false); } else stopAuto();
    });
    dg.stats = h('div.col'); dg.log = h('div.col.tight'); dg.sig = null;
    VF.mount(container,
      Studio.sectionHead('Diagnostics', 'What the driver logged, newest first. Nothing secret is kept in the log.', [
        h('button.btn.sm.warn', { type: 'button', onclick: function () {
          ask('End all staff sessions?', 'Every staff member who signed in with a PIN is signed out on every screen and has to enter the PIN again. Screens that open with the tile profile are not affected.', 'End all staff sessions', 'danger').then(function (ok) {
            if (!ok) return;
            VF.api('SESSIONS_REVOKE', {}, { since: false }).then(function (r) {
              if (!r.ok) { VF.toastReply(r); return; }
              VF.toast(count((r.data && r.data.revoked) || 0, 'staff session') + ' ended.', 'ok'); diagFetch(true);
            });
          });
        } }, icon('log-out'), 'End all staff sessions'),
        h('button.btn.sm.danger', { type: 'button', onclick: function () {
          ask('Clear the diagnostic log?', 'Every entry is removed from the driver. This cannot be undone.', 'Clear log', 'danger').then(function (ok) {
            if (!ok) return;
            VF.api('DIAG_CLEAR', {}, { since: false }).then(function (r) { if (!r.ok) { VF.toastReply(r); return; } dg.open = {}; VF.toast('The log was cleared.', 'ok'); diagFetch(true); });
          });
        } }, icon('trash'), 'Clear log')]),
      h('div.col',
        dg.stats,
        h('section.panel.pad.col',
          h('div.su-filters', h('label.lbl', 'Level', level), h('label.lbl', 'Category', category),
            h('div.row.tight', dg.refreshBtn, h('label.row.tight.su-auto', auto, h('span.small', 'Refresh every 3 s')))),
          dg.log),
        isSim() ? simulatorPanel() : null));
    paintDiag(true);
    if (dg.auto) startAuto();
    diagFetch(true);
  }

  /* ════════════════════════════════════════════════════════════════════════
     registration
     ════════════════════════════════════════════════════════════════════════ */
  Studio.register({ id: 'overview', title: 'Overview', icon: 'home', group: 'Setup', order: 1, render: renderOverview,
    onIssues: function () { Studio.refresh(); } });

  Studio.register({ id: 'wizard', title: 'Setup Wizard', icon: 'zap', group: 'Setup', order: 2, render: renderWizard,
    /* After a save: steps 1 and 2 hold fields in use, so only the stepper and the issue strip are redrawn there. */
    onIssues: function () { if (wiz.step <= 2) { paintStepper(); paintStepIssues(); } else refreshKeepingNote(); },
    dispose: function () { wiz.stepper = null; wiz.issuesHost = null; } });

  Studio.register({ id: 'diagnostics', title: 'Diagnostics', icon: 'activity', group: 'System', order: 2, render: renderDiagnostics,
    dispose: function () { stopAuto(); dg.stats = null; dg.log = null; dg.refreshBtn = null; dg.faultsHost = null; } });

  Studio.register({ id: 'licensing', title: 'Licensing', icon: 'shield', group: 'System', order: 3, render: renderLicensing,
    dispose: function () { lic.fresh = false; lic.host = null; } });

  Studio.register({ id: 'backup', title: 'Configuration Backup', icon: 'download', group: 'System', order: 4, render: renderBackup });

  Studio.register({ id: 'publish', title: 'Publish and Rollback', icon: 'upload', group: 'System', order: 5, render: renderPublish,
    onIssues: refreshKeepingNote,
    badge: function () { var s = Studio.summary(), n = (s.errors || 0) + (s.warnings || 0); return cfg() && n ? n : null; },
    badgeKind: function () { return Studio.summary().errors ? 'bad' : 'warn'; } });
})();
