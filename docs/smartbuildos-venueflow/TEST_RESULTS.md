# VenueFlow test results

Run on 14 November 2026 on macOS with LuaJIT, against build
`20261114.191046` of `smartbuildos-venueflow.c4z`.

**Everything here ran against the simulator (`src/venueflow/sim.lua`), the
test shim (`test/c4_shim.lua`) with a scripted Director, or a desktop
browser. Nothing in this file ran on a Control4 controller.** A check that
says a display was "confirmed" means the simulator reported the change.
What was run on the bench controller is in HARDWARE_VALIDATION.md, Results.

## Automated suites

```bash
make venueflow-test
```

| Suite | Checks | Failed | What it covers |
| --- | --- | --- | --- |
| `test_venueflow_routing.lua` | 100 | 0 | single and multi-display routes, invalid destinations, unsupported sources, the six-display partial result, every state class, serialisation, supersession, repeated requests, custom routes, power, outside feedback |
| `test_venueflow_audio.lua` | 93 | 0 | audio independence from video, "listen" routes, volume limits, presets, mute, zone power, refusals, lighting and shades as "commanded", shared-room validation |
| `test_venueflow_rules.lua` | 145 | 0 | scene execution, Game Day end to end, partial runs, dry run sends nothing, every condition and logic operator, IF / ELSE, waits, cancel, overlap protection, every trigger kind, validation (unknown steps, references, cycles, limits), runner bounds, the log |
| `test_venueflow_scheduler.lua` | 38 | 0 | once per day and time, midnight, restart, downtime not caught up, clocks forward, clocks back, a clock set back by hand, upcoming runs, schedules in the core, licence pause |
| `test_venueflow_permissions.lua` | 245 | 0 | what each profile receives, refusal per display, source, zone and scene, forged identity, every command unauthenticated, PIN sign-in and lockout, session expiry and revocation, Studio sign-in, no default profile, stations |
| `test_venueflow_store.lua` | 122 | 0 | empty driver, templates never overwrite silently, draft saves and stale saves, publish and acknowledgements, rollback, bounded history, discard, pictures, backup and restore on a second driver, migration, driver restart |
| `test_venueflow_relay.lua` | 257 | 0 | HTTP parsing across chunks, the chunked receiver, every route, security headers, identity over HTTP, every command closed to an unauthenticated caller, the raw picture upload, invalid payloads, state delivery |
| `test_venueflow_core.lua` | 209 | 0 | both reference venues, a publish keeping simulated device state, the room-panel profile, All Off and confirm-required scenes, alerts and Resolve, installer test actions, discovery, Composer commands, control mode (sample refused in Live), the diagnostic log (bounded, redacted) |
| `test_venueflow_license.lua` | 55 | 0 | the licensing SDK's decision table, a venue through a cloud outage and with no Agent, a definitive denial (automation stops, control does not, nothing switched off), restore |
| `test_venueflow_schema.lua` | 102 | 0 | defaults, identifiers, every class of error and warning, publishability, mapping integrity under layout changes and deletion |
| `test_venueflow_driver.lua` | 120 | 0 | `driver.lua` under the shim: start, Agent registration, the socket, the Navigator bridge, Live-mode commands and variable listeners, Composer commands and conditionals, the licence gate, passcode change, actions, restart |
| `test_venueflow_security.lua` | 326 | 0 | no code evaluation in engines or pages, pages self-contained, no credential in what ships, built pages and embedded modules current, the `.c4z` contents and integrity |
| **Total** | **1812** | **0** | |

The brief's seventeen required cases map to these suites:

| Case | Suite |
| --- | --- |
| Single-display routing | routing "single display" |
| Multi-display routing | routing "multi display" |
| Invalid destinations | routing "invalid destinations and unsupported sources" |
| Unsupported sources | routing, same section |
| Partial routing failures | routing "partial success, reported per display" |
| Audio independence | audio "audio is independent of video" |
| Scene execution | rules "Game Day" |
| Conditional logic | rules "conditions and logic" |
| Permission enforcement | permissions "refusals" |
| Unauthorized commands | permissions "forged identity", "unauthenticated"; relay "identity" |
| Device-state changes | routing "feedback from outside VenueFlow"; rules "triggers" |
| Configuration persistence | store "draft", "publish", "driver restart" |
| Configuration rollback | store "rollback" |
| Driver restart behaviour | store "driver restart"; driver [11] |
| Simulated cloud outage | license "cloud outage: the venue is unaffected" |
| Conflicting commands | routing "conflicting commands"; rules "overlapping runs" |
| Invalid command payloads | relay "invalid payloads" |

## The whole repository

```bash
make test
```

Exit code 0. 126 test files. The suites that print a total add up to 8567
checks passed, 0 failed. This includes the repository guards the new driver
must pass: driver XML structure, licensing through the Agent, every
`require` at module scope, locals declared before use, and embedded pages
matching their sources.

## Static checks

