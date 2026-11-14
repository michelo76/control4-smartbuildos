/* Installer Studio: Stations (staff device access). A station is a fixed screen,
   known by its LAN address, that opens as its own staff profile instead of the
   default one. Only a profile WITHOUT a PIN can be given to a station: an address
   is not a secret, so it may choose which open profile a screen gets and nothing more. */
(function () {
  'use strict';
  var h = VF.h, icon = VF.icon;
  var selected = null;

  function openProfiles() { return Studio.list('profiles').filter(function (p) { return !p.hasPin; }); }

  function render(container) {
    if (!Studio.hasDraft()) { Studio.emptyDraft(container); return; }
    var stations = Studio.list('stations');
    var profiles = openProfiles();
    var current = VF.byId(stations, selected) || stations[0] || null;
    selected = current ? current.id : null;

    var add = h('button.btn.primary', { type: 'button', disabled: !profiles.length, onclick: function () {
      var id = Studio.freshId('stations', 'Station');
      selected = id;
      Studio.update('Add station', function (c) { c.stations.push({ id: id, name: 'New station', address: '', profileId: profiles[0].id }); });
    } }, icon('plus'), 'Add station');

    var list = h('div.list');
    stations.forEach(function (st) {
      list.appendChild(h('div.item.clickable' + (st.id === selected ? '.sel' : ''), { onclick: function () { selected = st.id; Studio.refresh(); } },
        icon('monitor'),
        h('div.grow', h('div.ellipsis', st.name), h('div.small.muted.ellipsis', (st.address || 'no address yet') + ' opens as ' + Studio.nameOf('profiles', st.profileId))),
        Studio.issueChip('station', st.id)));
    });
    if (!stations.length) list.appendChild(h('div.empty', 'No stations. Every tile opens as the default profile chosen under Staff Profiles.'));

    var editor;
    if (current) {
      var set = function (label, fn) { Studio.update(label, function (c) { var s = VF.byId(c.stations, current.id); if (s) fn(s); }); };
      editor = h('div.panel.pad.col',
        h('div.row.between', h('h2', current.name), h('button.btn.sm.danger', { type: 'button', onclick: function () { Studio.confirmRemove('station', current.id, 'station').then(function (ok) { if (ok) selected = null; }); } }, icon('trash'), 'Delete')),
        Studio.issueList(Studio.issuesFor('station', current.id)),
        h('div.form',
          Studio.text('Name', current.name, function (v) { set('Rename station', function (s) { s.name = v || s.name; }); }, { hint: 'For example "Bartender tablet" or "Host station".' }),
          Studio.text('LAN address', current.address, function (v) { set('Station address', function (s) { s.address = v; }); }, { placeholder: '192.168.1.52', inputmode: 'decimal', max: 15, hint: 'The screen\'s IPv4 address. Reserve it in the router so it does not change.' }),
          Studio.select('Opens as', profiles.map(function (p) { return { value: p.id, label: p.name }; }), current.profileId, function (v) { if (v) set('Station profile', function (s) { s.profileId = v; }); }, { hint: 'Only profiles without a PIN are listed.' })),
        h('div.banner.info', icon('info'), h('div.small',
          h('div', 'A tile opened from this address shows what that profile may see, with no sign-in. Any other tile opens as the default profile.'),
          h('div', 'An address can be imitated on the venue network, so a station can never be given a profile that needs a PIN. Staff with a PIN still sign in on any screen.'))));
    } else {
      editor = h('div.panel.pad', h('p.muted', profiles.length ? 'Add a station to give one screen its own profile.' : 'Every staff profile has a PIN. A station needs a profile without one.'));
    }

    VF.mount(container,
      Studio.sectionHead('Stations', 'Give a fixed screen (a bar tablet, a host stand, a meeting-room panel) its own staff profile by its network address.', [add]),
      h('div.split', h('div.col', list), editor));
  }

  Studio.register({ id: 'stations', title: 'Stations', icon: 'monitor', group: 'Access', order: 2, render: render,
    badge: function () { var n = Studio.list('stations').length; return n || null; } });
})();
