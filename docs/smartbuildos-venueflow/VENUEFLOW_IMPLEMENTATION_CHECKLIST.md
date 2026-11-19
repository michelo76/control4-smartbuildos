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

**State, 18 November 2026: 156 tasks. 133 Completed, 19 Require Hardware
Verification, 2 Blocked (the `SBOS_VENUEFLOW` catalogue row not applied; an
owner decision on remote drafts), 1 In Progress, 1 Not Started. Two tasks
(4.6 and 20.4) are verified on the bench controller, in Simulation, on builds
of 14 November 2026; every other Completed task is verified on the simulator,
the test shim or in a desktop browser. Nothing has controlled real
equipment. Phases 23 and 24 (the second round and the fixes of 18 November
2026) have not run on a controller at all.**

The driver is on `main` (the branches it was built on, `feat/venueflow` and
`feat/dealer-tools`, were merged and removed from the remote). Driver:
`drivers/smartbuildos-venueflow`. Code: `src/venueflow`. Pages:
`ui/venueflow` (assembled into the driver's `www`).

## Phase 1. Repository discovery and requirements

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 1.1 | Find an existing VenueFlow project or assets | Search of the Codex folder and the driver monorepo reported | Completed | None found; only the seven mock-up images supplied with the brief |
| 1.2 | Identify the driver monorepo conventions | Layout, build, test and worktree rules written down | Completed | ARCHITECTURE.md "House conventions reused" |
| 1.3 | Locate Agent licensing | `src/sbos/license.lua` API read; SKU pattern known | Completed | ARCHITECTURE.md "Licensing" |
| 1.4 | Locate reusable WebView pattern | UI Button + LAN relay + embedded page (Daypart, PIN Lock, Commissioning) read | Completed | ARCHITECTURE.md "House conventions reused"; SDK_RESEARCH.md section 5 |
| 1.5 | Decide repository ownership | New worktree and branch, nothing existing overwritten | Completed | `git worktree list` |
| 1.6 | Record cross-repo boundaries | What belongs to the driver repo, the Agent and the web repo listed | Completed | SMARTBUILDOS_INTEGRATION.md "Not finished" |

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
| 4.5 | Every `require` at module scope | Build finds every module | Completed | test_driver_require_guard; 43 modules squished (counted in a package built on 18 November 2026; no module added since) |
| 4.6 | Loads on a controller | Driver added in Composer, no Lua error | Completed | Bench, 14 Nov 2026: HARDWARE_VALIDATION.md Results, H1 passed (Driver Status "Online - Simulation", Last Error "none"; the Lua tab was not open at the moment of start) |

## Phase 5. WebView communication

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 5.1 | Command envelope | requestId, command, payload, ts in; ack, status, errorCode, results, state out | Completed | test_venueflow_relay "invalid payloads", "state delivery" |
| 5.2 | Schema for every command | Unknown command and invalid payload refused with a code | Completed | test_venueflow_relay: every command validated, every command has a handler |
| 5.3 | LAN relay transport | HTTP router parses, routes, renders; oversize and malformed refused | Completed | test_venueflow_relay; browser tests |
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
| 15.4 | Entitlement issued by the platform | SKU row applied and Agent filename registered | Blocked | Agent side done on 18 Nov 2026: `DRIVER_FILENAMES` and `SKU_FILENAMES` name the driver (test_sbos_updater [10], [11]). The catalogue-row migration for `SBOS_VENUEFLOW` is merged in the web repository and **not applied by the owner**; the store's publish workflow does not name VenueFlow. SMARTBUILDOS_INTEGRATION.md |

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
| 18.4 | Unit and integration suites | All 17 cases of brief 18 covered | Completed | TEST_RESULTS.md: 16 suites, 2524 checks, 0 failed (18 Nov 2026) |
| 18.5 | Browser tests | Pages driven against the real Lua core and simulator | Completed | TEST_RESULTS.md "Browser tests" (Chromium) |
| 18.6 | Whole repository suite still passes | `make test` | Completed | TEST_RESULTS.md: make test exit 0, 133 files (18 Nov 2026) |

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

## Phase 23. Second round: Venue Studio for the client, source controls, Remote Management

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 23.1 | Venue Studio for the client | A profile with the permission opens the Studio on its PIN and changes only client-owned parts | Requires Hardware Verification | test_venueflow_clientstudio; browser check in desktop Chromium. Not tried on a touch screen or in the Control4 app (HARDWARE_VALIDATION.md, "Not yet run") |
| 23.2 | Client limits enforced by the driver | A hand-made request changing an installer-owned part is refused | Completed | test_venueflow_clientstudio "every installer-owned part refused" |
| 23.3 | Basic source controls | Closed key list, groups per source, permission, keys sent to the source's device | Requires Hardware Verification | test_venueflow_sourcecontrol. That a key reaches a real box is not documented and not seen |
| 23.4 | Favourite channels | Up to 24 per source, dialled digit by digit, edited by the client | Requires Hardware Verification | test_venueflow_sourcecontrol, test_venueflow_clientstudio. Digit spacing on a real box not seen |
| 23.5 | Remote Management, driver side | Property, registration only while on, five commands, snapshot without PIN material, published event | Requires Hardware Verification | test_venueflow_remote, test_venueflow_driver. Never registered with a real Agent |
| 23.6 | Remote Management, platform side | System Studio section, status route, module contract, catalogue-row migration | Completed | In the web repository: merged and deployed 15 Nov 2026 with its unit tests (not checked from this repository). The migration is not applied (15.4) |
| 23.7 | Remote Management end to end | A draft, publish and rollback from System Studio reach the bench controller | Requires Hardware Verification | HARDWARE_VALIDATION.md, "Not yet run". Never run |
| 23.8 | Owner decision: may a remote draft replace device mapping and device commands | Decided and enforced | Blocked | Needs the owner. Today a remote draft can replace the whole configuration (SECURITY_REVIEW.md) |

## Phase 24. Review and audit fixes, 18 November 2026

Simulator and test shim only; nothing here has run on a controller.

| ID | Task | Acceptance criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| 24.1 | Profiles screens and stations open with are the installer's | A client's change, rename, removal or PIN on them is refused | Completed | test_venueflow_clientstudio "the profiles a screen or station opens with", "PINs and templates: refused or attributed" |
| 24.2 | Whose draft it is | Saves record who saved; a client cannot publish or discard installer or remote work; a restored backup counts as the installer's | Completed | test_venueflow_clientstudio "whose work is in the draft" |
| 24.3 | Revisions never repeat | Across discard, publish, restore; `baseRevision` on `PUBLISH` and `DRAFT_DISCARD` | Completed | test_venueflow_store "revisions never repeat" |
| 24.4 | PINs kept when there is no draft | An installer or remote save with no draft keeps every PIN | Completed | test_venueflow_store "PINs when there is no draft" |
| 24.5 | Partly visible operations | Label counted over what the profile sees; no `origin` for a profile | Completed | test_venueflow_permissions "operations, partly visible" |
| 24.6 | A channel being dialled across a publish | Finishes unless the source's device or the control mode changed; a stop is logged | Completed | test_venueflow_sourcecontrol "a publish while a channel is being dialled", "the control mode changes ...". On a real box: 23.3 |
| 24.7 | Stopping a run | A command already sent is not reported as stopped | Completed | test_venueflow_routing "stopping a run: a command already sent is not 'stopped'" |
| 24.8 | A scene's area | `SCENE_ACTIVATE` refuses an area outside the profile's access | Completed | test_venueflow_permissions "a scene's area" |
| 24.9 | Alerts a profile is shown | Stored alerts filtered by what they concern; `ALERT_DISMISS` only for an alert shown; the count updated at once | Completed | test_venueflow_permissions "dismissing alerts"; test_venueflow_core "a stored alert about displays a profile cannot see is not shown to it", "ALERT_DISMISS writes the venue's count" |
| 24.10 | One count of alerts; *Alert Raised* for detected alerts | Property, `ALERT_COUNT` and *VenueFlow has alerts* agree; the event fires when a detected alert appears | Requires Hardware Verification | test_venueflow_driver; test_venueflow_core (the alert timer). In Composer programming: not seen |
| 24.11 | *Configuration Published* on a rollback; the event names the new version | Fires; `versionId` new, `restoredFrom` the old | Requires Hardware Verification | test_venueflow_driver |
| 24.12 | True-or-false conditionals honour the false choice | "Venue is closed", "has alerts: clear" | Requires Hardware Verification | test_venueflow_driver. The shim cannot tell how Composer passes the choice |
| 24.13 | Composer commands under a restricted licence | *Trigger the VenueFlow event* refused or flagged; *Mark the venue* sets the status and reports rules not run; Last Error says so | Requires Hardware Verification | test_venueflow_driver, test_venueflow_license. Needs H10 (15.4) |
| 24.14 | `refresh_status` summary and `config_version` | One line of at most 200 characters, a status frame at once, the live version | Requires Hardware Verification | test_venueflow_driver. Needs 23.7 |
| 24.15 | The Agent's updater and SKU lists name VenueFlow | `DRIVER_FILENAMES` and `SKU_FILENAMES` | Completed | test_sbos_updater [10], [11]. The store's publish workflow does not name VenueFlow yet |
| 24.16 | Package staleness check | The package check fails when a built package is older than its sources | Completed | test_venueflow_security; seen failing on 18 Nov 2026 against a package built before the last commits of the round |
| 24.17 | Touch-screen engine floor (Gecko 96) checked statically | The page sources and built pages scanned for features Gecko 96 lacks | In Progress | Written on a separate branch, not merged into this source; Gecko 96 itself remains untested (10.6) |
| 24.18 | Shared module client: authenticate the registration reply; leave the Agent when switched Off mid-registration | Fixed for every module driver | Not Started | SECURITY_REVIEW.md, residual risks 8 and 9. Changes the module contract for every module driver |
