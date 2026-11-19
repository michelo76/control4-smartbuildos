# VenueFlow security and release-quality review

Reviewed 14 November 2026 against the eleven points of the brief (section
22); updated 18 November 2026 for the adversarial review and gap audit of
that round (RELEASE_NOTES.md, top). "Evidence" names the automated check;
every check runs on the simulator or the test shim, not on a controller.
Check counts per suite are in TEST_RESULTS.md.

## The eleven points

| # | Point | Finding | Evidence |
| --- | --- | --- | --- |
| 1 | Review all command inputs | Every request passes `protocol.lua`: a known command, a bounded request id, a typed payload with no unknown field, bounded strings (4 kB; 2 MB only for the two upload commands), lists of at most 256 ids (4000 for publish acknowledgements), finite numbers, enumerated values. HTTP bodies over 4 MB are refused at the header, before the body arrives; a header block over 16 kB is refused; a large upload is buffered in chunks and joined once | `test_venueflow_relay.lua` "invalid payloads", "request parsing" |
| 2 | Enforce command authorization | Scope per command (public, operator, studio, installer) is checked in `core:handle` before any handler runs; inside, each engine asks the session's Access object per request and per device, and a client session's configuration changes are compared with the installer-owned part (`clientscope.lua`) | `test_venueflow_permissions.lua`, `test_venueflow_clientstudio.lua`, `test_venueflow_relay.lua` "identity" |
| 3 | Review exposed endpoints | Six routes: `GET /ping`, `GET /app`, `GET /studio`, `POST /api`, `POST /image` (a floor-plan picture; needs an installer session in the `X-VF-Session` header) and `OPTIONS`. The first three carry no secret and change nothing. Anything else is 404 | `test_venueflow_relay.lua` "routes", "picture upload" |
| 4 | Validate all configuration schemas | A draft is migrated, normalised and validated on every save; publishing needs zero errors and every warning acknowledged; a document from a newer schema is refused | `test_venueflow_schema.lua`, `test_venueflow_store.lua` |
| 5 | Prevent arbitrary code execution | Programs are data from a fixed vocabulary; an unknown step, condition or trigger is refused at validation and never executed by the runner. No `loadstring`, `load`, `dofile`, `os.execute`, `io.popen`, `setfenv` or `debug.` in any engine; no `eval`, `new Function`, `document.write` or HTML built from strings in either page. Floor plans are PNG, JPEG or WebP only (SVG is refused) | `test_venueflow_security.lua`, `test_venueflow_rules.lua` "validation", "runner bounds", `test_venueflow_store.lua` "floor plan images" |
| 6 | Check for embedded credentials | None. The Installer Passcode is a hidden property with an empty default. The development passcode and tile token exist only in the development host and the test harness, and are checked absent from the driver, the engines and both pages. The one PIN in the tree is the documented sample venues' manager PIN, usable only in Simulation | `test_venueflow_security.lua` "no credential in what ships"; gitleaks (below) |
| 7 | Review dependency security | The driver adds no dependency: it uses the repository's vendored `JSON.lua` and `drivers-common-public`, already shipped by every driver here. The pages load nothing external (checked). Build tools are unchanged | `test_venueflow_security.lua` "pages" |
| 8 | Remote administration requires authentication | Installer Studio needs the Installer Passcode (6+ characters; no passcode means the Studio is off). Wrong attempts lock per client address and overall. Sessions expire, idle out, and end when the passcode changes. The one remote (cloud) administration path is Remote Management, Off by default and authenticated by the Agent's module token (below) | `test_venueflow_permissions.lua` "Installer Studio sign-in", `test_venueflow_driver.lua` [3], [9] |
| 9 | No control through an unauthenticated configuration endpoint | There is no configuration endpoint outside the protocol, and every operator and installer command is refused without an identity. Looped over the whole protocol | `test_venueflow_relay.lua` "identity" (every command), `test_venueflow_permissions.lua` "unauthenticated" |
| 10 | Local operation survives network disruption | Nothing in the core makes a network call. With no Agent, an unreachable cloud or the grace period, everything works. A page that cannot reach the controller says so and recovers | `test_venueflow_license.lua` "cloud outage"; page behaviour: browser check; a real LAN drop: hardware H3 |
| 11 | Configuration backups can be restored | Export, restore on a second driver, publish, and the venues are equal, pictures and staff PINs included | `test_venueflow_store.lua` "backup and restore" |

## The client session and Remote Management

First built as `20261114.233926`; the rules added on 18 November 2026 are
source only and simulator verified.

**Client session.** The Studio now also opens for a staff profile whose
`permissions.studio` is true, on a PIN session. What protects the
installation:

- The driver compares the installer-owned part of the configuration before
  and after every client save, publish, discard and rollback
  (`clientscope.lua`). The page's own section list is a convenience.
- A client cannot grant or remove the permission, for anyone, itself
  included. Only an installer session can.
- A tile's default profile and a station never get a client session: it
  takes a PIN sign-in.
