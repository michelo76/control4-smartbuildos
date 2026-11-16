/* Interface B, Command Center: select displays, choose a source, route.
   Two ways of working: display first (select, pick, route) and source first
   (pick a source, then every display tapped is routed at once). */
(function () {
  'use strict';
  var h = VF.h, O = Operator;
  /* Kept across view switches (memory only). */
  var S = { filter: 'all', mode: 'display', floorId: '' };

  O.register('command', function (host) {
    var displays = O.list('displays');
    var canRoute = O.can('routeVideo'), canPower = O.can('power');
    if (!canRoute) S.mode = 'display';
    if (!displays.length) {
      VF.mount(host, h('div.empty', 'No display is available to this profile.'));
      return {};
    }

    /* filters: All, each area, each group */
    var filters = [{ id: 'all', label: 'All', ids: displays.map(function (d) { return d.id; }) }];
    O.list('areas').forEach(function (a) {
      var ids = displays.filter(function (d) { return d.areaId === a.id; }).map(function (d) { return d.id; });
      if (ids.length) filters.push({ id: 'area:' + a.id, label: a.name, ids: ids });
    });
    O.list('groups').forEach(function (g) {
      var ids = VF.asList(g.displayIds).filter(function (id) { return O.find('displays', id); });
      if (ids.length) filters.push({ id: 'group:' + g.id, label: g.name, ids: ids, group: true });
    });
    function filter() {
      for (var i = 0; i < filters.length; i++) if (filters[i].id === S.filter) return filters[i];
      S.filter = 'all';
      return filters[0];
    }

    /* top row: scenes, the selection count, All Off */
    var scenes = O.sceneBar();
    var count = h('span.chip.teal.op-cc-count');
    var top = h('div.op-cc-top', scenes || h('div.grow'), count, O.allOffButton('.sm'));

    /* step heads */
    function step() {
      var no = h('span.op-stepno'), title = h('h3.grow.ellipsis');
      var el = h('div.op-step', no, title);
      el.set = function (n, text) { O.setText(no, n); O.setText(title, text); };
      return el;
    }
    var stepDisplays = step(), stepSources = step(), stepRoute = step();

    /* 1: displays */
    var modeSeg = canRoute ? h('div.seg.op-cc-mode', { role: 'group', 'aria-label': 'How to route' },
      h('button', { type: 'button', dataset: { mode: 'display' }, title: 'Select displays, choose a source, then route', onclick: function () { setMode('display'); } }, 'Select first'),
      h('button', { type: 'button', dataset: { mode: 'source' }, title: 'Choose a source, then tap each display to route it at once', onclick: function () { setMode('source'); } }, 'Source first')) : null;
    var chipRow = h('div.op-cc-filters.scroll');
    var chipEls = filters.map(function (f) {
      var b = h('button.op-fchip' + (f.group ? '.group' : ''), { type: 'button', onclick: function () { S.filter = f.id; buildGrid(); update(); } }, f.label, h('span.op-fchip-n', String(f.ids.length)));
      b._f = f;
      chipRow.appendChild(b);
      return b;
    });
    var selAll = h('button.btn.sm', { type: 'button', onclick: function () { O.selection.add(filter().ids); } }, 'Select All');
    var selNone = h('button.btn.sm.ghost', { type: 'button', onclick: function () { O.selection.remove(filter().ids); } }, 'Clear');
    var grid = h('div.op-cc-grid.scroll');
    var tiles = [];
    var busyTiles = {};

    function tapTile(d) {
      if (S.mode !== 'source') { O.selection.toggle(d.id); return; }
      if (!O.pick.sourceId) { VF.toast('Choose a source first.', 'warn'); return; }
      if (busyTiles[d.id]) return;
      busyTiles[d.id] = true;
      O.route(O.pick.sourceId, [d.id], listenZoneId()).then(function () { delete busyTiles[d.id]; });
    }
    function buildGrid() {
      var f = filter();
      tiles = [];
      VF.clear(grid);
      f.ids.forEach(function (id) {
        var d = O.find('displays', id);
        if (!d) return;
        var chip = O.displayChip();
        var src = h('div.op-tile-src.ellipsis');
        var mark = h('span.op-check', VF.icon('check', 'sm'));
        var note = h('span.op-tile-note', 'Cannot show');
        var el = h('button.op-tile', { type: 'button', role: 'checkbox', onclick: function () { tapTile(d); } },
          h('div.op-tile-top', mark, h('div.grow.ellipsis.op-tile-name', d.name), h('span.op-tile-area.ellipsis', O.areaName(d.areaId))),
          h('div.op-tile-now', chip, src, note));
        grid.appendChild(el);
        tiles.push({ el: el, d: d, chip: chip, src: src });
      });
      grid.scrollTop = 0;
    }

    /* 2: sources */
    var sources = O.sourceList({
      get: function () { return O.pick.sourceId; },
      set: function (id) { O.pick.sourceId = id; update(); },
      note: function (s) {
        if (S.mode === 'source') return '';
        var blocked = O.selection.ids().filter(function (id) { return !O.canShow(O.find('displays', id), s.id); }).length;
        return blocked ? blocked + ' selected cannot show this' : '';
      }
    });

    /* 3: route, listen, power */
    var zones = O.listenZones();
    var follow = zones.length ? h('select.field', { 'aria-label': 'Audio follow', onchange: function () { O.pick.zoneId = follow.value; O.pick.listen = follow.value !== ''; update(); } },
      h('option', { value: '' }, 'No audio change'), zones.map(function (z) { return h('option', { value: z.id }, 'Listen in ' + z.name); })) : null;
    var followHint = h('div.hint.op-cc-hint');
    function listenZoneId() {
      if (!O.pick.listen || !O.pick.zoneId) return '';
      var z = O.find('audioZones', O.pick.zoneId);
      return z && !O.listenProblem(z, O.pick.sourceId) ? z.id : '';
    }
    var routing = false;
    var routeText = h('span');
    var routeBtn = canRoute ? h('button.btn.primary.lg.block.op-cc-go', { type: 'button', onclick: function () {
      var ids = O.selection.ids();
      if (routing || !ids.length || !O.pick.sourceId) return;
      routing = true; update();
      O.route(O.pick.sourceId, ids, listenZoneId()).then(function () { routing = false; update(); });
    } }, VF.icon('route'), routeText) : null;
    var sourceHint = h('div.banner.info.op-cc-sfhint.hidden', VF.icon('info'), h('div', 'Each display you tap is routed at once.'));
    function powerBtn(power) {
      var b = h('button.btn' + (power === 'off' ? '' : '.outline'), { type: 'button', onclick: function () {
        var ids = O.selection.ids();
        if (!ids.length || b.disabled) return;
        b._busy = true; b.disabled = true;
        O.power(ids, power).then(function () { b._busy = false; update(); });
      } }, VF.icon('power'), power === 'on' ? 'Power On' : 'Power Off');
      return b;
    }
    var pOn = canPower ? powerBtn('on') : null, pOff = canPower ? powerBtn('off') : null;

    /* compact venue map (shown by CSS only when the screen is wide enough) */
    var floors = O.list('floors').filter(function (f) { return O.floorDisplays(f.id).some(O.placed); });
    var mapHost = h('div.op-cc-maphost');
    var mapSeg = null, plan = null;
    function buildMap() {
      var floor = O.find('floors', S.floorId) || floors[0];
      if (!floor) return;
      S.floorId = floor.id;
      plan = O.plan(floor, { compact: true, onDisplay: function (d) { tapTile(d); }, onArea: S.mode === 'source' ? null : function (a) {
        O.selection.toggleMany(displays.filter(function (d) { return d.areaId === a.id; }).map(function (d) { return d.id; }));
      } });
      VF.mount(mapHost, plan.el);
      if (mapSeg) Array.prototype.forEach.call(mapSeg.children, function (b) { O.setClass(b, 'on', b.dataset.floor === floor.id); });
    }
    if (floors.length > 1) {
      mapSeg = h('div.seg.op-cc-mapseg', floors.map(function (f) { return h('button', { type: 'button', dataset: { floor: f.id }, onclick: function () { S.floorId = f.id; buildMap(); } }, f.name); }));
    }
    var map = floors.length ? h('div.op-cc-map', mapSeg, mapHost) : null;

    /* audio zones along the bottom */
    var zoneCards = O.can('audio') ? O.list('audioZones').map(function (z) { return O.zoneControl(z, { variant: 'card', source: false, presets: false, off: false, more: true }); }) : [];
    var zoneRow = zoneCards.length ? h('div.op-cc-zones.scroll', zoneCards) : null;

    function setMode(mode) {
      S.mode = mode;
      buildMap();
      update();
    }

    VF.mount(host,
      top,
      h('div.op-cc-body',
        h('section.panel.op-cc-displays', h('div.op-cc-head', stepDisplays, modeSeg), h('div.op-cc-tools', chipRow, selAll, selNone), grid),
        h('section.panel.op-cc-sources', stepSources, h('div.op-cc-srcwrap.scroll', sources)),
        h('section.panel.op-cc-route', stepRoute,
          h('div.op-cc-routebody.scroll',
            follow ? h('label.lbl', 'Audio follow', follow, followHint) : null,
            sourceHint, routeBtn,
            (pOn || pOff) ? h('div.op-cc-power', pOn, pOff) : null,
            map))),
      zoneRow);
    buildGrid();
    buildMap();

    function update() {
      var sel = O.selection.ids(), n = sel.length;
      var sourceFirst = S.mode === 'source';
      var src = O.find('sources', O.pick.sourceId);
      var f = filter();

      O.setText(count, O.plural(n, 'display') + ' selected');
      O.setClass(count, 'hidden', sourceFirst);
      if (scenes) scenes.update();

      if (sourceFirst) {
        stepSources.set('1', 'Choose Source'); stepDisplays.set('2', 'Tap Displays to Route'); stepRoute.set('3', 'Listen');
      } else {
        stepDisplays.set('1', 'Select Displays'); stepSources.set('2', 'Choose Source'); stepRoute.set('3', 'Route & Listen');
      }
      O.setClass(host, 'source-first', sourceFirst);
      if (modeSeg) Array.prototype.forEach.call(modeSeg.children, function (b) { O.setClass(b, 'on', b.dataset.mode === S.mode); });
      chipEls.forEach(function (b) { O.setClass(b, 'on', b._f.id === f.id); });
      selAll.disabled = sourceFirst || f.ids.every(function (id) { return O.selection.has(id); });
      selNone.disabled = sourceFirst || !f.ids.some(function (id) { return O.selection.has(id); });

      tiles.forEach(function (t) {
        var info = O.displayInfo(t.d);
        var on = O.selection.has(t.d.id);
        var cls = 'op-tile ' + info.key + (on && !sourceFirst ? ' sel' : '') + (src && !O.canShow(t.d, src.id) ? ' blocked' : '');
        if (t.el.className !== cls) t.el.className = cls;
        O.setAttr(t.el, 'aria-checked', on && !sourceFirst ? 'true' : 'false');
        t.chip.set(info);
        O.setText(t.src, info.sourceName || (info.on ? 'No source' : ''));
      });
      sources.update();

      if (follow) {
        var zid = O.pick.listen ? O.pick.zoneId : '';
        if (document.activeElement !== follow && follow.value !== zid) follow.value = zid;
        var problem = zid ? O.listenProblem(O.find('audioZones', zid), O.pick.sourceId) : '';
        O.setText(followHint, problem ? problem + ' The sound will not change.' : (zid ? 'The sound in that zone follows the source you route.' : ''));
        O.setClass(followHint, 'st-failed', !!problem);
      }
      if (routeBtn) {
        O.setClass(routeBtn, 'hidden', sourceFirst);
        O.setText(routeText, routing ? 'Sending' : (!n ? 'Select displays' : (!src ? 'Choose a source' : 'Route to ' + O.plural(n, 'Display'))));
        routeBtn.disabled = routing || !n || !src;
      }
      O.setClass(sourceHint, 'hidden', !sourceFirst);
      if (pOn) { pOn.disabled = !n || pOn._busy === true; O.setClass(pOn.parentNode, 'hidden', sourceFirst); }
      if (pOff) pOff.disabled = !n || pOff._busy === true;
      if (plan) plan.update();
      zoneCards.forEach(function (z) { z.update(); });
    }
    return { update: update };
  });
})();
