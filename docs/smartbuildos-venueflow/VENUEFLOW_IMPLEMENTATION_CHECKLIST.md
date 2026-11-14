# VenueFlow implementation checklist

Statuses: **Not Started**, **In Progress**, **Completed**, **Blocked**,
**Requires Hardware Verification** (RHV).

Rules for this file:

- A task is **Completed** only when its acceptance criterion was observed
  (a named test passing, or a named check in the browser against the
  simulator). "The code exists" is not evidence.
- **RHV** means: implemented and exercised against the simulator or the test
  shim, and the remaining proof needs a real Control4 controller. Nothing
  marked RHV is claimed to work on hardware.
- The "Evidence" column names the test file or the check.

**State, 14 November 2026 (after the first bench session): 130 tasks. 120
Completed, 9 Require Hardware Verification, 1 Blocked (needs other
repositories), 0 Not Started. Two tasks (4.6 and 20.4) are verified on the
bench controller, in Simulation; every other
Completed task is verified on the simulator, the test shim or in a desktop
browser. Nothing has controlled real equipment.**

Worktree: `control4-smartbuildos-venueflow`, branch `feat/venueflow` (cut from
`feat/dealer-tools`). Driver: `drivers/smartbuildos-venueflow`. Code:
`src/venueflow`. Pages: `ui/venueflow` (assembled into the driver's `www`).

## Phase 1. Repository discovery and requirements

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 1.1 | Find an existing VenueFlow project or assets | Search of the Codex folder and the driver monorepo reported | Completed | None found; only the seven mock-up images supplied with the brief |
| 1.2 | Identify the driver monorepo conventions | Layout, build, test and worktree rules written down | Completed | ARCHITECTURE.md "House conventions reused" |
| 1.3 | Locate Agent licensing | `src/sbos/license.lua` API read; SKU pattern known | Completed | ARCHITECTURE.md "Licensing" |
| 1.4 | Locate reusable WebView pattern | UI Button + LAN relay + embedded page (Daypart, PIN Lock, Commissioning) read | Completed | ARCHITECTURE.md "Transport" |
| 1.5 | Decide repository ownership | New worktree and branch, nothing existing overwritten | Completed | `git worktree list` |
| 1.6 | Record cross-repo boundaries | What belongs to the driver repo, the Agent and the web repo listed | Completed | SMARTBUILDOS_INTEGRATION.md "Not built" |

## Phase 2. Control4 SDK research

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 2.1 | UI Button WebView capabilities | `web_view_url`, `mobile_web_view_enabled` documented with source URLs | Completed | SDK_RESEARCH.md section 1 |
| 2.2 | WebView JavaScript API | `C4.sendCommand`, `subscribeToDataToUi`, `subscribeToVariable` signatures with source URLs | Completed | SDK_RESEARCH.md section 2 |
| 2.3 | Lua UI data path | `C4:SendDataToUI` signature with source URL | Completed | SDK_RESEARCH.md section 2 |
| 2.4 | Room commands and variables | Select video/audio, room off, volume, mute and the room variables, with source URLs | Completed | SDK_RESEARCH.md section 4 (room commands are not in the official docs; standing recorded) |
| 2.5 | Device enumeration | `C4:GetDevices`, `GetProjectItems`, variable listener APIs | Completed | SDK_RESEARCH.md section 3 |
| 2.6 | Driver-hosted server, persistence, timers | `CreateServer`, `PersistSetValue`, `SetTimer` | Completed | SDK_RESEARCH.md sections 5 to 7 |
| 2.7 | Minimum OS and Navigator requirements | Stated with the evidence behind each | Completed | SDK_RESEARCH.md section 1: OS 3.3.2, Gecko 96 |
| 2.8 | List what the docs do not confirm | Every unconfirmed point named, none used as a design dependency | Completed | SDK_RESEARCH.md "Not confirmed: the complete list" (11 items) |

## Phase 3. System architecture

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 3.1 | Component map | One control engine and registry behind every interface | Completed | ARCHITECTURE.md; test_venueflow_core |
| 3.2 | Hosting decision for Installer Studio | Options compared, smallest supported one chosen and justified | Completed | ARCHITECTURE.md "Installer Studio hosting" |
| 3.3 | Trust boundaries | Which layer authenticates, which authorises, what a page may never decide | Completed | ARCHITECTURE.md "Trust"; test_venueflow_permissions |
| 3.4 | Control4 adapter seam | All Control4 calls behind one interface, replaceable by the simulator | Completed | test_venueflow_security "only adapter_c4.lua talks to Control4 devices" |

## Phase 4. Driver framework

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 4.1 | `driver.xml` | Parses; passes the repository XML guard | Completed | test_driver_xml_guard (in make test) |
| 4.2 | UI Button proxy, binding, connection | Declared as in the bench-proven drivers | Completed | driver.xml; identical to Daypart |
| 4.3 | Properties, actions, commands, events, variables | Each declared item has a handler | Completed | test_venueflow_driver [7], [10] |
| 4.4 | Lifecycle | Init, late init, destroy; restart restores state | Completed | test_venueflow_driver [1], [11] |
| 4.5 | Every `require` at module scope | Build finds every module | Completed | test_driver_require_guard; 38 modules squished |
| 4.6 | Loads on a controller | Driver added in Composer, no Lua error | Completed | Bench, 14 Nov 2026: HARDWARE_VALIDATION.md Results, H1 passed (Driver Status "Online - Simulation", Last Error "none"; the Lua tab was not open at the moment of start) |

## Phase 5. WebView communication

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 5.1 | Command envelope | requestId, command, payload, ts in; ack, status, errorCode, results, state out | Completed | test_venueflow_relay "invalid payloads", "state delivery" |
| 5.2 | Schema for every command | Unknown command and invalid payload refused with a code | Completed | test_venueflow_relay: every command validated, every command has a handler |
| 5.3 | LAN relay transport | HTTP router parses, routes, renders; oversize and malformed refused | Completed | test_venueflow_relay (253 checks); browser tests |
| 5.4 | Navigator bridge transport | `C4.sendCommand` to `ExecuteCommand`, reply by `C4:SendDataToUI` | Completed | test_venueflow_driver [5] (shim). Delivery on a Navigator: 5.7 |
| 5.5 | State delivery to pages | Version counter; unchanged state costs one small reply | Completed | test_venueflow_relay "state delivery" |
| 5.6 | Page loads on Navigators | T3/T4, iOS, Android | Requires Hardware Verification | HARDWARE_VALIDATION.md H2. On the bench both pages load whole from the controller in a desktop browser; no Navigator has opened the tile |
| 5.7 | Bridge reply reaches the page on a Navigator | Reply seen in the page | Requires Hardware Verification | HARDWARE_VALIDATION.md H8 |

## Phase 6. Installer Studio

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 6.1 | Shell and navigation | All sections reachable on desktop and tablet widths | Completed | Browser check: 18 sections at 1280x800 and 1024x768 |
| 6.2 | Sign-in | Passcode required; wrong passcodes lock; no passcode means Studio is off | Completed | test_venueflow_permissions "Installer Studio sign-in"; test_venueflow_driver [3], [9] |
| 6.3 | Overview | Counts, publish state, validation summary | Completed | Browser check |
| 6.4 | Setup wizard, six steps | Each step saves to the draft; nothing overwritten without confirmation | Completed | Browser check; test_venueflow_store "templates" |
| 6.5 | Sources, audio zones, display groups editors | Create, edit, delete with confirmation | Completed | Browser check |
| 6.6 | Scenes and scheduling editors | Create, edit, schedule | Completed | Browser check |
| 6.7 | Staff profiles editor | Roles, interfaces, permissions, PIN set server-side | Completed | Browser check; test_venueflow_permissions (PIN hashes never leave the driver) |
| 6.8 | Diagnostics, licensing | Read from the driver | Completed | Browser check |
| 6.9 | Backup, publish, rollback | Round trip proven | Completed | test_venueflow_store; browser check |

## Phase 7. Device discovery and mapping

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 7.1 | Enumerate project devices | Documented APIs only; categories and capabilities recorded | Completed | test_venueflow_core "device discovery" (simulated project) |
| 7.2 | Manual mapping | Any device can be mapped by hand when discovery is incomplete | Completed | Browser check: room id typed by hand |
| 7.3 | Display mapping fields | All fields of brief 6.3 stored and validated | Completed | test_venueflow_schema |
| 7.4 | Test Power, Test Source, Test Route, Query Status | Confirmation required; results per device | Completed | test_venueflow_core "installer test actions"; browser check |
| 7.5 | Discovery against a real project | Categories match Composer | Requires Hardware Verification | HARDWARE_VALIDATION.md H4 |

## Phase 8. Spatial Layout Designer

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 8.1 | Canvas: blank or uploaded floor plan, floors | Image stored through the driver, not in the browser | Completed | Browser check; test_venueflow_store "floor plan images"; test_venueflow_relay "picture upload" |
| 8.2 | Place, move, rotate, resize, lock | Persisted in the draft | Completed | Browser check |
| 8.3 | Rooms/areas, audio zones, labels, scene buttons, groups | Created and persisted | Completed | Browser check |
| 8.4 | Grid, snap, zoom, pan, layers | Work with mouse (touch: built on pointer events, not tried on a touch screen) | Completed | Browser check with mouse. Touch gestures: synthetic events only |
| 8.5 | Undo and redo | Reverts and reapplies the last changes | Completed | Browser check |
| 8.6 | Operator preview | Shows what an operator sees | Completed | Browser check |
| 8.7 | Mapping integrity | Moving or deleting an icon never changes a device mapping | Completed | test_venueflow_schema "layout never touches a mapping"; browser check |

## Phase 9. Visual Programming Engine

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 9.1 | Declarative program format | No user Lua or JavaScript is ever evaluated | Completed | test_venueflow_rules "validation", "runner bounds"; test_venueflow_security |
| 9.2 | Triggers | Button/scene, schedule, Control4 event, device state, variable, manual | Completed | test_venueflow_rules "triggers" (every kind) |
| 9.3 | Conditions and logic | AND, OR, NOT, IF/ELSE, all condition kinds | Completed | test_venueflow_rules "conditions and logic" |
| 9.4 | Actions | Every action kind of the brief | Completed | test_venueflow_rules "Game Day"; test_venueflow_audio; test_venueflow_core |
| 9.5 | Validation | Unknown references, unsupported operations, cycles refused | Completed | test_venueflow_rules "validation" |
| 9.6 | Dry run sends nothing | Adapter call count unchanged | Completed | test_venueflow_rules "dry run" |
| 9.7 | Execution log, failure detail, last success | Recorded per run | Completed | test_venueflow_rules "execution log", "regressions" |
| 9.8 | Editor | Add, reorder, edit, duplicate, remove blocks | Completed | Browser check |

## Phase 10. Operator interfaces

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 10.1 | A: Visual Floor Plan | Select, route, power, audio, scenes, floors, status | Completed | Browser check |
| 10.2 | B: Command Center | Display-first and source-first routing, filters, mixer, feedback | Completed | Browser check |
| 10.3 | C: Simplified Room Control | Installer-defined buttons and optional controls | Completed | Browser check (conference centre) |
| 10.4 | D: Manager Overview | Counts, states, alerts, scenes, opening/closing, confirmations | Completed | Browser check |
| 10.5 | One engine behind all four | Same commands, same state document | Completed | One protocol, one state document: test_venueflow_core, test_venueflow_relay |
| 10.6 | Touch screen rendering | T3/T4 WebView | Requires Hardware Verification | HARDWARE_VALIDATION.md H2. Pages tested in Chromium only |

## Phase 11. Source routing engine

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 11.1 | Eight-step route pipeline | Permission, source, destinations, path, conflicts, execute, feedback, results | Completed | test_venueflow_routing |
| 11.2 | Partial success | Six displays: four routed, one unavailable, one unsupported, reported individually | Completed | test_venueflow_routing "partial success, reported per display" |
| 11.3 | State classes | confirmed, pending, commanded, unknown, failed | Completed | test_venueflow_routing "state classes" |
| 11.4 | Serialisation | One command in flight per Control4 room; a newer request supersedes a waiting one | Completed | test_venueflow_routing "conflicting commands" |
| 11.5 | No matrix assumptions | Route strategy is per display | Completed | test_venueflow_routing (room and custom-command strategies) |
| 11.6 | Real matrix, AV-over-IP, video wall | Routes follow on screen | Requires Hardware Verification | HARDWARE_VALIDATION.md H6 |

## Phase 12. Audio-zone management

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 12.1 | Zone source, volume, mute, power, presets | Each with feedback class | Completed | test_venueflow_audio |
| 12.2 | Volume limits | A level outside the zone range is clamped and reported | Completed | test_venueflow_audio "volume limits" |
| 12.3 | Independence | A video route changes no audio zone unless asked | Completed | test_venueflow_audio "audio is independent of video" |
| 12.4 | Coupling detection | A display and zone sharing a Control4 room is flagged | Completed | test_venueflow_audio "validation of shared Control4 rooms" |
| 12.5 | Real amplifier or matrix | Heard in the room | Requires Hardware Verification | HARDWARE_VALIDATION.md H7 (room mute is the least certain command) |

## Phase 13. Scenes and scheduling

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 13.1 | Eight editable scene templates | Present per venue type | Completed | test_venueflow_store "templates" |
| 13.2 | Scene execution with per-step results | Recorded | Completed | test_venueflow_rules |
| 13.3 | Schedules | Fire once per day and time in controller local time | Completed | test_venueflow_scheduler |
| 13.4 | Daylight-saving changes | Skipped hour caught up once; repeated hour not fired twice | Completed | test_venueflow_scheduler "daylight saving" (scripted clock) |
| 13.5 | Overlap protection | A newer run touching the same devices stops the older one and says so | Completed | test_venueflow_rules "overlapping runs", "regressions" |
| 13.6 | Disruptive scene safeguard | Confirmation required | Completed | test_venueflow_core "disruptive actions need confirmation" |
| 13.7 | Schedule on a controller across a real clock change | Observed | Requires Hardware Verification | HARDWARE_VALIDATION.md H9 |

## Phase 14. Staff profiles and security

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 14.1 | Seven profile templates | Present | Completed | test_venueflow_store "templates" |
| 14.2 | Permissions enforced in the driver | A hidden control cannot be driven by a hand-made request | Completed | test_venueflow_permissions "refusals", "forged identity" |
| 14.3 | Profile identity | PIN to session; the page never asserts its own profile | Completed | test_venueflow_permissions "PIN sign-in", "stations" |
| 14.4 | Installer authentication | Passcode, lockout, session expiry | Completed | test_venueflow_permissions "sessions", "Installer Studio sign-in" |
| 14.5 | No unauthenticated configuration or control endpoint | Every route checked | Completed | test_venueflow_relay "identity"; test_venueflow_permissions "unauthenticated" |
| 14.6 | Secrets | No PIN, passcode or token in logs, pages or backups in clear | Completed | test_venueflow_core "diagnostic log"; test_venueflow_security; test_venueflow_store "backup and restore" |

## Phase 15. SmartBuildOS licensing

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 15.1 | License through the Agent | `sbos.license`, SKU `SBOS_VENUEFLOW`, standard properties | Completed | test_driver_license_guard; test_venueflow_driver [1] |
| 15.2 | Fail open on uncertainty | No Agent, cloud outage, grace: full operation | Completed | test_venueflow_license "cloud outage" |
| 15.3 | Definitive denial | Manual control and All Off keep working; automation and publishing stop; nothing is switched off | Completed | test_venueflow_license "restricted"; test_venueflow_driver [8] |
| 15.4 | Entitlement issued by the platform | SKU row and Agent filename registered | Blocked | Needs the web repository (SKU row) and the Agent (DRIVER_FILENAMES): SMARTBUILDOS_INTEGRATION.md |

## Phase 16. Local configuration and persistence

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 16.1 | Schemas for every entity of brief 16 | Documented and validated | Completed | DATA_MODEL.md; test_venueflow_schema |
| 16.2 | Stable identifiers | Renaming never changes an id | Completed | test_venueflow_schema "identifiers" |
| 16.3 | Draft, published, previous versions | Kept through the controller persistence API | Completed | test_venueflow_store |
| 16.4 | Schema version and migration | Older document migrated on load | Completed | test_venueflow_store "schema migration" (mechanism; version 1 is the first schema) |
| 16.5 | Backup and restore | Exported document restores to an equal draft | Completed | test_venueflow_store "backup and restore" |
| 16.6 | Browser storage is never the authority | Pages hold only a session token | Completed | test_venueflow_security (no localStorage); pages hold a session token only |
| 16.7 | Large documents on a controller | Floor plan image and 24-display venue survive a restart | Requires Hardware Verification | HARDWARE_VALIDATION.md H3, H5. On the bench a 478 kB picture and the 24-display sample survived a driver restart (an update of the driver). A restart of the controller itself and H5 at real size are not done |

## Phase 17. Error handling and diagnostics

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 17.1 | Structured error codes | One catalogue; every refusal carries a code | Completed | test_venueflow_relay (every code has a sentence and a status) |
| 17.2 | Bounded log | Fixed size ring, oldest dropped | Completed | test_venueflow_core "diagnostic log" |
| 17.3 | Redaction | Secret-named fields hidden | Completed | test_venueflow_core "diagnostic log" |
| 17.4 | Operator message and installer detail | Both present on a failure | Completed | test_venueflow_routing; test_venueflow_permissions (detail only for installers) |
| 17.5 | A failure never reads as success | Dispatch without confirmation is never "confirmed" | Completed | test_venueflow_routing "state classes"; test_venueflow_core (tests, Live mode) |

## Phase 18. Simulation and automated tests

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 18.1 | Sports-bar reference venue | 24 displays, 8 sources, 4 zones, groups, scenes, 3 profiles | Completed | test_venueflow_core "reference sports bar" |
| 18.2 | Conference-centre venue | Present and valid | Completed | test_venueflow_core "reference conference centre" |
| 18.3 | Simulator with fault injection | Offline device, unsupported route, silent device | Completed | src/venueflow/sim.lua: offline, silent, wrong, slow; used throughout |
| 18.4 | Unit and integration suites | All 17 cases of brief 18 covered | Completed | TEST_RESULTS.md: 12 suites, 1812 checks, 0 failed |
| 18.5 | Browser tests | Pages driven against the real Lua core and simulator | Completed | TEST_RESULTS.md "Browser tests" (Chromium) |
| 18.6 | Whole repository suite still passes | `make test` | Completed | TEST_RESULTS.md: make test exit 0, 126 files |

## Phase 19. Hardware integration tests

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 19.1 | Written procedure | Every item of brief 19 has steps and a pass criterion | Completed | HARDWARE_VALIDATION.md H1 to H10 |
| 19.2 | Run on the bench controller | Results recorded | Requires Hardware Verification | Started 14 Nov 2026: H1, the laptop part of H2 and H3 with a driver restart passed and are recorded. H2 on Navigators, a controller restart, the network drop and H4 to H10 not run |

## Phase 20. Driver packaging

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 20.1 | Reproducible build | One command builds the `.c4z` without touching Composer's folder | Completed | make venueflow |
| 20.2 | Archive contents | driver.xml, squished Lua with every module, www pages, icons, documentation | Completed | test_venueflow_security "package" |
| 20.3 | Archive integrity | Zip test passes, paths relative, no stray files | Completed | test_venueflow_security "package"; the squished driver loads under the shim |
| 20.4 | Import in Composer | Driver appears and loads | Completed | Bench, 14 Nov 2026: build `20261114.061304` imported from `dist/oss` with no error dialog and added to the project (HARDWARE_VALIDATION.md Results, H1). Build `20261114.191046` was imported the same day as an update (Composer says "Versions are equal" for a second build of one day; Yes overwrites) |

## Phase 21. Documentation

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 21.1 | Installer guide | Written | Completed | INSTALLER_GUIDE.md |
| 21.2 | Programmer guide | Written | Completed | PROGRAMMER_GUIDE.md |
| 21.3 | Operator guide | Written | Completed | OPERATOR_GUIDE.md |
| 21.4 | SmartBuildOS integration | Written | Completed | SMARTBUILDOS_INTEGRATION.md |
| 21.5 | Troubleshooting | Written | Completed | TROUBLESHOOTING.md |
| 21.6 | Release notes | Written | Completed | RELEASE_NOTES.md |
| 21.7 | Driver manual in Composer | `www/documentation/index.md` builds | Completed | Built into the .c4z (www/documentation/index.html). No bench screenshots yet |
| 21.8 | Schemas and sample venues | Published as files | Completed | DATA_MODEL.md, schema/*.json, samples/*.json |

## Phase 22. Release verification

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 22.1 | Security review of the brief's 11 points | Each answered with evidence | Completed | SECURITY_REVIEW.md |
| 22.2 | Secret scan | No credential in the tree | Completed | gitleaks: no leaks found |
| 22.3 | Static checks | stylua, driver guards | Completed | TEST_RESULTS.md "Static checks" |
| 22.4 | Readiness statement | One of: development only, simulation verified, hardware validated, production ready | Completed | RELEASE_NOTES.md: simulation verified |
