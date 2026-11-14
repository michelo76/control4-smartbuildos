/* Interface C, Simplified Room Control: one room, a few very large buttons.
   Driven by the room panels of the published configuration (config.rooms). */
(function () {
  'use strict';
  var h = VF.h, O = Operator;
  var S = { roomId: '' };

  function cell(kind, id, field) { return VF.state.cell(kind, id, field); }
  function word(c) { return c.status === 'pending' ? 'working' : (c.status === 'failed' || (c.status === 'unknown' && c.errorCode) ? 'not confirmed' : ''); }

  O.register('room', function (host) {
    var rooms = O.list('rooms');
    if (!rooms.length) {
      VF.mount(host, h('div.op-room-none', VF.icon('home', 'xl'), h('h2', 'No room panel here'), h('p.muted', 'No room panel is available to this profile. Ask your installer to add one for this room.')));
      return {};
    }
    var body = h('div.op-room-body');
    var picker = rooms.length > 1 ? h('div.seg.op-room-pick', { role: 'group', 'aria-label': 'Room' }, rooms.map(function (r) {
      return h('button', { type: 'button', dataset: { room: r.id }, onclick: function () { build(r.id); } }, r.name);
    })) : null;
    var parts = [];       // update functions of the room now shown

    function build(id) {
      var room = O.find('rooms', id) || rooms[0];
      S.roomId = room.id;
      parts = [];
      if (picker) Array.prototype.forEach.call(picker.children, function (b) { O.setClass(b, 'on', b.dataset.room === room.id); });

      var displays = VF.asList(room.displayIds).map(function (x) { return O.find('displays', x); }).filter(Boolean);
      var zone = room.volumeZoneId && O.can('audio') ? O.find('audioZones', room.volumeZoneId) : null;
      var lighting = room.lightingId ? O.find('lighting', room.lightingId) : null;
      var shades = VF.asList(room.shadeIds).map(function (x) { return O.find('shades', x); }).filter(Boolean);

      var roomScenes = VF.asList(room.buttons).map(function (b) { return O.find('scenes', b.sceneId); }).filter(Boolean);

      /* head: the room name and whether anything in it needs a look */
      var ready = h('span.chip'), readyDot = h('span.dot'), readyText = h('span');
      VF.append(ready, [readyDot, readyText]);
      parts.push(function () {
        var working = false, trouble = false;
        displays.forEach(function (d) { var k = O.displayInfo(d).key; if (k === 'working') working = true; if (k === 'failed' || k === 'offline') trouble = true; });
        if (zone) ['power', 'source', 'volume', 'mute'].forEach(function (f) { var w = word(cell('zones', zone.id, f)); if (w === 'working') working = true; if (w === 'not confirmed') trouble = true; });
        var running = roomScenes.some(function (s) { return O.sceneState(s).running; });
        var cls = 'chip op-room-ready ' + (trouble ? 'warn' : (working || running ? 'teal' : 'ok'));
        if (ready.className !== cls) ready.className = cls;
        O.setClass(readyDot, 'pulse', !trouble && (working || running));
        O.setText(readyText, trouble ? 'Needs attention' : (working || running ? 'Working' : 'Room Ready'));
      });

      /* the big buttons */
      var buttons = VF.asList(room.buttons).map(function (b) {
        var scene = O.find('scenes', b.sceneId);
        if (!scene) return null;
        var tag = h('span.op-big-tag');
        var el = h('button.op-big' + (b.icon === 'power' ? '.off' : ''), { type: 'button', onclick: function () {
          if (el.disabled) return;
          el.disabled = true;
          O.activateScene(scene, { areaId: room.areaId }).then(function () { el.disabled = false; });
        } }, VF.sceneIcon(b.icon || scene.icon, 'xl'), h('span.op-big-label', b.label || scene.name), tag);
        parts.push(function () {
          var st = O.sceneState(scene);
          O.setClass(el, 'on', st.active);
          O.setClass(el, 'busy', st.running);
          O.setAttr(el, 'aria-pressed', st.active ? 'true' : 'false');
          O.setText(tag, st.running ? 'Starting' : (st.active ? 'Current mode' : ''));
        });
        return el;
      }).filter(Boolean);

      /* current mode strip */
      var mode = [];
      function modeCell(icon, label) {
        var value = h('div.op-mode-value'), sub = h('div.small.muted.ellipsis');
        mode.push(h('div.op-mode-cell', VF.icon(icon, 'lg'), h('div.grow', h('div.tiny.muted.op-mode-label', label), value, sub)));
        return { value: value, sub: sub };
      }
      if (displays.length) {
        var mDisp = modeCell('tv', 'Displays');
        parts.push(function () {
          var on = 0, names = {}, flags = [];
          displays.forEach(function (d) {
            var i = O.displayInfo(d);
            if (i.on) { on++; if (i.sourceName) names[i.sourceName] = true; }
            if (i.key === 'working' || i.key === 'failed' || i.key === 'offline') flags.push(i.label.toLowerCase());
          });
          O.setText(mDisp.value, on + ' of ' + displays.length + ' on');
          O.setText(mDisp.sub, flags.length ? flags[0] : Object.keys(names).join(', '));
        });
      }
      if (zone) {
        var mAudio = modeCell('volume', 'Audio');
        parts.push(function () {
          var p = cell('zones', zone.id, 'power'), v = cell('zones', zone.id, 'volume'), m = cell('zones', zone.id, 'mute'), s = cell('zones', zone.id, 'source');
          O.setText(mAudio.value, m.value === true ? 'Muted' : (p.value === 'off' ? 'Off' : (typeof v.value === 'number' ? v.value + '%' : 'Unknown')));
          O.setText(mAudio.sub, word(v) || word(m) || word(p) || (p.value === 'on' && s.value ? O.sourceName(s.value) : ''));
        });
      }
      if (lighting) {
        var mLight = modeCell('bulb', 'Lights');
        parts.push(function () {
          var c = cell('lighting', lighting.id, 'preset');
          var p = VF.byId(lighting.presets, c.value);
          O.setText(mLight.value, p ? p.name : 'Not set yet');
          O.setText(mLight.sub, p && c.status === 'commanded' ? 'sent, no feedback' : word(c));
        });
      }
      if (shades.length) {
        var mShade = modeCell('blinds', 'Shades');
        parts.push(function () {
          var vals = {}, sent = false, w = '';
          shades.forEach(function (s) { var c = cell('shades', s.id, 'position'); vals[c.value || ''] = true; if (c.status === 'commanded') sent = true; w = w || word(c); });
          var keys = Object.keys(vals);
          O.setText(mShade.value, keys.length > 1 ? 'Mixed' : (keys[0] === 'open' ? 'Open' : (keys[0] === 'closed' ? 'Closed' : 'Not set yet')));
          O.setText(mShade.sub, w || (sent ? 'sent, no feedback' : ''));
        });
      }

      /* optional blocks */
      var blocks = [];
      if (zone) {
        var ctl = O.zoneControl(zone, { variant: 'card', source: false, off: false });
        parts.push(function () { ctl.update(); });
        blocks.push(h('section.panel.pad.op-room-block', h('h4', 'Audio'), ctl));
      }
      if (lighting && VF.asList(lighting.presets).length) {
        var lightBtns = VF.asList(lighting.presets).map(function (p) {
          var b = h('button.btn.op-room-opt', { type: 'button', onclick: function () { O.send('LIGHTING_PRESET', { lightingId: lighting.id, presetId: p.id }); } }, VF.icon('bulb'), p.name);
          b._id = p.id;
          return b;
        });
        parts.push(function () {
          var c = cell('lighting', lighting.id, 'preset');
          lightBtns.forEach(function (b) { O.setClass(b, 'on', c.value === b._id && c.status !== 'failed'); });
        });
        blocks.push(h('section.panel.pad.op-room-block', h('h4', 'Lights'), h('div.op-room-opts', lightBtns)));
      }
      if (shades.length) {
        var rows = shades.map(function (s) {
          var open = h('button.btn.op-room-opt', { type: 'button', onclick: function () { O.send('SHADE', { shadeId: s.id, action: 'open' }); } }, VF.icon('arrow-up'), 'Open');
          var close = h('button.btn.op-room-opt', { type: 'button', onclick: function () { O.send('SHADE', { shadeId: s.id, action: 'close' }); } }, VF.icon('arrow-down'), 'Close');
          parts.push(function () {
            var c = cell('shades', s.id, 'position');
            O.setClass(open, 'on', c.value === 'open' && c.status !== 'failed');
            O.setClass(close, 'on', c.value === 'closed' && c.status !== 'failed');
          });
          return h('div.col.tight', shades.length > 1 ? h('div.small.muted', s.name) : null, h('div.op-room-opts', open, close));
        });
        blocks.push(h('section.panel.pad.op-room-block', h('h4', 'Shades'), rows));
      }
      if (room.showSources && displays.length && O.can('routeVideo')) {
        var routable = displays.filter(function (d) { return d.canRoute !== false; });
        var srcBtns = O.videoSources().filter(function (s) { return routable.some(function (d) { return O.canShow(d, s.id); }); }).map(function (s) {
          var b = h('button.btn.op-room-opt', { type: 'button', onclick: function () {
            if (b.disabled) return;
            b.disabled = true;
            O.route(s.id, routable.map(function (d) { return d.id; })).then(function () { b.disabled = false; });
          } }, O.sourceIcon(s), h('span.ellipsis', s.name));
          b._id = s.id;
          return b;
        });
        if (srcBtns.length) {
          parts.push(function () {
            srcBtns.forEach(function (b) {
              var showing = routable.filter(function (d) { var i = O.displayInfo(d); return i.on && i.source.value === b._id; }).length;
              O.setClass(b, 'on', showing > 0 && showing === routable.length);
            });
          });
          blocks.push(h('section.panel.pad.op-room-block.wide', h('h4', 'Source on ' + (routable.length === 1 ? routable[0].name : 'the room displays')), h('div.op-room-opts', srcBtns)));
        }
      }

      VF.mount(body,
        h('div.op-room-head', h('h1.ellipsis', room.name), ready),
        buttons.length ? h('div.op-room-buttons', { dataset: { n: String(Math.min(buttons.length, 4)) } }, buttons) : h('div.empty', 'This room panel has no button for this profile.'),
        mode.length ? h('div.panel.op-room-mode', h('h4', 'Current Mode'), h('div.op-mode-cells', mode)) : null,
        blocks.length ? h('div.op-room-blocks', blocks) : null);
      update();
    }
    function update() { parts.forEach(function (fn) { fn(); }); }

    VF.mount(host, h('div.op-room.scroll', picker, body));
    build(S.roomId);
    return { update: update };
  });
})();
