# VenueFlow release notes

## Source of 18 November 2026: review and audit fixes, not imported anywhere

Found by an adversarial review of the driver's code (who may change what,
whose draft it is, revisions, operations, source controls, scenes, alerts)
and by a gap audit of the wiring between the driver, Composer programming,
the SmartBuildOS Agent and smartbuildos.io. Each defect was reproduced by a
test against the old code and then fixed. **All of it is verified on the
simulator and the test shim only.** The VenueFlow suites and the whole
repository pass on this source: 2477 checks in 16 VenueFlow suites, 9534 in
133 test files (18 November 2026, TEST_RESULTS.md). No package built from
this exact source exists: the one in the build folder of the working copy
predates the last commits (the package check reports it as stale), and none
has been imported on a controller. The bench controller still runs build
`20261114.191046`, in Simulation.

| Defect | Fix |
| --- | --- |
| **A client could widen what an unsigned-in tile or a station may do.** Only the pointers to the default profile and the station profiles were installer-owned; the profile records themselves (permissions, areas, interfaces) were the client's, and anyone on the LAN acts as those profiles | The default profile and every station's profile are the installer's as whole records. A client's change, rename or removal of them, or setting or clearing their PIN, is refused with `VF_FORBIDDEN` and `data.installerOnly` ("the profile a screen or station opens with"). Other staff profiles stay the client's |
| **A client could publish or discard the installer's half-built work** when it touched only parts a client may also change (a schedule or scene the installer was still building) | Every draft save records who saved it (`installer`, `remote`, `profile:<id>`) until the next publish or discard. A client cannot publish or discard a draft holding a save by the installer or the dealer (`VF_FORBIDDEN`, "the installer has unfinished changes in the draft"; the Studio's standing gives the reason, "changes saved by the installer" or "changes saved remotely by the dealer"). A PIN set and a template applied by the installer count as installer saves |
| A draft revision number could come back with other content after a discard, a publish or a restore, so a check against a revision could pass on a different draft | The counter is stored on its own (`vf_draft_revision_v1`), never goes back, and travels in a backup (`revision`). `PUBLISH` and `DRAFT_DISCARD` accept an optional `baseRevision` and refuse a stale one with `VF_STALE_DRAFT` |
| A save made with no draft (the installer's or a remote one) dropped every staff PIN | PINs are taken from what is published when there is no draft |
| An operation partly outside a profile's access kept its original label ("Sports 2 to 5 displays") and `origin`, which names a profile or a station | The label is counted over what the profile sees, and `origin` is no longer sent to a profile (state document and `OPERATION_GET`; an installer's `OPERATION_GET` is unchanged) |
| A publish in the middle of a favourite channel cut the number off, leaving a box half-dialled | The channel finishes unless that source's Control4 device or the control mode changed; a stop is logged in Diagnostics (`VF_CANCELLED`) |
| Stopping a run reported a command it had already sent as "stopped before it was sent" when the run had asked for the same value twice | The sent command keeps its place and its outcome is reported |
| `SCENE_ACTIVATE` with an area outside the profile's access ran the scene's "not pressed in that area" branch | Refused with `VF_FORBIDDEN` |
| `ALERT_DISMISS` removed any stored alert by id, also one the profile is not shown | Only an alert the profile is shown as dismissable; any other id answers `VF_NOT_FOUND` |
| The Alerts property, the variable `ALERT_COUNT` and the conditional *VenueFlow has alerts* counted three different things; *Alert Raised* never fired for a display that did not confirm | One definition: every current alert, stored and detected, a muted zone excluded. *Alert Raised* fires for each stored alert and once when a detected one appears |
| A rollback did not fire *Configuration Published*, and its record and the `venueflow.config.published` event named the version restored rather than the new live one | It fires; `versionId` is the new live version and `restoredFrom` the version whose content came back |
| The two true-or-false conditionals ignored the choice made in Composer | They read it: "Venue is closed" and "VenueFlow has alerts: clear" work as written. How Composer passes the choice is not yet seen on a controller |
| *Trigger the VenueFlow event* under a restricted licence reported success while no rule ran | Refused, with Last Error `TRIGGER_EVENT refused: licence restricted: N rule(s) not run` |
| `refresh_status` answered with nothing useful and the module always reported `config_version` "0" | It answers with a one-line summary (at most 200 characters) and sends a status frame at once with that line, counters and `config_version`: the published version the controller runs, or `none` |
| The Agent's updater and its SKU-to-file list did not name VenueFlow | `smartbuildos-venueflow.c4z` is in both. The store's publish workflow does not name VenueFlow yet, so the updater has nothing to fetch until a package is published to the store |

