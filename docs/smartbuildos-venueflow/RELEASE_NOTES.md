# VenueFlow release notes

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
    tested against the simulator and the smartbuildos.io side is built on the
    web repository's branch `codex/venueflow-studio` (unit-tested, not
    merged), but no controller has received an operation from the platform,
    so nothing can be managed remotely today. Multi-venue overview,
    remote backup and fleet views are not built either. See
    SMARTBUILDOS_INTEGRATION.md.
13. **The entitlement cannot be issued yet**: the `SBOS_VENUEFLOW` SKU is not
    in the platform. With enforcement off (the default) the driver works
    fully.
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
  the platform's redaction rewrites. **Not connected end to end:** the
  smartbuildos.io side is on an unmerged branch of the web repository, and
  the bench Agent does not know the module.
- The Agent driver gains one allowlist entry for these commands and the
  event envelope one prefix (`venueflow.`). Both are inert until the
  platform side exists.
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