| Check | Command | Result |
| --- | --- | --- |
| Lua formatting | `stylua --check` over `src/venueflow`, the driver, the suites and the tools | clean |
| Python formatting | `black --check tools/venueflow-ui.py tools/venueflow-dev.py` | clean |
| Page sources parse | `node --check` on each of the 12 `.js` files under `ui/venueflow` | all parse |
| Built pages current | `python3 tools/venueflow-ui.py check` | current |
| Embedded pages current | `luajit tools/embed-pages.lua --check` | current |
| Generated samples and schema current | `luajit tools/venueflow-samples.lua --check` | current |
| Secrets | `gitleaks dir` over every VenueFlow file (2.93 MB) | no leaks found |

## Package

```bash
make venueflow
```

| | |
| --- | --- |
| File | `dist/oss/smartbuildos-venueflow.c4z` |
| Size | 593,433 bytes |
| Version | `20261114.191046` |
| SHA-256 | `f939bdc58349c672a8d19c2aed81dafe4ac5303a1410f7a42655dfe5aeb6752f` |
| Contents | `driver.xml`, `driver.lua` (squished, 38 modules), `www/app/index.html`, `www/studio/index.html`, `www/documentation/index.html` and `index.md`, seven icons |
| Integrity | `unzip -t` passes; no absolute or parent path; the squished driver loads under the shim and defines its handlers |

This build was imported on the bench controller as an update of build
`20261114.061304` and runs there in Simulation (HARDWARE_VALIDATION.md,
Results).

## Browser tests

Chromium (the desktop app's browser pane), driving the real Lua core and
relay through `tools/venueflow-dev.py`, on the sports bar and the
conference centre, at 1280x800 and 1024x768 (operator page also at 390x844).
No console errors from the pages.

Operator page:

- Tile opens as the default profile (Bartender: the bar's eight displays);
  PIN sign-in with a right and a wrong PIN; lockout countdown; sign out.
- Command Center: select, choose a source, route; tiles go working then
  confirmed; source-first mode; filters; power; zone volume, mute, source,
  preset.
- Floor Plan: drawn from the configuration, cropped to what the profile can
  see; select by display, area and group; route; "listen"; a floor picture.
- Room Control (conference centre): the four scene buttons, volume, lighting
  presets, shades.
- Manager: counts, area summaries, scenes, alerts with Resolve, Unmute and
  Dismiss, venue open and close, All Off with its preview, recent activity.
- A partial route reported per display; a silent display ending "not
  confirmed" after about eight seconds and appearing as a manager alert.
- Restricted licence (development host flag): banner, scene refused, manual
  route still working.

Installer Studio (all 18 sections draw):

- Sign-in; empty state into the wizard; templates with the overwrite
  confirmation; floors and areas; discovery; hand-off to the other sections
  and back.
- Devices: add from discovered, map by hand, Test Route ending confirmed and,
  with a simulator fault, not confirmed; delete with references listed.
- Sources, Audio Zones, Display Groups, Lighting and Shades, Room Panels,
  Staff Profiles (PIN set and removed; only `hasPin` reaches the page),
  Stations (a tile from the station's address opens as its profile).
- Layout Designer: drag, resize, rotate, lock, snap, grid, zoom, pan, fit,
  marquee, nudge, undo and redo, new area, label and scene button, remove
  from the plan and place again with the Control4 room unchanged, picture
  upload, second floor, preview as a profile.
- Visual Programming: Game Day read back; a new scene built with a route, a
  volume, a wait and an IF / ELSE; validate; dry run with no command sent;
  execute with step chips going from sent to done, and partial with a fault;
  one rule per trigger kind; a schedule created and listed.
- Publish with acknowledgement, rollback, discard; backup export and restore
  (pictures sent separately); diagnostics filters; simulator faults.
- A 306 kB floor picture stored in 48 ms through the raw upload route. (The
  route exists because the repository's JSON decoder is quadratic on long
  strings: decoding a request holding a 300 kB string measured 2.5 s, and
  600 kB measured 10.4 s, in LuaJIT on this machine.)

Not covered by any browser test: Gecko 96 (the touch screens' engine), a
real touch screen, the Control4 apps, the Navigator bridge transport, a real
pointer drag on a slider, the native file chooser, a backup file landing on
disk, and pinch gestures (synthetic events only).

## Exclusions

1. **No controller.** Driver installation, the WebView in a Navigator, real
   room commands, real feedback, real persistence limits, a controller
   restart, a real network drop and a real daylight-saving change are all in
   HARDWARE_VALIDATION.md and all untested.
2. **The daylight-saving tests** use a scripted clock: they prove the
   arithmetic.
3. **The shim's HMAC** is a deterministic stand-in, not SHA-256.
4. **The driver suite's Director** is scripted: it shows which commands the
   driver sends (`SELECT_VIDEO_DEVICE` to room 1101 with `deviceid = 3001`),
   not what a controller does with them.