- The profile a tile opens with and every station's profile are the
  installer's as whole records (permissions, areas, interfaces, PIN), because
  anyone on the LAN acts as them. A client's change, rename or removal of
  them, or setting or clearing their PIN, is refused (18 November 2026).
- Every draft save records who saved it. A client cannot publish or discard
  a draft that holds a save by the installer or by the dealer through Remote
  Management since the last publish or discard (18 November 2026).
- Installer-only commands (devices, discovery, tests, live program runs,
  pictures, backup, restore, diagnostics, licensing, session revocation, the
  simulator) answer `VF_FORBIDDEN`.
- Taking the permission away and publishing ends the access at once.

What it costs: day-to-day configuration is now guarded by a 4 to 8 digit
PIN, which crosses the venue network in clear like any PIN, with the same
lockout (five wrong attempts per address, forty in ten minutes overall).
Scene steps and schedules can only name the venue's own configured
equipment; there is no step that sends an arbitrary Control4 command.

**Remote Management.** Off by default. When the dealer switches it on:

- Authority is the Agent's module contract: a command is accepted only with
  the token the Agent issued at registration, and the Agent accepts only
  commands on its allowlist that this instance registered. With "Draft only"
  the driver does not register `publish` or `rollback`, so the Agent refuses
  them before they reach the driver, and the driver refuses them again.
- The commands act on the configuration only. None routes video, changes a
  volume, runs a scene, sets a PIN or touches the simulator.
- A remote draft must name the revision it was edited from; a publish must
  name the revision that was reviewed. Work done on site is never
  overwritten silently.
- A snapshot travels as base64 groups, which neither the Agent's snapshot
  redaction nor the platform's can look inside. That is deliberate (a
  redacted configuration cannot be edited and sent back; both redactors
  rewrite ordinary configuration text) and it means VenueFlow's own stripping
  is the only filter: PIN salts and hashes are removed before encoding and
  the passcode is never in the configuration (tested).
- A snapshot carries no PIN salt or hash and no passcode. It does carry the
  whole configuration (names, Control4 device and room ids, staff profile
  names): that is the data the dealer's platform account will hold.
- **A remote draft can replace the whole configuration, and "Draft and
  publish" can put it live.** A remote draft is checked against the schema
  and the revision, not against an installer-owned part: it can replace
  device mapping and device commands, including a display's custom route
  command (one command, with its device id, name and parameters, sent to a
  device on every route) and a lighting preset's command. With "Draft and
  publish" the platform can then publish it with nobody on site; with
  "Draft only" someone on site must. The commands remain bound to the
  venue's own vocabulary (a route, a preset), and Remote Management never
  runs one by itself, but what a route or a preset sends afterwards is what
  the dealer's platform account wrote. Whether a remote publish may replace
  device mapping and device commands is an open owner decision; until it is
  made, give "Draft and publish" only where the dealer's platform account is
  trusted as much as the Installer Passcode.
- The server side was merged and deployed in the web repository on 15
  November 2026 (its `docs/venueflow/README.md`): the route requires
  `monitoring:manage`, resolves the system inside the caller's company, and
  every change goes through the existing command gateway with its audit row.
  It has not been run against a controller.

**Source controls.** A page sends a key name from a closed list of 33; the
driver maps it to a Control4 command and refuses anything else, so a page
cannot make the driver send an arbitrary command. The target is always the
source's own mapped device. A channel is digits with at most one dash or
dot, eight characters at most. At most 64 keys wait at once. The permission
is separate (`sourceControl`), and a client may edit favourites but not which
controls a source has.

## Residual risks, stated plainly

These are real and are not closed by this build.

1. **Plain HTTP on the LAN.** The relay is HTTP, like the repository's other
   relays (a driver cannot hold a certificate a browser trusts). Anyone who
   can capture traffic on the venue network can read a staff PIN, the
   Installer Passcode or a session token as they are sent. Mitigation
   available today: put controllers and control screens on a network guests
   cannot join. A challenge-response sign-in would keep the PIN and passcode
   off the wire (not the session token); it is not built.
2. **The tile token is a bearer token for the default profile.** It is in the
   web view URL and in "Print Operator Page Link". Whoever has it and is on
   the LAN can act as the tile's default profile. That is why the default
   profile must be a restricted one without a PIN, and why validation warns
   when an unprotected profile can run venue-wide actions.
3. **A station is identified by its address.** An address can be imitated on
   the LAN. A station can therefore only be given a profile without a PIN.
4. **PIN hashes in backups.** A four-digit PIN's hash can be reversed by
   trying every PIN. A backup file must be kept as private as the PINs.
   Stated in the Studio and the guides.
5. **The driver's random numbers** come from an HMAC keyed by a persisted
   seed over a counter, the clocks and table addresses, plus `C4:UUID` and
   `C4:GetTime` when they exist. Adequate for LAN session tokens; not a
   certified generator.
6. **Denial of service on the LAN.** One connection is handled at a time by
   the driver's socket callbacks. A device flooding port 47861 can slow the
   pages. Control from Composer programming is unaffected.
