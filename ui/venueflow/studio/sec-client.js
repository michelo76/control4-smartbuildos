/* Venue Studio: the sections only the venue's own people see (a client session:
   a staff profile that holds the Venue Studio permission, signed in with its PIN).

     home       what you can change here, and where things stand
     channels   source names and channel labels
     presets    volume presets per audio zone

   Scenes, Scheduling, Staff Profiles and Publish are the installer's sections,
   shown to a client as they are. The driver refuses a client's change to anything
   else, whatever this page sends (src/venueflow/clientscope.lua). */
(function () {
  'use strict';
  var S = Studio, h = VF.h, icon = VF.icon;

  function when(epoch) {
    if (!epoch) return '';
    try { return new Date(epoch * 1000).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' }); } catch (e) { return ''; }
  }
  function who(by) {
    if (!by) return '';
    if (by === 'installer') return 'the installer';
    var id = String(by).replace(/^profile:/, '');
    return S.nameOf('profiles', id, id);
  }
  function tile(ic, title, sub, go) {
    return h('button.item.clickable.cl-tile', { type: 'button', onclick: function () { S.go(go); } },
      icon(ic), h('div.grow', h('div.cl-tile-t', title), h('div.small.muted', sub)), icon('arrow-right', 'sm'));
  }

  /* ── home ────────────────────────────────────────────────────────────── */
  function renderHome(container) {
    var pub = S.published, c = S.config(), pending = S.pendingReason();
    var sum = S.summary();
    var schedules = c ? S.list('rules').filter(function (r) { return r.trigger && r.trigger.type === 'schedule'; }).length : 0;
    VF.mount(container,
      S.sectionHead('Your venue', 'Signed in as ' + ((S.boot && S.boot.who) || 'staff') + '. Changes are kept as a draft until you publish them.'),
      pending ? h('div.banner.warn', icon('alert'), h('div', h('b', pending.title + ' '), pending.ask + ' ' + pending.keep)) : null,
      !c ? h('div.empty', h('p', 'There is nothing to edit yet. Your installer sets the venue up first.')) :
        h('div.col',
          h('div.list',
            tile('play', 'Scenes', S.list('scenes').length + ' scene' + (S.list('scenes').length === 1 ? '' : 's') + ': what one press does', 'scenes'),
            tile('calendar', 'Scheduling', schedules + ' schedule' + (schedules === 1 ? '' : 's') + ': what happens by itself, and when', 'scheduling'),
            tile('tv', 'Channels and source names', 'What each source is called, what is on it, and favourite channels', 'channels'),
            tile('volume', 'Volume presets', 'The one-press levels in each audio zone', 'presets'),
            tile('users', 'Staff profiles', 'Who can do what, and their PINs', 'profiles'),
            tile('upload', 'Publish', sum.errors ? sum.errors + ' problem' + (sum.errors === 1 ? '' : 's') + ' to fix first' : 'Make your changes live, or go back to an earlier version', 'publish')),
          h('div.card.col',
            h('h3', 'What is live now'),
            pub ? h('div.small', 'Version ' + pub.versionId + (pub.publishedAt ? ', published ' + when(pub.publishedAt) : '') + (pub.by ? ' by ' + who(pub.by) : '') + (pub.note ? '. Note: ' + pub.note : '')) : h('div.small.muted', 'Nothing is published yet.'),
            h('p.small.muted', 'Devices, the floor plan, routing and anything else not listed above are looked after by your installer.'))));
  }

  /* ── channels and source names ───────────────────────────────────────── */
  function renderChannels(container) {
    if (!S.hasDraft()) { VF.mount(container, S.sectionHead('Channels and source names'), h('div.empty', h('p', 'There is no draft to edit.'))); return; }
    var rows = S.list('sources').map(function (src) {
      function ed(label, fn) { S.update(label, function (c) { var x = VF.byId(c.sources, src.id); if (x) fn(x); }, { silent: true }); }
      return h('div.cl-row',
        h('div.cl-row-ic', icon(VF.SOURCE_ICON[src.kind] || 'monitor')),
        S.text('Name', src.name, function (v) {
          if (!v) { VF.toast('A name is needed.', 'warn'); S.refresh(); return; }
          ed('Rename source', function (x) { x.name = v; });
        }, { max: 40 }),
        S.text('Channel label', src.channel || '', function (v) {
          ed('Channel label', function (x) { if (v) x.channel = v; else delete x.channel; });
        }, { max: 40, placeholder: 'e.g. ESPN 206' }),
        src.enabled === false ? h('span.chip', 'Off') : null);
    });
    /* Favourite channels, for the sources whose installer gave them a keypad. */
    var favs = S.list('sources').filter(function (src) { return VF.asList(src.controls).indexOf('keypad') >= 0; }).map(function (src) {
      return h('div.card.col', h('div.row.between', h('h3', src.name), h('span.small.muted', VF.asList(src.favorites).length + ' favourite' + (VF.asList(src.favorites).length === 1 ? '' : 's'))),
        S.favoritesEditor(src, function (label, fn) { S.update(label, function (c) { var x = VF.byId(c.sources, src.id); if (x) fn(x); }); }));
    });
    VF.mount(container,
      S.sectionHead('Channels and source names', 'What staff see on each source button. The channel label is a note for staff: it does not change the channel.'),
      rows.length ? h('div.panel.pad.col', rows) : h('div.empty', h('p', 'This venue has no sources yet.')),
      favs.length ? h('div.col', h('h2', 'Favourite channels'), h('p.muted', 'One press on a control screen dials the number on that box.'), favs) : null);
  }

  /* ── volume presets ──────────────────────────────────────────────────── */
  function renderPresets(container) {
    if (!S.hasDraft()) { VF.mount(container, S.sectionHead('Volume presets'), h('div.empty', h('p', 'There is no draft to edit.'))); return; }
    var zones = S.list('audioZones');
    function edZone(id, label, fn) { S.update(label, function (c) { var z = VF.byId(c.audioZones, id); if (z) { z.presets = VF.asList(z.presets); fn(z); } }); }
    var cards = zones.map(function (z) {
      var lo = typeof z.minVolume === 'number' ? z.minVolume : 0, hi = typeof z.maxVolume === 'number' ? z.maxVolume : 100;
      var presets = VF.asList(z.presets);
      return h('div.card.col',
        h('div.row.between', h('h3', z.name), h('span.small.muted', 'Allowed ' + lo + ' to ' + hi)),
        presets.length ? presets.map(function (p) {
          return h('div.cl-row',
            S.text('Name', p.name, function (v) {
              if (!v) { VF.toast('A name is needed.', 'warn'); S.refresh(); return; }
              edZone(z.id, 'Rename preset', function (x) { var q = VF.byId(x.presets, p.id); if (q) q.name = v; });
            }, { max: 24 }),
            S.number('Level', p.level, function (v) {
              edZone(z.id, 'Preset level', function (x) { var q = VF.byId(x.presets, p.id); if (q) q.level = Math.max(lo, Math.min(hi, Math.round(v))); });
            }, { min: lo, max: hi }),
            h('button.btn.sm.ghost.icon', { type: 'button', 'aria-label': 'Remove preset ' + p.name, onclick: function () {
              edZone(z.id, 'Remove preset', function (x) { x.presets = x.presets.filter(function (q) { return q.id !== p.id; }); });
            } }, icon('trash')));
        }) : h('p.small.muted', 'No presets. Staff set the volume with the slider.'),
        presets.length < 8 ? h('div', h('button.btn.sm', { type: 'button', onclick: function () {
          edZone(z.id, 'Add preset', function (x) {
            x.presets.push({ id: VF.freshId('preset', x.presets), name: 'Preset ' + (x.presets.length + 1), level: Math.max(lo, Math.min(hi, typeof z.defaultVolume === 'number' ? z.defaultVolume : Math.round((lo + hi) / 2))) });
          });
        } }, icon('plus'), 'Add a preset')) : null);
    });
    VF.mount(container,
      S.sectionHead('Volume presets', 'One-press levels for each audio zone. A preset stays inside the limits your installer set for the zone.'),
      cards.length ? h('div.col', cards) : h('div.empty', h('p', 'This venue has no audio zones.')));
  }

  S.register({ id: 'home', title: 'Home', icon: 'home', group: 'Your venue', order: 1, clientOnly: true, render: renderHome });
  S.register({ id: 'channels', title: 'Channels and Names', icon: 'tv', group: 'Your venue', order: 2, clientOnly: true, render: renderChannels });
  S.register({ id: 'presets', title: 'Volume Presets', icon: 'volume', group: 'Your venue', order: 3, clientOnly: true, render: renderPresets });
})();
