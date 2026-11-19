# VenueFlow test results

First run on 14 November 2026 on macOS with LuaJIT, against build
`20261114.233926` of `smartbuildos-venueflow.c4z`.

**The counts below are those of 19 November 2026 before the owner
decisions of that day (on-site-only mapping, the tune step, shade levels).
Their suites are described here; the counts are refreshed in the next
run.**

**Automated suites and the whole repository: run again on 19 November 2026**
on the source of that day (branch `vf/docs-final`, which holds the review
and audit fixes of 15 and 18 November 2026 and the page follow-ups of 19
November 2026, RELEASE_NOTES.md). The suites were run with no package in
the build folder, as in a clean checkout and in CI, so the security suite's
package checks were skipped. No package built from
this source exists, so the browser tests and the package section further
down still describe build `20261114.233926`.

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
| `test_venueflow_routing.lua` | 111 | 0 | single and multi-display routes, invalid destinations, unsupported sources, the six-display partial result, every state class, serialisation, supersession, repeated requests, custom routes, power, outside feedback; stopping a run does not report a command it already sent as stopped |
| `test_venueflow_audio.lua` | 93 | 0 | audio independence from video, "listen" routes, volume limits, presets, mute, zone power, refusals, lighting and shades as "commanded", shared-room validation |
| `test_venueflow_rules.lua` | 174 | 0 | scene execution, Game Day end to end, partial runs, dry run sends nothing, every condition and logic operator, IF / ELSE, waits, cancel, overlap protection, every trigger kind, validation (unknown steps, references, cycles, limits), runner bounds, the log; stopping a run stops its queued commands (also under All Off, and not a command a manual request shares); a schedule due just after a start or a publish; the tune step (validation, run, stop, overlap by source) |
| `test_venueflow_scheduler.lua` | 49 | 0 | once per day and time, midnight, restart, downtime not caught up, clocks forward, clocks back, a clock set back by hand, upcoming runs, schedules in the core, licence pause; the baseline set at install and carried across a publish |
| `test_venueflow_permissions.lua` | 249 | 0 | what each profile receives, refusal per display, source, zone and scene, forged identity, every command unauthenticated, PIN sign-in and lockout, session expiry and revocation, Studio sign-in, no default profile, stations; operation detail by id filtered by the profile's access; partly visible operations (label, no `origin`); a scene's area; dismissing only alerts the profile is shown |
| `test_venueflow_store.lua` | 144 | 0 | empty driver, templates never overwrite silently, draft saves and stale saves, publish and acknowledgements, rollback, bounded history, discard, pictures, backup and restore on a second driver, migration, driver restart; revisions never repeat (discard, publish, restore); PINs kept when there is no draft |
| `test_venueflow_relay.lua` | 259 | 0 | HTTP parsing across chunks, the chunked receiver, every route, security headers, identity over HTTP, every command closed to an unauthenticated caller, the raw picture upload, invalid payloads, state delivery |
| `test_venueflow_core.lua` | 273 | 0 | both reference venues, a publish keeping simulated device state, the room-panel profile, All Off and confirm-required scenes, alerts and Resolve, installer test actions, discovery, Composer commands, control mode (sample refused in Live), the diagnostic log (bounded, redacted); mapping tests refused on a sample draft in Live; state across a publish that remaps a display; `ALERT_DISMISS` and the venue's count; the alert timer across a stop and a restart, and across a publish that removes a display; stored alerts not shown to a profile that cannot see what they concern |
| `test_venueflow_license.lua` | 64 | 0 | the licensing SDK's decision table, a venue through a cloud outage and with no Agent, a definitive denial (automation stops, control does not, nothing switched off), restore; the venue status set under a restricted licence with the rules not run counted |
| `test_venueflow_schema.lua` | 102 | 0 | defaults, identifiers, every class of error and warning, publishability, mapping integrity under layout changes and deletion; tune step validation; shade levels |
| `test_venueflow_driver.lua` | 233 | 0 | `driver.lua` under the shim: start, Agent registration, the socket, the Navigator bridge, Live-mode commands (including the shade's `SET_LEVEL_TARGET`, a lighting preset's exact parameters, `MUTE_OFF`) and variable listeners, Composer commands and conditionals (both choices of the true-or-false ones), the one alert count and *Alert Raised*, *Configuration Published* on a rollback, Last Error for a refused or partly run command, the licence gate, passcode change, actions, the Remote Management switch and the Agent token, `save_draft`, `publish`, `rollback` and `refresh_status` through the driver with the status frame and `config_version`, restart |
| `test_venueflow_security.lua` | 303 | 0 | no code evaluation in engines or pages, pages self-contained, no credential in what ships, built pages and embedded modules current. The package checks (the `.c4z` contents and integrity, and since 18 November whether the package is older than its sources) run only when a package is built, and were skipped here |
| `test_venueflow_clientstudio.lua` | 217 | 0 | the Venue Studio as a client gets it: who may open it, what a client may change and publish, every installer-owned part refused to a hand-made request, installer-only commands, the installer's unfinished draft, rollback, losing the permission, live warnings not asked again; the profiles a screen or station opens with; whose work is in the draft; PINs and templates refused or attributed; a tune step in the client's hands |
| `test_venueflow_remote.lua` | 80 | 0 | Remote Management in the core: off, draft only, draft and publish; a remote draft cannot overwrite on-site work; publish only what was reviewed; no PIN material leaves; nothing remote controls equipment; since 19 November, device mapping and device commands on site only (save, publish, rollback; the installer's draft work; the base with no draft; the bounded refusal). The Agent and the platform are not in this test |
| `test_venueflow_sourcecontrol.lua` | 146 | 0 | basic source controls: the closed key vocabulary and the Control4 command each key becomes, a page naming anything else, who may press, groups per source, an unmapped source, favourites dialled digit by digit in order and spaced, a box that does not answer, a flood of keys, the schema, a client editing favourites but not the controls; a publish, and a change of control mode, while a channel is being dialled. "Sent" means the simulator logged the command; the tune step's way into the engine (dry runs, runs, a source without a keypad, the pause after a cut-off number) |
| `test_venueflow_engine_floor.lua` | 66 | 0 | a static scan of every page source and both built pages for features Firefox 96 (the touch screens' Gecko 96) lacks, from a deny-list with the Firefox version that shipped each; none found. It runs nothing in Gecko: a pass means none of the listed features appears |
| `test_venueflow_adapter.lua` | 27 | 0 | the Control4 adapter's variable listeners against a scripted Director that keeps one callback per pair: two rules on one variable, a rule on a mapped room's variable, a republish, an unmapped room, the first call on registration, a watcher that fails |
| **Total (17 suites, 19 November 2026)** | **2590** | **0** | |

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

Exit code 0. 134 test files. The suites that print a total add up to 9647
checks passed, 0 failed (19 November 2026, on the source of that day, with
no package in the build folder). This includes the repository guards the new driver
must pass: driver XML structure, licensing through the Agent, every
`require` at module scope, locals declared before use, and embedded pages
matching their sources.

## Static checks

Run on 14 November 2026 for build `20261114.233926`; the rows marked
"18 Nov" or "19 Nov" were run again on the source of that day.

| Check | Command | Result |
| --- | --- | --- |
| Lua formatting | `stylua --check` over `src/venueflow`, the driver, the suites and the tools | clean |
| Python formatting | `black --check tools/venueflow-ui.py tools/venueflow-dev.py` | clean |
| Page sources parse | `node --check` on each `.js` file under `ui/venueflow` | 18 Nov: all 13 parse |
| Built pages current | `python3 tools/venueflow-ui.py check` | 18 Nov: current |
| Embedded pages current | `luajit tools/embed-pages.lua --check` | 18 Nov: current |
| Generated samples and schema current | `luajit tools/venueflow-samples.lua --check` | 19 Nov: current (`schema/protocol.json` was stale on 18 Nov, without the optional `baseRevision` on `PUBLISH` and `DRAFT_DISCARD`, and was regenerated on 19 Nov). No suite checks this file |
| Secrets | `gitleaks dir` over every VenueFlow file (2.93 MB) | no leaks found |

## Package

```bash
make venueflow
```

| | |
| --- | --- |
| File | `dist/oss/smartbuildos-venueflow.c4z` |
| Size | 622,303 bytes |
| Version | `20261114.233926` |
| SHA-256 | `4406b77d9fbc218060cc3445adb0c786609a101a5934f4378986449651a8c446` |
| Contents | `driver.xml`, `driver.lua` (squished, 42 modules), `www/app/index.html`, `www/studio/index.html`, `www/documentation/index.html` and `index.md`, seven icons |
| Integrity | `unzip -t` passes; no absolute or parent path; the squished driver loads under the shim and defines its handlers |

**This build has not been imported on the bench controller.** The bench runs
build `20261114.191046`, which was imported as an update of build
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

**Page follow-ups, 19 November 2026** (desktop Chromium against the
simulator; touch emulation where named; the page workers' checks, recorded
in `ui/venueflow/README.md` and the commit messages):

- Every interactive control of the operator page reachable and not covered,
  with touch emulation, at 1024x600, 1280x800, 1920x1200, 390x844, 844x390,
  820x1180 and 1180x820, both samples; the client's Venue Studio at 390x844,
  820x1180, 1024x600, 1280x800; the Installer Studio at 1024x600, 1024x768,
  1280x800, 1920x1200.
- Floor plan: a touch tap at the centre of every display selects exactly
  that display at 1024x600, 390x844, 844x390 and 1280x800 in both samples;
  smallest effective target 28 px (sports bar, 1024x600; 33 px at 390x844)
  and 46 px or more (conference centre). A tap in the gap opens "Which
  display?".
- Publish and Discard with two tabs (save in one, act in the other),
  installer and client: nothing done, the draft reloaded.
- The client's reason on the header, Home and Publish and Rollback; the
  dealer wording only with the page's state set by hand.
- The default profile read-only for a client (no station in the samples).
- The venue status toast on a simulator started restricted.
- The manual's ten screenshots taken on 19 November 2026 from the
  simulator, and checked to render and enlarge in the built manual.

Not covered by any browser test: Gecko 96 (the touch screens' engine; only
the static scan above), WebKit, a real touch screen, the Control4 apps, the Navigator bridge transport, a real
pointer drag on a slider, the native file chooser, a backup file landing on
disk, and pinch gestures (synthetic events only).

## Exclusions

1. **No controller.** The WebView in a Navigator, real room commands, real
   feedback, real persistence limits, a controller restart, a real network
   drop, a real daylight-saving change, Composer programming of the events
   and conditionals, and Remote Management with a real Agent are all in
   HARDWARE_VALIDATION.md and all untested. Driver installation, the pages
   in a desktop browser and publishing were seen on the bench controller in
   Simulation, on build `20261114.191046` (HARDWARE_VALIDATION.md, Results).
2. **The daylight-saving tests** use a scripted clock: they prove the
   arithmetic.
3. **The shim's HMAC** is a deterministic stand-in, not SHA-256.
4. **The driver suite's Director** is scripted: it shows which commands the
   driver sends (`SELECT_VIDEO_DEVICE` to room 1101 with `deviceid = 3001`),
   not what a controller does with them.