Also new: a package check that fails when a locally built package is older
than its sources.

**What an installer will notice.** A client signed in to the Venue Studio
can no longer touch the tile's profile or a station's profile. Saving a
change, setting a PIN or applying a template makes the draft yours until you
publish or discard it, and the client waits for you. A backup now carries
the revision counter.

**What a venue will notice.** In the Venue Studio, a change to a profile the
screens open with is refused as installer-only, and "Your installer has
unfinished changes" appears whenever the installer, or the dealer
remotely, has saved work that is not published. A favourite being dialled is
no longer cut short by a publish.

**What a programmer will notice.** *Configuration Published* on a rollback;
ALERT_COUNT and *VenueFlow has alerts* now include detected alerts (and no
longer a muted zone); *Alert Raised* fires when a display stops confirming;
the "closed" and "clear" choices work; a refused *Trigger the VenueFlow
event* writes Last Error.

**Known and not changed.** Scenes and schedules cannot tune a channel.
A remote draft can replace the whole configuration, device mapping and
device commands included, and with "Draft and publish" put it live; whether
it should be able to is an open owner decision (SECURITY_REVIEW.md). Two weaknesses of the
shared module client are recorded in SECURITY_REVIEW.md, residual risks 8
and 9. The manual has no screenshots.

**Still not verified.** Everything above on a controller, in Composer
programming and on a touch screen. The new hardware checks are in
HARDWARE_VALIDATION.md, "Not yet run".

## Source after build 20261114.233926 (15 November 2026): review fixes, not built

Six defects found by the automated review of the VenueFlow pull request,
each reproduced by a new test against the old code and then fixed. **No
package was built from this source and none of it has run on a controller.**
The readiness table below still describes build `20261114.233926`, which has
all six defects.

| Defect | Fix |
| --- | --- |
| **A sample venue left in the draft could be test-driven in Live mode.** Test Power, Test Route and Test Source acted on the draft without the sample check that stops a published sample, so they addressed the sample's invented Control4 ids in the real project | `TEST_DEVICE` answers `VF_SIMULATION_ONLY` for a sample draft in Live, Query Status included; nothing is read or sent |
| Two rules watching the same Control4 variable: only the last one fired. A rule on a mapped room's variable silenced that room's feedback | The adapter keeps one callback per device and variable and calls every watcher from it |
| Stopping a scene stopped its remaining steps, but the commands its current step had queued kept reaching Control4. After All Off, a stopped scene's queued routes could arrive and bring displays back on | Stopping a run removes its unsent commands from the queue; the displays go back to what was known before. A command already sent, or one a manual request also asked for, is left alone |
| Any signed-in operator could read any operation by its id (`op1`, `op2` ...), including displays and zones outside their profile | `OPERATION_GET` returns only the targets the profile may see, with counts over those; an operation it can see none of answers as not found. The state document's counts are filtered the same way |
| A schedule falling due within 20 seconds of a driver start or a publish was skipped | The scheduler's baseline is set when it is installed and carried across a publish. Downtime is still not replayed |
| A display or zone remapped to other hardware kept the old hardware's confirmed readings, indefinitely if the new mapping gave no feedback | State is kept across a publish only where the mapping is unchanged; otherwise it starts again as unknown |

