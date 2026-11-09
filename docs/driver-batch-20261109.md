# Driver batch — 9 November 2026

Eight dealer-tooling drivers requested by the owner, built in parallel on
branch `feat/event-tracer` (worktree `control4-smartbuildos-event-tracer`).
This file is the contract every builder follows; the allocations below are
fixed so no two drivers collide.

## Allocations

| # | Driver folder / c4z | Composer name | SKU | module_id / prefix | Surface |
| --- | --- | --- | --- | --- | --- |
| 1 | `smartbuildos-user-manual` | SmartBuildOS Home Guide | `SBOS_USER_MANUAL` | — | uibutton web view (Atmosphere pattern) |
| 2 | `smartbuildos-guest-mode` | SmartBuildOS Guest Mode | `SBOS_GUEST_MODE` | — | Composer only (combo) |
| 3 | `smartbuildos-usage-analytics` | SmartBuildOS Usage Analytics | `SBOS_USAGE_ANALYTICS` | `usage_analytics` / `usage.` | Composer (combo) + Agent pipeline |
| 4 | `smartbuildos-notification-router` | SmartBuildOS Notification Router | `SBOS_NOTIFICATION_ROUTER` | — | Composer only (combo) |
| 5 | `smartbuildos-logic-pack` | SmartBuildOS Logic Pack | `SBOS_LOGIC_PACK` | — | Composer only (combo) |
| 6 | `smartbuildos-solar` | SmartBuildOS Solar Position | `SBOS_SOLAR` | — | Composer only (combo) |
| 7 | `smartbuildos-dealer-panel` | SmartBuildOS Dealer Settings | `SBOS_DEALER_PANEL` | — | uibutton web view (Atmosphere pattern) |
| 8 | `smartbuildos-variable-inspector` | SmartBuildOS Variable Inspector | `SBOS_VARIABLE_INSPECTOR` | — | uibutton web view (Atmosphere pattern) |

Pure modules live under `src/<shortname>/` using these short names:
`usermanual`, `guestmode`, `usage`, `notify`, `logic`, `solarpos`,
`dealerpanel`, `varinspector`. Tests are `test/test_<shortname>_*.lua`.
Design notes go to `docs/<driver-folder>/DESIGN.md`. Nothing else in the
repo is a builder's to edit (shared files — `src/sbos/envelope.lua`,
`CHANGELOG.md`, the Makefile, the Agent — are the coordinator's).

## Non-negotiable rules (from the owner and from what the bench taught today)

1. **Licensing through the Agent.** `local license = require("sbos.license")`,
   `license.setup({ sku = SKU })` in `OnDriverLateInit`, `EC.SBOS_ENTITLEMENT`
   wired to `license.onEntitlement`, and the four standard read-only
   properties declared in driver.xml: `License Status` (default `No
   SmartBuildOS Agent Found`), `License Source`, `Subscription Tier`,
   `SmartBuildOS Company` (defaults `-`). Enforcement follows the charter:
   `license.enforces()` true (definitive denial AND enforcement on) puts the
   driver in a read-only / stopped state and says so; every uncertain status
   leaves it working. Copy the shape from
   `drivers/smartbuildos-event-tracer/driver.lua` (`reconcileLicence`).
2. **`<combo>true</combo>` in driver.xml** for every proxy-less driver, right
   after `<modified>`. Without it Composer imports the driver and never lists
   it (measured today). Web-view drivers have a uibutton proxy and do not
   need it (follow `drivers/smartbuildos-atmosphere/driver.xml`).
3. **XML shape.** Copy `drivers/smartbuildos-event-tracer/driver.xml` for a
   combo driver and `drivers/smartbuildos-atmosphere/driver.xml` for a
   web-view driver. `<description>` only on LIST properties, events,
   conditionals and commands. `minimum_os_version` 3.3.2, manufacturer and
   creator `SmartBuildOS`, `<created>11/09/2026 12:00 PM</created>`, empty
   `<version>` and `<modified>` (the build stamps them), category `Utility`.
   Standard properties `Driver Status`, `Driver Version`, `Log Level`,
   `Log Mode` exactly as the tracer declares them.
