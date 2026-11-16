/* Interface A, Visual Floor Plan: the venue from above. Tap displays where they
   really are, then route, listen and power them from the side panel. */
(function () {
  'use strict';
  var h = VF.h, O = Operator;
  /* Kept across view switches (memory only). */
  var S = { floorId: '', zoneId: '' };

  O.register('floorplan', function (host) {
    var floors = O.list('floors');
    var canRoute = O.can('routeVideo'), canPower = O.can('power');
    if (!floors.length) {
      VF.mount(host, h('div.empty', 'No floor is available to this profile.'));
      return {};
    }
    var floor = null, plan = null;
    var planHost = h('div.op-fp-plan');
    var floorSeg = floors.length > 1 ? h('div.seg.op-fp-floors', { role: 'group', 'aria-label': 'Floor' }, floors.map(function (f) {
      return h('button', { type: 'button', dataset: { floor: f.id }, onclick: function () { setFloor(f.id); } }, f.name);
    })) : null;

    function idsOnFloor() { return O.floorDisplays(floor.id).map(function (d) { return d.id; }); }

    /* toolbar: groups, Select All, Clear */
    var groupRow = h('div.op-fp-groups.scroll');
    var groupEls = [];
    function buildGroups() {
      VF.clear(groupRow); groupEls = [];
      var onFloor = {};
      idsOnFloor().forEach(function (id) { onFloor[id] = true; });
      O.list('groups').forEach(function (g) {
        var ids = VF.asList(g.displayIds).filter(function (id) { return onFloor[id]; });
        if (!ids.length) return;
        var b = h('button.op-fchip.group', { type: 'button', title: 'Select ' + g.name, onclick: function () { O.selection.toggleMany(ids); } }, g.name, h('span.op-fchip-n', String(ids.length)));
        b._ids = ids;
        groupRow.appendChild(b); groupEls.push(b);
      });
    }
    var selAll = h('button.btn.sm', { type: 'button', onclick: function () { O.selection.add(idsOnFloor()); } }, VF.icon('check', 'sm'), 'Select All');
    var selNone = h('button.btn.sm.ghost', { type: 'button', onclick: function () { O.selection.clear(); } }, 'Clear');

    /* side panel */
    var selTitle = h('h3');
    var selList = h('div.list.op-fp-sel');
    var unplacedBox = h('div.op-fp-unplaced');
    var unplacedEls = [];
    function buildUnplaced() {
      unplacedEls = [];
      var list = O.unplacedDisplays(floor.id);
      VF.clear(unplacedBox);
      if (!list.length) return;
      unplacedBox.appendChild(h('h4', 'Not on the plan'));
      var wrap = h('div.op-fp-unplaced-list');
      list.forEach(function (d) {
        var st = h('span.small');
        var b = h('button.op-mini', { type: 'button', role: 'checkbox', onclick: function () { O.selection.toggle(d.id); } }, h('span.op-check', VF.icon('check', 'sm')), h('span.grow.ellipsis', d.name), st);
        wrap.appendChild(b);
        unplacedEls.push({ el: b, d: d, st: st });
      });
      unplacedBox.appendChild(wrap);
    }

    /* source picker: one button that opens the list */
    var srcText = h('span.grow.ellipsis');
    function pickSource() {
      var closer = null;
      var list = O.sourceList({
        get: function () { return O.pick.sourceId; },
        set: function (id) { O.pick.sourceId = id; update(); if (closer) closer(id); },
        note: function (s) {
          var blocked = O.selection.ids().filter(function (id) { return !O.canShow(O.find('displays', id), s.id); }).length;
          return blocked ? O.plural(blocked, 'selected display') + ' cannot show this' : '';
        }
      });
      list.update();
      VF.modal({ title: 'Choose a source', icon: 'monitor', body: list, actions: [{ label: 'Cancel', kind: 'ghost', value: null }], onOpen: function (close) { closer = close; } });
    }
    var srcBtn = h('button.btn.block.op-fp-srcbtn', { type: 'button', 'aria-haspopup': 'dialog', onclick: pickSource }, VF.icon('monitor'), srcText, VF.icon('chevron-down', 'sm'));
    var routing = false;
    var routeText = h('span', 'Route Video');
    var routeBtn = canRoute ? h('button.btn.primary.lg.block', { type: 'button', onclick: function () {
      var ids = O.selection.ids();
      if (routing || !ids.length || !O.pick.sourceId) return;
      routing = true; update();
      O.route(O.pick.sourceId, ids, listenZoneId()).then(function () { routing = false; update(); });
    } }, VF.icon('route'), routeText) : null;

    /* listen: send the sound of the routed source to one audio zone */
    var zones = O.listenZones();
    var listenToggle = h('button.toggle', { type: 'button', role: 'switch', 'aria-label': 'Listen', onclick: function () {
      O.pick.listen = !O.pick.listen;
      if (O.pick.listen && !O.pick.zoneId) O.pick.zoneId = defaultListenZone();
      update();
    } });
    var listenName = h('span.grow.ellipsis');
    var listenSelect = zones.length > 1 ? h('select.field.op-fp-listenzone', { 'aria-label': 'Listen in', onchange: function () { O.pick.zoneId = listenSelect.value; O.pick.listen = true; update(); } },
      zones.map(function (z) { return h('option', { value: z.id }, z.name); })) : null;
    var listenHint = h('div.hint');
    var listenRow = zones.length && canRoute ? h('div.op-fp-listen', h('div.row', listenToggle, listenName, listenSelect), listenHint) : null;
    function defaultListenZone() {
      var sel = O.selection.ids();
      for (var i = 0; i < sel.length; i++) {
        var d = O.find('displays', sel[i]);
        if (d && d.audioZoneId && zones.some(function (z) { return z.id === d.audioZoneId; })) return d.audioZoneId;
      }
      return zones.length ? zones[0].id : '';
    }
    function listenZone() { return O.find('audioZones', O.pick.zoneId) || O.find('audioZones', defaultListenZone()); }
    function listenZoneId() {
      if (!O.pick.listen || !listenRow) return '';
      var z = listenZone();
      return z && !O.listenProblem(z, O.pick.sourceId) ? z.id : '';
    }

    function powerBtn(power) {
      var b = h('button.btn.grow' + (power === 'off' ? '' : '.outline'), { type: 'button', onclick: function () {
        var ids = O.selection.ids();
        if (!ids.length || b.disabled) return;
        b._busy = true; b.disabled = true;
        O.power(ids, power).then(function () { b._busy = false; update(); });
      } }, VF.icon('power'), power === 'on' ? 'Power On' : 'Power Off');
      return b;
    }
    var pOn = canPower ? powerBtn('on') : null, pOff = canPower ? powerBtn('off') : null;

    var side = h('aside.panel.op-fp-side.scroll',
      h('div.op-fp-block', selTitle, selList),
      unplacedBox,
      canRoute ? srcBtn : null,
      routeBtn, listenRow,
      (pOn || pOff) ? h('div.row.op-fp-power', pOn, pOff) : null);

    /* bottom bar: scene shortcuts and one audio zone */
    var scenes = O.sceneBar();
    var zoneList = O.can('audio') ? O.list('audioZones') : [];
    var zoneHost = h('div.op-fp-zone');
    var zoneCtl = null;
    var zoneSelect = zoneList.length > 1 ? h('select.field.op-fp-zonepick', { 'aria-label': 'Audio zone', onchange: function () { S.zoneId = zoneSelect.value; buildZone(); } },
      zoneList.map(function (z) { return h('option', { value: z.id }, z.name); })) : null;
    function buildZone() {
      var z = O.find('audioZones', S.zoneId);
      if (!z || zoneList.indexOf(z) < 0) z = zoneList[0];
      zoneCtl = null;
      if (!z) return;
      S.zoneId = z.id;
      if (zoneSelect) zoneSelect.value = z.id;
      zoneCtl = O.zoneControl(z, { variant: 'bar', source: false, presets: false, off: false });
      VF.mount(zoneHost, zoneCtl);
    }
    var bottom = (scenes || zoneList.length || O.can('allOff')) ? h('div.panel.op-fp-bottom',
      scenes || h('div.grow'),
      zoneList.length ? h('div.op-fp-audio', zoneSelect, zoneHost) : null,
      O.allOffButton('.sm')) : null;

    function setFloor(id) {
      floor = O.find('floors', id) || floors[0];
      S.floorId = floor.id;
      plan = O.plan(floor, {
        onDisplay: function (d) { O.selection.toggle(d.id); },
        onArea: function (a) { O.selection.toggleMany(O.floorDisplays(floor.id).filter(function (d) { return d.areaId === a.id; }).map(function (d) { return d.id; })); }
      });
      VF.mount(planHost, plan.el, plan.count ? null : h('div.op-fp-noplan.muted', 'No display has been placed on this floor yet.'));
      if (floorSeg) Array.prototype.forEach.call(floorSeg.children, function (b) { O.setClass(b, 'on', b.dataset.floor === floor.id); });
      buildGroups();
      buildUnplaced();
      update();
    }

    VF.mount(host,
      h('div.op-fp-bar', floorSeg, groupRow, selAll, selNone),
      h('div.op-fp-body', h('div.panel.op-fp-planwrap.scroll', planHost), side),
      bottom);
    buildZone();

    function update() {
      if (!plan) return;
      var sel = O.selection.ids(), n = sel.length;
      var src = O.find('sources', O.pick.sourceId);
      plan.update();
      groupEls.forEach(function (b) { O.setClass(b, 'on', b._ids.every(function (id) { return O.selection.has(id); })); });
      var onFloor = idsOnFloor();
      selAll.disabled = !onFloor.length || onFloor.every(function (id) { return O.selection.has(id); });
      selNone.disabled = !n;

      O.setText(selTitle, 'Selected Displays (' + n + ')');
      var sig = sel.map(function (id) { var i = O.displayInfo(O.find('displays', id)); return id + ':' + i.key + ':' + i.line; }).join('|');
      O.patch(selList, 'n' + n + '|' + sig, function () {
        if (!n) return h('div.empty.small', 'Tap displays on the plan, an area name, or a group.');
        return sel.map(function (id) {
          var d = O.find('displays', id), info = O.displayInfo(d);
          var chip = O.displayChip(); chip.set(info);
          return h('div.item.op-fp-selrow', h('div.grow', h('div.ellipsis', d.name), h('div.small.muted.ellipsis', info.sourceName || O.areaName(d.areaId))), chip,
            h('button.btn.ghost.icon.sm', { type: 'button', 'aria-label': 'Remove ' + d.name, onclick: function () { O.selection.toggle(id); } }, VF.icon('x', 'sm')));
        });
      });
      unplacedEls.forEach(function (u) {
        var info = O.displayInfo(u.d);
        var cls = 'op-mini ' + info.key + (O.selection.has(u.d.id) ? ' sel' : '');
        if (u.el.className !== cls) u.el.className = cls;
        O.setAttr(u.el, 'aria-checked', O.selection.has(u.d.id) ? 'true' : 'false');
        O.setText(u.st, info.line);
      });

      O.setText(srcText, 'Source: ' + (src ? src.name : 'choose one'));
      O.setClass(srcBtn, 'on', !!src);
      if (routeBtn) {
        O.setText(routeText, routing ? 'Sending' : (n ? 'Route Video to ' + O.plural(n, 'Display') : 'Route Video'));
        routeBtn.disabled = routing || !n || !src;
      }
      if (listenRow) {
        var z = listenZone();
        var on = O.pick.listen && !!z;
        O.setClass(listenToggle, 'on', on);
        O.setAttr(listenToggle, 'aria-checked', on ? 'true' : 'false');
        O.setText(listenName, listenSelect ? 'Listen in' : 'Listen in ' + (z ? z.name : ''));
        if (listenSelect && z && document.activeElement !== listenSelect && listenSelect.value !== z.id) listenSelect.value = z.id;
        var problem = on ? O.listenProblem(z, O.pick.sourceId) : '';
        O.setText(listenHint, problem ? problem + ' The sound will not change.' : (on ? 'The sound in ' + z.name + ' follows the routed source.' : ''));
        O.setClass(listenHint, 'st-failed', !!problem);
      }
      if (pOn) pOn.disabled = !n || pOn._busy === true;
      if (pOff) pOff.disabled = !n || pOff._busy === true;
      if (scenes) scenes.update();
      if (zoneCtl) zoneCtl.update();
    }

    setFloor(S.floorId);
    return { update: update };
  });
})();