Hardware checks these add are in HARDWARE_VALIDATION.md, "Not yet run".

## Build 20261114.233926 (14 November 2026)

**Readiness: SIMULATION VERIFIED.**

| Level | Standing |
| --- | --- |
| Development build | Passed |
| Simulation verified | **Yes**: 2176 automated checks and browser tests against the simulator, all passing for this build (TEST_RESULTS.md; 2282 on the source with the review fixes above) |
| Hardware validated | **No**: a bench run has started. On the bench controller, in Simulation, H1, the laptop part of H2 and H3 (including a driver restart) passed, on build `20261114.191046`. **This build has not been on a controller.** Nothing has controlled real equipment and no Navigator has opened the tile |
| Production ready | **No**: needs HARDWARE_VALIDATION.md H1 to H9 to pass |

Do not install this build at a customer site. Import it on a bench system
only, in Simulation mode first.

### What is in it

- **One driver**, `smartbuildos-venueflow.c4z` (SKU `SBOS_VENUEFLOW`): a UI
  Button tile, a LAN relay on port 47861, and two pages compiled into the
  driver.
- **Four operator interfaces** on the tile: Visual Floor Plan, Command
  Center, Simplified Room Control, Manager Overview, all on one control
  engine and one device registry.
- **Installer Studio** at `http://<controller>:47861/studio`: Overview, Setup
  Wizard (six steps), Devices (discovery, mapping, test actions), Sources,
  Audio Zones, Layout Designer, Display Groups, Lighting and Shades, Room
  Panels, Scenes, Visual Programming, Scheduling, Staff Profiles, Stations,
  Diagnostics, Licensing, Configuration Backup, Publish and Rollback.
- **Video routing engine**: per-display route strategy (Control4 room
  selection, a custom command, or none), one outcome per display, commands
  serialised, newer requests replace waiting ones, confirmation from
  Control4's room state.
- **Audio zones** independent of video: source, volume with limits, mute,
  power, presets, optional "listen" on a route.
- **Visual programming**: scenes and rules from a fixed vocabulary (14 step
  kinds, 13 condition kinds, 8 trigger kinds), validation, dry run, live test
  with per-step and per-device results, execution log, overlap protection.
- **Schedules** on the controller's clock, with defined behaviour across
  daylight-saving changes and downtime.
- **Staff profiles** (seven role templates) with permissions enforced in the
  driver; PIN sign-in; stations (a fixed screen opens as its own profile).
- **Venue Studio for the client**: a staff profile that holds the Venue
  Studio permission (the Owner role by default) opens the Studio with its
  PIN, on the Control4 tile or on the page, and changes scenes, schedules,
  staff and PINs, source names and channel labels and volume presets, and
  publishes that. Everything else stays the installer's; the driver enforces
  it.
- **Basic source controls**: a source can have channel up, down and last, a
  number keypad, arrows with guide, info and menu, and transport keys, plus
  up to 24 favourite channels dialled with one press. A cable or satellite
  source starts with channel keys and a keypad. Staff open a source's
  remote from the source list; the venue edits favourites in the Venue
  Studio.
- **Remote Management** (driver side only): a property, Off by default, that
  lets smartbuildos.io read the configuration and fill the draft, or also
  publish and roll back, through the SmartBuildOS Agent.
- **Configuration**: draft, published and five previous versions; backup and
  restore; schema version 1 with migration support.
- **Licensing** through the SmartBuildOS Agent; fail open; a restriction never
  stops manual control or switches anything off.
- **Simulation mode** (the default): a simulated project, two reference
  venues, fault injection.
- **Composer surface**: 5 commands, 8 events, 4 variables, 3 conditionals,
  8 actions.

### Known limitations

1. **Not run against real equipment.** On the bench controller the driver
   installs, serves both pages whole (large replies from the driver's socket
   work), stores a 478 kB picture and brings its configuration back after a
   driver restart. Still unverified: the tile loading on a Navigator, the
   room commands changing a room, the feedback variables, a restart of the
   controller itself, a daylight-saving change.