4. **Pure logic in `src/<shortname>/`, thin driver.lua.** Every rule a
   technician relies on is in a pure module with an injected Director
   surface and a test under `test/`. Driver tests follow
   `test/test_tracer_driver.lua` (fake Director, scripted Agent, property
   table read from the driver.xml). `make test` must stay green; run only
   your own files through stylua (`stylua --indent-type Spaces --column-width
   120 --line-endings Unix --indent-width 2 --quote-style AutoPreferDouble
   <files>`), never the whole tree.
5. **Only documented or shipped-driver APIs** as design dependencies (the
   ranking rule: measured > shipped driver > docs > nothing). The emulator's
   API table is `~/Documents/Codex/control4-director-emulator/src/director/apidoc.lua`
   and the cached docs are under `~/Documents/Codex/control4-director-emulator/.cache/docs/`
   (read-only reference). Anything unconfirmed is a PROBE with a fallback,
   named in DESIGN.md, never a silent assumption. Known-good calls:
   `C4:GetDevices({})`, `C4:GetDeviceVariables(id)`, `C4:GetDeviceVariable`,
   `C4:SetDeviceVariable(id, varId, value)` (documented, not for
   OnDriverInit), `C4:RegisterVariableListener` + `OnWatchedVariableChanged`,
   `C4:RegisterDeviceEvent` + `OnDeviceEvent`, `C4:GetProjectItems`,
   `C4:SendToDevice`, `C4:url` via `lib.http`, `C4:CreateServer`/`ServerSend`
   (Atmosphere's relay), `C4:SetTimer` via the vendored `SetTimer(name, ms,
   fn, repeating)`, `lib.persist`.
6. **Web-view drivers** copy Atmosphere's proven path, not a new one: uibutton
   proxy with `<web_view_url proxybindingid="5001">controller://driver/<c4z-name>/app/index.html</web_view_url>`,
   `mobile_web_view_enabled`, icons (copy `drivers/smartbuildos-insights/www/icons/`
   wholesale), a LAN relay on its own port (pick: user-manual 47821,
   dealer-panel 47822, variable-inspector 47823) with a minted token in the
   URL query, the pure router modelled on `src/atmosphere/uirelay.lua`, and
   `URL_CHANGED` on every change. Read `docs/atmosphere/WEBVIEW.md`,
   `docs/atmosphere-architecture.md` §4 and the relay code in
   `drivers/smartbuildos-atmosphere/driver.lua` (search `uirelay`,
   `CreateServer`, `relayToken`) before writing a line. The page is plain
   HTML/JS in `www/app/index.html`, phone-first, no external assets.
7. **Privacy.** Never persist or display credentials; redact like
   `sbos.envelope.redact`. Tokens and PINs are `PASSWORD` properties.
8. **Scope discipline.** A complete, honest v1 tonight beats a wide one:
   every feature either works under the shim test or is listed as not
   included in DESIGN.md. No `make build`, no copying into
   `~/Documents/Control4/Drivers`, no commits, no edits outside your files.
9. **Composer surface conventions.** Actions for dealers (`Print …`, `Refresh
   Status`, `Register With Agent Now`), programming commands with STRING /
   DEVICE_SELECTOR / LIST params, events with ids from 1, variables from
   3000, conditionals from 1. Variables and events are re-added in
   `OnDriverLateInit` with `C4:AddVariable` / `C4:AddEvent` in `pcall`
   (static XML ones register only at first add).
10. **Documentation** in `www/documentation/index.md` (setup, behaviour, what
    is not claimed, actions, programming, privacy) in the tracer's voice.

## Per-driver scope (v1)

