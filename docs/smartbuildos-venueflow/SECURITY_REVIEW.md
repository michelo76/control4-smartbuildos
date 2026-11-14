# VenueFlow security and release-quality review

Reviewed 14 November 2026 against the eleven points of the brief (section
22). "Evidence" names the automated check; every check runs on the simulator
or the test shim, not on a controller.

## The eleven points

| # | Point | Finding | Evidence |
| --- | --- | --- | --- |
| 1 | Review all command inputs | Every request passes `protocol.lua`: a known command, a bounded request id, a typed payload with no unknown field, bounded strings (4 kB; 2 MB only for the two upload commands), lists of at most 256 ids (4000 for publish acknowledgements), finite numbers, enumerated values. HTTP bodies over 4 MB are refused at the header, before the body arrives; a header block over 16 kB is refused; a large upload is buffered in chunks and joined once | `test_venueflow_relay.lua` "invalid payloads", "request parsing" |
| 2 | Enforce command authorization | Scope per command (public, operator, installer) is checked in `core:handle` before any handler runs; inside, each engine asks the session's Access object per request and per device | `test_venueflow_permissions.lua` (244 checks), `test_venueflow_relay.lua` "identity" |
| 3 | Review exposed endpoints | Five routes: `/ping`, `/app`, `/studio`, `POST /api`, `OPTIONS`. The first three carry no secret and change nothing. Anything else is 404 | `test_venueflow_relay.lua` "routes" |
| 4 | Validate all configuration schemas | A draft is migrated, normalised and validated on every save; publishing needs zero errors and every warning acknowledged; a document from a newer schema is refused | `test_venueflow_schema.lua`, `test_venueflow_store.lua` |
| 5 | Prevent arbitrary code execution | Programs are data from a fixed vocabulary; an unknown step, condition or trigger is refused at validation and never executed by the runner. No `loadstring`, `load`, `dofile`, `os.execute`, `io.popen`, `setfenv` or `debug.` in any engine; no `eval`, `new Function`, `document.write` or HTML built from strings in either page. Floor plans are PNG, JPEG or WebP only (SVG is refused) | `test_venueflow_security.lua`, `test_venueflow_rules.lua` "validation", "runner bounds", `test_venueflow_store.lua` "floor plan images" |
| 6 | Check for embedded credentials | None. The Installer Passcode is a hidden property with an empty default. The development passcode and tile token exist only in the development host and the test harness, and are checked absent from the driver, the engines and both pages. The one PIN in the tree is the documented sample venues' manager PIN, usable only in Simulation | `test_venueflow_security.lua` "no credential in what ships"; gitleaks (below) |
| 7 | Review dependency security | The driver adds no dependency: it uses the repository's vendored `JSON.lua` and `drivers-common-public`, already shipped by every driver here. The pages load nothing external (checked). Build tools are unchanged | `test_venueflow_security.lua` "pages" |
| 8 | Remote administration requires authentication | Installer Studio needs the Installer Passcode (6+ characters; no passcode means the Studio is off). Wrong attempts lock per client address and overall. Sessions expire, idle out, and end when the passcode changes. There is no remote (cloud) administration path in this build | `test_venueflow_permissions.lua` "Installer Studio sign-in", `test_venueflow_driver.lua` [3], [9] |
| 9 | No control through an unauthenticated configuration endpoint | There is no configuration endpoint outside the protocol, and every operator and installer command is refused without an identity. Looped over the whole protocol | `test_venueflow_relay.lua` "identity" (every command), `test_venueflow_permissions.lua` "unauthenticated" |
| 10 | Local operation survives network disruption | Nothing in the core makes a network call. With no Agent, an unreachable cloud or the grace period, everything works. A page that cannot reach the controller says so and recovers | `test_venueflow_license.lua` "cloud outage"; page behaviour: browser check; a real LAN drop: hardware H3 |
| 11 | Configuration backups can be restored | Export, restore on a second driver, publish, and the venues are equal, pictures and staff PINs included | `test_venueflow_store.lua` "backup and restore" |

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
| The Studio could not show a draft floor plan before the first publish | `test_venueflow_store.lua` "backup and restore" | `IMAGE_GET` is allowed to an installer session without a published venue |
| The same source asked for twice on one display was reported as a conflict ("superseded") | `test_venueflow_rules.lua` "regressions" | a repeated request for the same value follows the newer one's outcome |
| Cancel did nothing in the confirmation dialogs | the editor's browser test | `VF.modal` closes on any plain value |
| A property-page summary lagged a publish by up to 30 seconds | `test_venueflow_driver.lua` [4] | the driver repaints on every event |