2. **Room mute** (`MUTE_ON` / `MUTE_OFF`) is the least certain command: it is
   in neither the official documentation nor Control4's published code.
3. **The Navigator JavaScript bridge** is implemented as the fallback
   transport and is unverified; the LAN relay is the transport.
4. **LAN only, plain HTTP.** The pages work on the venue network. A PIN or
   the Installer Passcode crosses that network in clear. Keep control screens
   off the guest network (SECURITY_REVIEW.md).
5. **The pages are large** (operator about 180 kB, Studio about 540 kB),
   served in one reply each. If a controller's socket cannot deliver that,
   the pages must be split into several requests (not built).
6. **Engine floor Gecko 96.** The pages are written for it but were tested
   only in Chromium.
7. **Schedules use the controller's time zone.** There is no separate venue
   time zone.
8. **Diagnostics are kept in memory** (the newest 400 entries) and start
   empty after a restart. The Flight Recorder, when present, keeps history.
9. **A custom route, device power, lighting and shades give no feedback**:
   their state shows "sent", never "confirmed".
10. **A venue's audio independence depends on its hardware.** VenueFlow flags
    a display and a zone that share a Control4 room; it cannot make a
    single-zone amplifier play two things.
11. **Composer command parameters are typed, not picked from a list** (scene
    and source names).
12. **Remote management has never run end to end.** The driver side is
    tested against the simulator. The smartbuildos.io side (System Studio,
    Drivers & Licenses, VenueFlow, a status route and the module contract)
    was merged and deployed on 15 November 2026. No controller has received
    an operation from the platform: the bench controller runs build
    `20261114.191046`, which has no Remote Management, and its Agent (built
    from `main` on 18 November 2026) allows the `venueflow` module, but no
    VenueFlow registration with it has been watched. Multi-venue overview,
    remote backup and fleet views are not built. See
    SMARTBUILDOS_INTEGRATION.md.
13. **The entitlement cannot be issued yet**: the catalogue-row migration
    for `SBOS_VENUEFLOW` exists on smartbuildos.io but the owner has not
    applied it, so no licence can be issued for the SKU and there is no
    store or product page. With enforcement off (the default) the driver
    works fully.
14. **The driver manual has no screenshots.** This repository takes them on
    the bench, which has not been done for VenueFlow.
15. **No video-wall composition.** A video wall is one display with a custom
    route command.
16. **Floor rulers show canvas units**, not feet or metres.
17. **The Venue Studio on a Navigator is untested.** It was checked in a
    desktop browser against the simulator. A PIN of 4 to 8 digits now guards
    day-to-day configuration, with the same lockout as any PIN; give the
    permission to as few profiles as the venue needs.
18. **PINs cannot be set remotely**, by design.
19. **Source controls are unproven on hardware.** The command names are the
    ones Control4 documents for its Satellite, Tuner, TV, DVD and Media
    Player proxies; there is no published page for a cable box, which is
    assumed to follow the Satellite set. That a command sent by this driver
    to a source's device reaches the box is not documented and has not been
    seen on a controller. There is no feedback: VenueFlow never knows what
    channel a box is on, and a key changes every screen showing that source.
    Scenes and schedules cannot change a channel yet.

### Changed since build 20261114.191046

- **The Studio has two doors.** The installer signs in with the Installer
  Passcode, as before. The venue's own people sign in with a staff PIN when
  their profile holds the new Venue Studio permission. A client sees seven
  sections (Home, Channels and Names, Volume Presets, Scenes, Scheduling,
  Staff Profiles, Publish) and the driver refuses a client's change to
  anything else, whatever the page sends.
- **The Studio opens on the tile.** The control page's profile menu has a
  Venue Studio entry; it opens in the same view and takes the PIN session
  along. Not yet tried on a touch screen or in the Control4 app.