1. **Home Guide (user manual).** A personalised manual generated from the
   project: rooms and the devices in each (GetDevices + room names), grouped
   by proxy/driver category with a plain-language "how to" paragraph per
   category from a built-in text table (lights, shades, locks, thermostats,
   keypads, media rooms, cameras, garage, security), dealer contact block
   (Dealer Name / Phone / Email / Support Hours / Emergency Note properties),
   custom per-room notes (properties `Room Note 1..6` as "Room: text"), and
   a "what to do if" section (Director restart, Wi-Fi, remote batteries).
   Rendered by the page from a JSON snapshot the relay serves; refreshed on
   project change (Agent's `project_changed` is not available without the
   module client — use a `Refresh Manual` action plus hourly rebuild).
   `Print Manual Outline` action. No cloud.
2. **Guest Mode (short-let).** `Calendar URL 1..3` (iCal feeds: Airbnb,
   Booking, VRBO), polled every `Poll Interval` minutes through `lib.http`;
   pure iCal parser (VEVENT DTSTART/DTEND date and date-time, SUMMARY,
   folded lines, Z and floating times) and a stay engine with `Check-in
   Time` / `Check-out Time` properties: states `vacant`, `arriving_today`,
   `occupied`, `departing_today`, `turnover`; events Guest Arriving Today,
   Guest Checked In, Guest Checked Out, Turnover Due, Calendar Unreachable;
   variables GUEST_STATUS, GUEST_NAME, NEXT_CHECKIN, NEXT_CHECKOUT,
   GUEST_PIN, GUEST_WIFI_PASSWORD, STAYS_NEXT_30_DAYS; commands Check In
   Now, Check Out Now, Set Guest Wi-Fi Password; per-stay PIN generated
   (4–8 digits, property) at check-in and cleared at check-out, exposed as
   a variable the dealer wires to the lock's own user-code programming (lock
   user-code commands are not in the docs we hold: NOT sent by the driver).
