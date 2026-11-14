# VenueFlow release notes

## Build 20261114.191046 (14 November 2026)

**Readiness: SIMULATION VERIFIED.**

| Level | Standing |
| --- | --- |
| Development build | Passed |
| Simulation verified | **Yes**: 1812 automated checks and browser tests against the simulator, all passing (TEST_RESULTS.md) |
| Hardware validated | **No**: a bench run has started. On the bench controller, in Simulation, H1, the laptop part of H2 and H3 (including a driver restart on this build) passed. It has not controlled real equipment and no Navigator has opened the tile |
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
12. **No remote (cloud) features**: multi-venue overview, remote backup,
    fleet views. See SMARTBUILDOS_INTEGRATION.md for what they need.
13. **The entitlement cannot be issued yet**: the `SBOS_VENUEFLOW` SKU is not
    in the platform. With enforcement off (the default) the driver works
    fully.
14. **The driver manual has no screenshots.** This repository takes them on
    the bench, which has not been done for VenueFlow.
15. **No video-wall composition.** A video wall is one display with a custom
    route command.
16. **Floor rulers show canvas units**, not feet or metres.

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