- **A client is not asked about warnings that are already live**, only about
  one their own change brings. A client cannot publish or discard a draft
  that holds the installer's unfinished work, and can roll back only across
  their own changes.
- **Sources have a channel label** ("ESPN 206"), a note shown beside the
  name. It does not change the channel.
- **Sources have basic controls.** The installer picks the groups per source
  (channel, keypad, navigation, transport); a cable or satellite source in an
  existing configuration gains channel keys and a keypad by default. A new
  permission, "Use source controls", decides who sees the remote (on for
  Installer, Owner, Manager and Bartender in the templates; off for profiles
  in an existing configuration until someone switches it on). The page names
  a key from a fixed list of 33; the driver turns it into the documented
  Control4 command (`PULSE_CHANNEL_UP`, `NUMBER_0` to `NUMBER_9`, `ENTER`,
  `RECALL` and so on) and sends it to the source's own device. A favourite is
  dialled as its digits 350 ms apart, then Enter.
- **Remote Management property** (Off, Draft only, Draft and publish) and
  Remote Management Status. The driver registers with the Agent as the
  `venueflow` module, answers `snapshot`, `save_draft`, `publish`, `rollback`
  and `refresh_status`, and reports each new live version. The configuration
  snapshot travels as base64 groups, the one form neither the Agent's nor
  the platform's redaction rewrites. **Not connected end to end:** when
  this build was made the smartbuildos.io side was on a branch; it was
  merged on 15 November 2026, and the two have still never run together
  with a controller (limitation 12).
- The Agent driver gains one allowlist entry for these commands and the
  event envelope one prefix (`venueflow.`). Both are on `main`; neither has
  been exercised with a controller.
- The published summary records who published (`installer`, `remote` or
  `profile:<id>`).

### Changed since build 20261114.061304

Three defects found on the bench controller, each with a test:

- A picture upload refused for want of an Installer Studio session no longer
  carries installer `detail` in its reply.
- A wrong Installer Passcode is answered with its own code,
  `VF_BAD_PASSCODE`, "That passcode is not right." (it used the PIN code and
  wording).
- In Simulation, publishing a version keeps what the simulated devices were
  doing, as a real project's rooms would. It used to reset every simulated
  display to Off while the Active Scene label stayed.

### Upgrade and rollback

First release: nothing to migrate. A configuration is stored with
`schema: 1`. Removing the driver removes its stored configuration; export a
backup first.

### Files

| Deliverable | Where |
| --- | --- |
| Driver package | `dist/oss/smartbuildos-venueflow.c4z` (`make venueflow`) |
| Driver source | `drivers/smartbuildos-venueflow/`, `src/venueflow/` |
| Page sources | `ui/venueflow/` |
| Build and development tools | `Makefile` (targets `venueflow`, `venueflow-ui`, `venueflow-test`, `venueflow-dev`), `tools/venueflow-*.{py,lua}`, `tools/embed-pages.lua` |
| Test suites | `test/test_venueflow_*.lua`, `test/venueflow_harness.lua` |
| Configuration schema | `DATA_MODEL.md`, `schema/vocabulary.json`, `schema/protocol.json` |
| Sample venues | `samples/sports-bar.json`, `samples/conference-center.json`, `samples/blank-restaurant.json` |
| Guides | `INSTALLER_GUIDE.md`, `PROGRAMMER_GUIDE.md`, `OPERATOR_GUIDE.md`, `TROUBLESHOOTING.md` |
| Integration | `SMARTBUILDOS_INTEGRATION.md` |
| Architecture and research | `ARCHITECTURE.md`, `SDK_RESEARCH.md`, `PROTOCOL.md` |
| Verification | `TEST_RESULTS.md`, `SECURITY_REVIEW.md`, `HARDWARE_VALIDATION.md`, `VENUEFLOW_IMPLEMENTATION_CHECKLIST.md` |
| Manual shown in Composer | `drivers/smartbuildos-venueflow/www/documentation/index.md` |
