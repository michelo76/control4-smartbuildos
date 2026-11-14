/* Interface D, Manager Overview: how the venue is doing, what needs a look,
   scenes, open / close, All Off, and what was done recently. Calm and plain:
   a manager is not a technician. Every number comes from the driver's counts. */
(function () {
  'use strict';
  var h = VF.h, O = Operator;
  var S = { floorId: '', open: {} };

  function resolveAlert(alert) {
    var a = VF.asMap(alert.action);
    if (a.type === 'query') {
      var payload = {};
      if (VF.asList(a.displayIds).length) payload.displayIds = VF.asList(a.displayIds);
      return VF.api('QUERY_STATUS', payload).then(function (r) {
        var results = VF.asList(r.results);
        var failed = results.filter(function (x) { return x.status === 'failed'; });
        if (!r.ok) VF.toastReply(r);
        else if (failed.length) VF.modal({ title: 'Checked again', icon: 'alert', body: VF.outcomeList(results), actions: [{ label: 'Close', kind: 'primary', value: null }] });
        else VF.toast('Checked again. The screen now shows what Control4 reports.', 'ok');
      });
    }
    if (a.type === 'unmute') return O.send('AUDIO_MUTE', { zoneId: a.zoneId, muted: false });
    return Promise.resolve();
  }
  function displaySheet(d) {
    var info = O.displayInfo(d);
    var chip = O.displayChip(); chip.set(info);
    var actions = [{ label: 'Close', kind: d.hasFeedback ? 'ghost' : 'primary', value: null }];
    if (d.hasFeedback) actions.push({ label: 'Check again', kind: 'primary', icon: 'refresh', value: 'check' });
    VF.modal({ title: d.name, icon: 'tv', body: h('div.list',
      h('div.item', h('div.grow', 'Status'), chip),
      h('div.item', h('div.grow', 'Showing'), h('span.muted', info.sourceName || 'Nothing')),
      h('div.item', h('div.grow', 'Area'), h('span.muted', O.areaName(d.areaId) || 'None'))), actions: actions }).then(function (v) {
      if (v === 'check') resolveAlert({ action: { type: 'query', displayIds: [d.id] } });
    });
  }

  O.register('manager', function (host) {
    var displays = O.list('displays');

    /* stat tiles */
    function tile(label, icon) {
      var value = h('div.op-stat-value'), sub = h('div.small.muted.ellipsis');
      var el = h('div.op-stat', VF.icon(icon, 'lg'), h('div.grow', value, h('div.op-stat-label.ellipsis', label), sub));
      el.set = function (v, s, tone) { O.setText(value, v); O.setText(sub, s || ''); var cls = 'op-stat' + (tone ? ' ' + tone : ''); if (el.className !== cls) el.className = cls; };
      return el;
    }
    var tDisplays = tile('Displays', 'tv'), tOn = tile('On', 'check-circle'), tAttention = tile('Attention', 'alert'),
      tZones = tile('Audio Zones', 'volume'), tScene = tile('Active Scene', 'zap');
    var stats = h('div.op-mgr-stats', tDisplays, tOn, tAttention, tZones, tScene);

    /* venue layout */
    var floors = O.list('floors').filter(function (f) { return O.floorDisplays(f.id).some(O.placed); });
    var mapHost = h('div.op-mgr-maphost'), plan = null;
    var mapSeg = floors.length > 1 ? h('div.seg', floors.map(function (f) { return h('button', { type: 'button', dataset: { floor: f.id }, onclick: function () { buildMap(f.id); } }, f.name); })) : null;
    function buildMap(id) {
      var floor = O.find('floors', id) || floors[0];
      if (!floor) return;
      S.floorId = floor.id;
      plan = O.plan(floor, { compact: true, selection: false, onDisplay: displaySheet });
      VF.mount(mapHost, plan.el);
      if (mapSeg) Array.prototype.forEach.call(mapSeg.children, function (b) { O.setClass(b, 'on', b.dataset.floor === floor.id); });
    }
    var legend = h('div.op-mgr-legend', ['on', 'off', 'failed', 'offline'].map(function (k) {
      return h('span.op-legend', h('i.' + k), k === 'on' ? 'On' : (k === 'off' ? 'Off' : (k === 'failed' ? 'Not confirmed' : 'Offline or unknown')));
    }));
    var areaList = h('div.list.op-mgr-areas');

    /* scenes */
    var sceneCards = O.list('scenes').map(function (s) {
      var chip = h('span.chip.ok.hidden', h('span.dot'), 'Active');
      var btn = h('button.btn.sm.outline', { type: 'button', onclick: function () {
        if (btn.disabled) return;
        btn.disabled = true;
        O.activateScene(s).then(function () { btn.disabled = false; });
      } }, 'Activate');
      var el = h('div.card.op-mgr-scene', h('div.row', VF.sceneIcon(s.icon, 'lg'), h('h3.grow.ellipsis', s.name), chip),
        h('p.small.muted.op-mgr-scene-desc', s.description || (s.confirm ? 'Asks for confirmation before it runs.' : '')), h('div.row.end', btn));
      el.update = function () {
        var st = O.sceneState(s);
        O.setClass(el, 'on', st.active);
        O.setClass(chip, 'hidden', !st.active);
        O.setText(btn, st.running ? 'Running' : (st.active ? 'Run again' : 'Activate'));
      };
      return el;
    });

    /* attention, venue, activity */
    var alertList = h('div.list');
    var alertCount = h('span.chip');
    var venueText = h('div.grow');
    var venueBtn = O.can('venueStatus') ? h('button.btn', { type: 'button', onclick: function () { O.setVenueStatus(O.doc().venueStatus === 'open' ? 'closed' : 'open'); } }) : null;
    var runList = h('div.list');
    var runPanel = h('section.panel.hidden', h('div.panel-head', VF.icon('play'), h('h3', 'Running now')), h('div.panel-body', runList));
    var opList = h('div.list');

    VF.mount(host, h('div.op-mgr.scroll',
      stats,
      h('div.op-mgr-cols',
        h('div.op-mgr-main',
          displays.length ? h('section.panel', h('div.panel-head', VF.icon('map'), h('h3.grow', 'Venue'), mapSeg),
            h('div.panel-body.op-mgr-venue', floors.length ? h('div.op-mgr-map', mapHost, legend) : null, areaList)) : null,
          sceneCards.length ? h('section.panel', h('div.panel-head', VF.icon('zap'), h('h3', 'Scenes')), h('div.panel-body.op-mgr-scenes', sceneCards)) : null),
        h('div.op-mgr-side',
          O.can('viewAlerts') ? h('section.panel', h('div.panel-head', VF.icon('alert'), h('h3.grow', 'Needs attention'), alertCount), h('div.panel-body', alertList)) : null,
          h('section.panel', h('div.panel-head', VF.icon('building'), h('h3', 'Venue status')),
            h('div.panel-body.col', h('div.row', venueText, venueBtn),
              O.can('allOff') ? h('div.row.op-mgr-alloff', h('div.grow.small.muted', 'Switches off every display and audio zone. You see a preview first.'), O.allOffButton('')) : null)),
          runPanel,
          h('section.panel', h('div.panel-head', VF.icon('history'), h('h3', 'Recent activity')), h('div.panel-body', opList))))));
    buildMap(S.floorId);

    function update() {
      var doc = O.doc();
      var c = VF.asMap(VF.asMap(doc.counts).displays), z = VF.asMap(VF.asMap(doc.counts).zones);
      /* The driver's own counts: on and off as it knows them, and what it cannot vouch for. */
      var rest = [(c.off || 0) + ' off'];
      if (c.unknown) rest.push(c.unknown + ' unknown');
      if (c.offline) rest.push(c.offline + ' offline');
      tDisplays.set(String(c.total || 0), '');
      tOn.set(String(c.on || 0), rest.join(', '), c.on ? 'ok' : '');
      tAttention.set(String(c.attention || 0), c.attention ? 'see the list below' : 'all clear', c.attention ? 'warn' : '');
      tZones.set((z.on || 0) + ' of ' + (z.total || 0) + ' on', z.muted ? z.muted + ' muted' : '');
      tScene.set(doc.activeScene ? doc.activeScene.name : 'None', doc.activeScene && doc.activeScene.at ? 'since ' + VF.fmtTime(doc.activeScene.at) : '', doc.activeScene ? 'teal' : '');
      if (plan) plan.update();

      /* area summaries */
      var rows = O.list('areas').map(function (a) {
        var list = displays.filter(function (d) { return d.areaId === a.id; });
        var on = 0, bad = 0, working = 0;
        list.forEach(function (d) { var i = O.displayInfo(d); if (i.on) on++; if (i.key === 'failed' || i.key === 'offline') bad++; if (i.key === 'working') working++; });
        var audio = O.list('audioZones').filter(function (x) { return x.areaId === a.id; }).map(function (x) {
          var st = VF.asMap(VF.asMap(doc.zones)[x.id]);
          var v = st.volume || {}, m = st.mute || {}, p = st.power || {};
          return m.value === true ? 'Muted' : (p.value === 'off' ? 'Audio off' : (typeof v.value === 'number' ? 'Audio ' + v.value + '%' : 'Audio unknown'));
        });
        return { a: a, total: list.length, on: on, bad: bad, working: working, audio: audio };
      }).filter(function (r) { return r.total || r.audio.length; });
      O.patch(areaList, JSON.stringify(rows.map(function (r) { return [r.a.id, r.total, r.on, r.bad, r.working, r.audio]; })), function () {
        if (!rows.length) return h('div.empty.small', 'No area is set up.');
        return rows.map(function (r) {
          return h('div.item.op-mgr-area', h('div.grow', h('div.ellipsis', r.a.name), h('div.small.muted', r.total ? r.on + ' of ' + O.plural(r.total, 'display') + ' on' : 'No display')),
            r.working ? h('span.chip.teal', h('span.dot.pulse'), r.working + ' working') : null,
            r.bad ? h('span.chip.warn', h('span.dot'), r.bad + ' to check') : null,
            r.audio.map(function (t) { return h('span.chip' + (t === 'Muted' ? '.warn' : ''), VF.icon(t === 'Muted' ? 'volume-x' : 'volume', 'sm'), t); }));
        });
      });

      sceneCards.forEach(function (s) { s.update(); });

      /* alerts */
      if (O.can('viewAlerts')) {
        var alerts = VF.asList(doc.alerts);
        O.setText(alertCount, alerts.length ? String(alerts.length) : 'All clear');
        var acls = 'chip ' + (alerts.length ? 'warn' : 'ok');
        if (alertCount.className !== acls) alertCount.className = acls;
        O.patch(alertList, JSON.stringify(alerts.map(function (a) { return [a.id, a.title, a.detail, a.level]; })), function () {
          if (!alerts.length) return h('div.op-mgr-clear', VF.icon('check-circle', 'lg'), h('span', 'Nothing needs attention.'));
          return alerts.map(function (a) {
            var act = VF.asMap(a.action);
            var warn = a.level !== 'info';
            var label = act.type === 'query' ? 'Resolve' : (act.type === 'unmute' ? 'Unmute' : '');
            var btn = label ? h('button.btn.sm' + (warn ? '.warn' : ''), { type: 'button', onclick: function () {
              if (btn.disabled) return;
              btn.disabled = true;
              resolveAlert(a).then(function () { btn.disabled = false; });
            } }, label) : null;
            var dismiss = a.dismissable ? h('button.btn.sm.ghost', { type: 'button', onclick: function () { O.send('ALERT_DISMISS', { alertId: a.id }); } }, 'Dismiss') : null;
            return h('div.op-alert' + (warn ? '.warn' : '.info'), VF.icon(warn ? 'alert' : 'info'),
              h('div.grow', h('div.op-alert-title', a.title), a.detail ? h('div.small.op-alert-detail', a.detail) : null, a.at ? h('div.tiny.muted', VF.fmtTime(a.at)) : null),
              h('div.op-alert-actions', btn, dismiss));
          });
        });
      }

      /* venue */
      var open = doc.venueStatus === 'open';
      O.patch(venueText, 'v' + doc.venueStatus, function () {
        return [h('div', 'The venue is ', h('b', open ? 'open' : 'closed'), '.'), h('div.small.muted', open ? 'Close it at the end of the day.' : 'Open it when the day starts.')];
      });
      if (venueBtn) O.patch(venueBtn, 'b' + doc.venueStatus, function () { return [VF.icon(open ? 'moon' : 'sun'), open ? 'Close venue' : 'Open venue']; });

      /* running + recent */
      var running = VF.asList(doc.running);
      O.setClass(runPanel, 'hidden', !running.length);
      O.patch(runList, JSON.stringify(running), function () {
        return running.map(function (x) {
          return h('div.item', h('span.dot.teal.pulse'), h('div.grow', h('div.ellipsis', x.name), h('div.small.muted', (x.kind === 'rule' ? 'Automatic rule' : 'Scene') + ', started ' + VF.fmtTime(x.startedAt))), VF.outcomeChip(x.status === 'settling' ? 'waiting' : 'running'));
        });
      });
      var ops = VF.asList(doc.operations);
      O.patch(opList, JSON.stringify(ops.map(function (op) { return [op.id, O.opText(op), op.done, !!S.open[op.id]]; })), function () {
        if (!ops.length) return h('div.empty.small', 'Nothing has been done yet.');
        return ops.map(function (op) {
          var tone = O.opTone(op), isOpen = !!S.open[op.id];
          var head = h('button.op-oprow', { type: 'button', 'aria-expanded': isOpen ? 'true' : 'false', onclick: function () { S.open[op.id] = !S.open[op.id]; update(); } },
            h('span.dot.' + tone + (op.done ? '' : '.pulse')),
            h('div.grow', h('div.ellipsis', op.label || 'Operation'), h('div.small.muted', VF.fmtTime(op.startedAt) + ' · ' + O.opText(op))),
            VF.icon(isOpen ? 'chevron-up' : 'chevron-down', 'sm'));
          return h('div.op-op' + (isOpen ? '.open' : ''), head, isOpen ? VF.outcomeList(op.targets) : null);
        });
      });
    }
    return { update: update };
  });
})();