3. **Usage Analytics.** Module on the Agent (`sbos.moduleclient`, module_id
   `usage_analytics`, prefix `usage.`, singleton). Measures: media hours per
   room per source (room variables via `RegisterVariableListener`: find the
   room device ids and the variable ids by name from `GetDeviceVariables`;
   the tracer's `CAPABILITY-MATRIX` row 3 says how), lights on-hours per
   light (LIGHT_STATE / LIGHT_LEVEL), keypad button presses per keypad
   (device events found through `tracer.catalog` + `tracer.catalog_data`
   for drivers whose event names contain "Press"/"Push"/"Click"). Daily
   rollups kept 30 days in persist; `Print Usage Report` (today, 7 days, 30
   days, least-used keypads/buttons, rooms never used); one `usage.daily`
   envelope per day and `usage.summary` on request. Never record variable
   values other than the typed ones above.
4. **Notification Router.** Programming command `Notify` (CHANNEL, PRIORITY
   low/normal/high/critical, TITLE, MESSAGE) and `Notify All`. Targets:
   Telegram bot (Bot Token, Chat ID), Pushover (App Token, User Key),
   Slack/Discord-compatible incoming webhook URL, generic webhook (POST JSON),
   Twilio SMS (Account SID, Auth Token, From, To). Per target: enabled,
   minimum priority, quiet hours (critical bypasses). Router rules: dedupe
   identical messages within `Dedupe Window`, rate limit per target per
   hour, retry with backoff (3 tries), delivery log ring (last 50) with
   `Print Delivery Log`, events Delivery Failed / Target Unreachable /
   Quiet Hours Suppressed, variables LAST_NOTIFICATION, FAILED_TODAY. Pure:
   routing decisions, formatting per target, backoff. HTTP through `lib.http`.
5. **Logic Pack.** Named primitives for Composer programming, all keyed by
   a STRING the programmer types (like the tracer's channels): counters
   (Increment / Decrement / Reset / Set; variables COUNTER_1..8 bound by a
   `Counter Slot N Key` property mapping; conditional Counter Is At Least
   with KEY and VALUE params), flags (Set / Clear / Toggle; conditional Flag
   Is Set), a state machine (Set State; variable CURRENT_STATE; event State
   Changed; conditional State Is), debounce (Debounce KEY MS: fires event
   Debounced Trigger once the key is quiet, variable LAST_TRIGGER_KEY),
   throttle (at most once per MS), once-per-day (event Once Per Day Passed),
   timers (Start Timer KEY SECONDS / Cancel Timer; event Timer Expired).
   First verify in the cached XML docs whether `<conditional>` supports
   `<param>`s; if not, use per-key variables and document the limitation.
   `Print State` action; everything persisted.
6. **Solar Position.** Reuse `src/atmosphere/solar.lua` (read it first; add
   anything missing in `src/solarpos/`): project latitude/longitude the way
   Atmosphere reads them (search `grab("latitude")` in its driver.lua) with
   property overrides and Director system events 52–54 for changes.
   Variables SUN_ELEVATION, SUN_AZIMUTH, IS_DAYLIGHT, DAY_PHASE (night,
   dawn, golden_morning, day, golden_evening, dusk), NEXT_SUNRISE,
   NEXT_SUNSET, MINUTES_TO_SUNSET; four facades (`Facade N Name`, `Facade N
   Azimuth`, `Facade N Width`, `Facade N Min Elevation`) with variables
   SUN_ON_FACADE_1..4 and events Sun Hits / Sun Leaves per facade; events
   Golden Hour Started, Civil Dawn, Civil Dusk. One-minute tick, hysteresis
   of one degree on facade edges. Tests against known NOAA values.
7. **Dealer Settings.** Twelve dealer-defined settings, each a property
   quartet `Setting N Name`, `Setting N Type` (Number / Toggle / Text /
   Choice), `Setting N Value`, `Setting N Options` (min..max for Number,
   choices for Choice). Exposed as variables SETTING_1..12 (typed) plus
   SETTING_<N>_NAME, event Setting Changed with variable CHANGED_SETTING,
   programming command Set Setting (NAME, VALUE), conditional Setting Equals.
   Web view: a phone-first page listing the settings with controls, gated by
   `Dealer PIN` (PASSWORD; empty = read-only page), writes through the relay
   (POST), Composer properties updated so there is one truth.
8. **Variable Inspector.** Web view: device list (room, name, driver), tap a
   device → its variables live (GetDeviceVariables, then
   RegisterVariableListener for the open device only), a watch list (persisted)
   with a history ring per watched variable (reuse `tracer.ring`), filters,
   and Set (SetDeviceVariable) gated by `Dealer PIN`. Credential-named
   variables (the tracer's FIXED_EXCLUSIONS list in `flightrecorder.config`)
   are shown masked and never writable. Composer: `Inspect Device ID`
   property + `Print Variables For Inspect Device`, `Print Watch List`,
   `Clear History`; variables WATCHED_COUNT, LAST_CHANGE; event Watched
   Variable Changed. Bounded: at most 64 watched variables.

## After the batch (coordinator)

Full `make test`, `make preprocess gen-squishy update-xml docs-html package`,
import every new `.c4z` and the rebuilt Agent into Composer from `dist/oss/`
(never from the Drivers folder), add each to the SmartBuildOS room, record in
CHANGELOG and each driver's DESIGN.md what the bench showed.

## Status 2026-11-09 ~01:30 (coordinator)

All eight drivers built and tested (1,018 new checks; whole suite 85 files,
0 failures; `test/test_driver_require_guard.lua` added). Packages built to
`dist/oss/` together with the rebuilt Agent (prefixes `capture.`, `tracer.`,
`usage.` compiled in), the rebuilt Event Tracer (catalogue now included,
`<combo>`), and the rebuilt Flight Recorder (`<combo>`). Each package was
checked to carry its own modules. Nothing committed.

### Composer runbook (what the coordinator does once the screen is unlocked)

Composer Pro runs in the Parallels "Windows 11" window on this Mac; macOS
blocks window input while the screen is locked, so the import waited.

1. Driver → Add or Update Driver or Agent, pick the file from
   `\\Mac\Home\Documents\Codex\control4-smartbuildos-event-tracer\dist\oss\`
   (never from `~/Documents/Control4/Drivers`: that is Composer's own folder
   and importing from it corrupts the file), one at a time, in this order:
   `smartbuildos.c4z` (Agent; pairing survives via Pairing Backup),
   `smartbuildos-event-tracer.c4z`, `smartbuildos-flight-recorder.c4z`,
   then the eight new ones.
2. In System Design select the room **SmartBuildOS** (create it under the
   house if it does not exist), then Items → Search (Local) each driver by
   name and double-click it to add it to the selected room. Web-view drivers
   add an Experience button to that room.
3. Read on each: License Status (should move from "No SmartBuildOS Agent
   Found" to "Checking…" then a licence line now that discovery is fixed),
   Agent Link / Agent Connection on the module drivers, and the first status
   line of each (Coverage, Catalogue, Stays, Sun elevation, Settings
   configured, …). Record in each DESIGN.md.

## Done 2026-11-09 07:05–07:25 — imported and installed on Beta Site 2

All eleven packages imported through Driver → Add or Update Driver or Agent
from `dist\oss\` (Agent, Event Tracer, Flight Recorder, then the eight new
drivers; each answered "Update Succeeded" / "successfully added"). The ten
drivers were added to the existing room **Smartbuildps** (Room ID 318,
Home → House → Control4): Event Tracer (already there, updated in place),
Guest Mode, Notification Router, Flight Recorder, Logic Pack, Solar Position,
Usage Analytics, Dealer Settings, Variable Inspector, Home Guide (the user
manual's Composer name). Per-driver readings are in each `docs/*/DESIGN.md`
("Bench 2026-11-09") and `docs/event-tracer/VERIFICATION.md`.

What the bench showed:

- **Agent discovery fixed**: every module driver paints `Agent device 72 –
  registered` / `ready`; every driver paints tier `Enterprise` and the
  company. New drivers show `SmartBuildOS Agent Found – Checking…` for up to
  ~5 minutes before the tier arrives.
- **Catalogue fixed**: the tracer reports `built-in: 187 driver(s)`.
- **One defect found and fixed on the bench**: `<type>PASSWORD</type>` on
  *Dealer PIN* (Dealer Settings Panel, Variable Inspector) makes Composer
  raise "Property Invalid … Object reference not set"; changed to
  `<type>STRING</type><password>true</password>`, rebuilt as 121857 and
  re-imported (project instances updated in place). CHANGELOG has the entry.

Composer lessons added to the runbook:

- Double-clicking a search result adds the driver only while a **room** is
  selected in System Design; with a device selected nothing happens, so
  re-select the room before every add.
- Keyboard input from macOS into the Parallels VM is unreliable (dropped
  characters, a stuck repeating key): drive Composer with clicks — the
  Items **Clear** button, the Manufacturer filter, the file list sorted by
  the Name header, double-clicks — and never rely on typed search terms.
- Items → Search with an empty term and Sort = Relevance lists the most
  recently imported local drivers first (ours were results 1–10).
- A `.c4z` already present in Composer's Drivers folder at the same version
  triggers "Versions are equal — overwrite?"; **Yes** is the update path and
  also refreshes the instances in the project.

Still owed: the web-side work listed per driver (SKU catalogue rows, prefix
ownership, command verbs, Studio pages), and a commit of this batch.

## Studio side built 2026-11-09 afternoon (web repo)

Web branch `codex/dealer-tooling-studio` (worktree
`~/Documents/Codex/smartbuildos/.claude/worktrees/dealer-tooling-studio`),
stacked on `codex/flight-recorder` (PR #394). Its `docs/dealer-tooling/README.md`
has the detail. In short: catalogue migration for the nine SKUs, prefix
ownership, operation vocabulary with validated args, and three Studio
sections (Activity → Event Tracer, Activity → Usage, Drivers & Licenses →
SmartBuildOS tools). Web suite 10,375 / 10,375; nothing merged, no migration
applied, nothing deployed.

Driver changes that go with it (this branch, suite 85 files / 4,702 checks,
packages rebuilt as `20261109.203405` in `dist/oss/`, NOT yet re-imported
into Composer): the Agent's `MODULE_COMMANDS` gained the two modules, and
the Event Tracer writes a Studio policy into its Composer properties and
reports its running policy in `tracer.applied`.