7. **Not verified on hardware.** How the controller's socket behaves with
   large replies and many clients is unknown (HARDWARE_VALIDATION.md H2, H5).
8. **A forged registration reply is believed (shared module client).** The
   module client every SmartBuildOS module driver uses
   (`src/sbos/moduleclient.lua`) accepts an `SBOS_MODULE_REGISTERED` reply
   without knowing who sent it, and adopts the token in it. Code that can
   already send commands to drivers on the controller can therefore pose as
   the Agent and, with Remote Management at "Draft and publish", save,
   publish and roll back the configuration. A page on the LAN cannot do
   this: it reaches only the protocol. Not fixed: the fix changes the module contract for every
   module driver. Confirmed by a reviewer on 18 November 2026.
9. **Switching Remote Management Off during a registration (shared module
   client).** If the property is set to Off before the Agent has answered a
   registration, the module stays registered with the Agent and keeps
   sending status. Commands are still refused by the driver. Not fixed, for
   the same reason as item 8.

## Scans

Recorded in TEST_RESULTS.md with the commands and their output: the whole
repository's `make test`, the VenueFlow suites, `stylua --check`, `node
--check` on every page source, and `gitleaks` over the VenueFlow commits.

## Release blockers found and fixed during the build

| Defect | Found by | Fix |
| --- | --- | --- |
| A program step whose devices were already in the requested state stayed "sent" for ever (the run never finished) | `test_venueflow_rules.lua` "waits" | `routing.lua` reports a settled operation; `rules.lua` settles the step at once |
| A rule triggered by a scene's own step stopped that scene | `test_venueflow_scheduler.lua` "in the core", and the editor's browser test | the runner tracks the runs whose step is executing; a run is never a rival of its ancestor |
| State read in Simulation was shown as "confirmed" after switching to Live | `test_venueflow_core.lua` "control mode" | the state is cleared on a mode change |
| A reference venue (invented Control4 ids) could be run in Live mode | review | reference venues are marked and refused in Live |
| A sample venue left in the DRAFT could be test-driven in Live mode: the mapping tests acted on the draft without the sample check | automated review of the pull request; `test_venueflow_core.lua` "Live refuses test ... on a sample draft" | `TEST_DEVICE` refuses a sample configuration in Live before anything is read or sent |
| Any signed-in operator could read any operation by its sequential id, hidden areas included | automated review; `test_venueflow_permissions.lua` "operation detail is filtered by the profile's access" | `OPERATION_GET` filters targets and counts through the profile's access; nothing visible answers as not found |
| Stopping a run left its queued commands running; after All Off a stopped scene's routes could still arrive | automated review; `test_venueflow_rules.lua` "stopping a run stops its queued commands" | the run's unsent commands leave the queue when it is stopped |
| A second listener on a Control4 variable replaced the first (two rules; a rule and a room's feedback) | automated review; `test_venueflow_adapter.lua` | one callback per device and variable, fanned out |
| A schedule due within 20 s of a start or a publish was skipped | automated review; `test_venueflow_scheduler.lua` "baseline", `test_venueflow_rules.lua` "schedules across a start and a publish" | the baseline is set at install and carried across a publish |
| A remapped display or zone kept the old hardware's confirmed readings | automated review; `test_venueflow_core.lua` "state across a publish" | state is kept only where the mapping is unchanged |
| The Studio could not show a draft floor plan before the first publish | `test_venueflow_store.lua` "backup and restore" | `IMAGE_GET` is allowed to an installer session without a published venue |
| The same source asked for twice on one display was reported as a conflict ("superseded") | `test_venueflow_rules.lua` "regressions" | a repeated request for the same value follows the newer one's outcome |
| Cancel did nothing in the confirmation dialogs | the editor's browser test | `VF.modal` closes on any plain value |
| A property-page summary lagged a publish by up to 30 seconds | `test_venueflow_driver.lua` [4] | the driver repaints on every event |
| A client could change, rename or remove the profile a tile or a station opens with, or set its PIN, widening what anyone on the LAN may do | adversarial review, 18 Nov 2026; `test_venueflow_clientstudio.lua` | those profiles are installer-owned as whole records |
| A client could publish or discard the installer's half-built work when it touched only client-owned parts | adversarial review; `test_venueflow_clientstudio.lua` | the draft records who saved it; a client is refused while it holds an installer or remote save |
| A draft revision could repeat after a discard, a publish or a restore | adversarial review; `test_venueflow_store.lua` | a stored counter that never goes back and travels in a backup; `baseRevision` on `PUBLISH` and `DRAFT_DISCARD` |
| An operation partly outside a profile's access told its original label and who asked (`origin`) | adversarial review; `test_venueflow_permissions.lua` | label counted over what the profile sees; no `origin` for a profile |
| `SCENE_ACTIVATE` accepted an area outside the profile's access; `ALERT_DISMISS` removed an alert the profile is not shown | adversarial review; `test_venueflow_permissions.lua` | both refused |
| *Trigger the VenueFlow event* reported success under a restricted licence while no rule ran | gap audit; `test_venueflow_driver.lua` | refused, with the reason in Last Error |
