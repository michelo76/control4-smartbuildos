# <span style="color:#F97316">Changelog</span>

<!--
Template for a new release entry (copy below the heading, fill in, uncomment):

## v[Version] - YYYY-MM-DD

### Added
- Added

### Fixed
- Fixed

### Changed
- Changed

### Removed
- Removed
-->

## Unreleased

### Added

- **Logic Pack: Logic Blocks** (`docs/smartbuildos-logic-blocks/DESIGN.md`). Up
  to 16 named rules, set up on the Properties and Actions tabs: cooldown, quiet
  period, restartable timer, once per day, flag, counter, all/any conditions,
  threshold with a deadband, stable-state filter and state selector. Programming
  feeds a block with the new `BLOCK_*` commands, or the block reads a device
  variable; each slot has its own events, variables and conditionals. A dealer
  app, served by the driver on the home network, shows each block's rule, inputs
  and decisions and has a sandbox that simulates one block without touching the
  live one. Every classic command, event, variable and conditional is unchanged,
  and a block never takes over a free-form key. The Logic Pack is now in the
  store publish map and the Agent's update list, so a release publishes it and
  installed copies update in place. Not yet run on a controller:
  `docs/smartbuildos-logic-blocks/BENCH.md` lists what is owed.

- **Agent: Studio release G1 reporting**
  (`docs/studio-g1/AGENT-CONTRACT-G1.md`). The heartbeat now carries three
  optional blocks. `device_poll` confirms each 5-minute poll with a digest the
  platform can check, so devices stop reading "stale". `controller` reports the
  time zone, locale, host name and boot id. `last_errors` gives the last failure
  reason for each upload. A full sync now adds the project's rooms (empty ones
  included) and a census of its driver files. Each device row gains `room_id`.
  Devices with no network binding (IR, serial, relay) are now reported as "not
  monitored". Six new capability strings are declared. A platform that ignores
  the new keys sees no change.

### Changed

- **Agent: `online` is now `null` when there is no state to report.** This
  covers an unaddressed binding (`NOT_SET`), which used to be sent as `false`,
  and a device with no network binding. `devices_total` now counts those devices
  too.

### Fixed

- **AI Core: the configuration System Studio publishes is now accepted, so
  learning can be switched on.** The platform's document had a different shape
  from the driver's schema 1 and was refused whole, which kept learning off.
  Both sides now build to the same contract; the platform's golden documents are
  fed to the driver's validator by the cross-repo parity test and delivered
  through the real Agent in the emulator. Excluded rooms go up to 500 (the
  platform's own bound). A room is the Director room id on both sides; the
  platform translates its learning categories to the driver's.
- **AI Core: a pause takes effect at once.** `set_learning` gains
  `config_version`: System Studio sends it (and `apply_config` for exclusions)
  as soon as learning or exclusions change. The configuration document stays the
  source of truth: an operation for a version already applied is ignored, a
  preview holds only until that version's document arrives, an older
  `apply_config` never replaces a newer document, and learning cannot be
  switched on over a refused document.
- **AI Core: `AI_RECORD_EVENT` works with learning off or paused** (it is a
  dealer's marker, not learning); excluded rooms and categories still refuse it.
- **AI Core: payload text is cut between characters.** A long non-ASCII `DETAIL`
  or question used to reach the shared envelope, which cut it in the middle of a
  character; the Agent then refused the whole frame as malformed. AI Core now
  cuts every payload string and label between characters itself. The shared
  envelope is unchanged for the other drivers (`docs/ai-core/KNOWN-ISSUES.md`
  KI-1).
- **AI Core: Sync Now's `status` request carries only its request id**, the only
  field the platform accepts.

### Added

- **AI Core: Run Household Analysis from Control4 programming.** A new
  programming command, `AI_RUN_HOUSEHOLD_ANALYSIS`, asks SmartBuildOS to run the
  household analysis (op `analyze_household`; the Agent relays it). It needs the
  `AI_LEARNING` licence feature and is refused on the controller without it. At
  most one accepted run an hour and one request at a time, so programming in a
  loop sends nothing; a refusal or an outage does not use up the hour. The
  normal answer is *accepted (queued)*: the result appears in System Studio and
  the driver is never told when the run finishes. Refusals show SmartBuildOS's
  reason (`learning_not_allowed`, `not_licensed`, `already_running`,
  `rate_limited` with the wait); an Agent too old to relay it says so.
  `AI_ANALYZE_SYSTEM` is unchanged.

- **SmartBuildOS module contract v2 (Agent + module client).** A strict superset
  of v1 (protocol 1..2 negotiated; v1 modules unchanged): capability manifest on
  registration, discovery with debounced directory-change pushes, local pub/sub
  of envelopes the Agent accepted (bounded, lossy by design), module-to-module
  requests routed by the Agent with sender stamping, closed policy tables,
  idempotency, deadlines and cursor paging, a closed-vocabulary cloud relay to
  `/api/integrations/control4/modules/rpc`, per-module rate limits, bus counters
  on the heartbeat, and registration tokens from `C4:UUID("RANDOM")`. Spec:
  `docs/protocol/MODULE-CONTRACT-V2.md`. Emulator-verified only; bench
  validation owed.

- **SmartBuildOS AI Core (`smartbuildos-ai-core`, SKU `SBOS_AI_CORE`).** The
  controller-side half of AI Core on module contract v2: ten Composer commands
  (validated and bounded; one cloud op each through the Agent, with an
  idempotency key; refusals shown as they are), ten Composer events, eleven
  variables and five conditionals, six restricted operations from the platform
  with closed argument sets (none controls equipment), whole-document
  configuration (no key ever reaches the controller; the credential property is
  status text), collection without double capture (Flight Recorder topics
  consumed; own collector for Director system events, and a minimal set when the
  recorder is absent), a persisted critical-event buffer with counted drops,
  local diagnostics from the Flight Recorder's ring. Reference:
  `docs/ai-core/DRIVER.md`. No physical controller has run it.

- **AI Core: licensing, failure-mode and parity tests; installation and release
  documentation.** Licensing end to end (activation, controller binding,
  tampering, grace and validation-required on a virtual clock, renewal and
  transfer without a reload, feature gating, uncertain states, store update
  selection) in unit tests and the emulator with the real Agent and real
  signatures; the product brief's failure modes mapped to named tests in
  `docs/ai-core/TEST-MATRIX.md` with a 20-procedure hardware validation plan; a
  cross-repo parity test against the platform's mirrors (`SBOS_PLATFORM_REPO`);
  `docs/ai-core/INSTALLATION.md` and `docs/ai-core/RELEASE.md`. Simulation only.

- **Flight Recorder: local history over module contract v2.** Manifest
  `sbos.flight_recorder` with `events.query`, `events.timeline`,
  `events.device_history`, `events.room_activity` (cursor-paged, under 24 KB,
  each entry citing its uploaded envelope's `event_id`, retention stated) and
  the `events.subscribe` topic. Unchanged against a v1-only Agent.

- **VenueFlow (`smartbuildos-venueflow`, SKU `SBOS_VENUEFLOW`): a commercial AV
  control surface on an existing Control4 project.** Four operator screens on
  one UI Button tile (Visual Floor Plan, Command Center, Simplified Room
  Control, Manager Overview) and Installer Studio, served on the venue LAN from
  the driver's relay: setup wizard, device discovery and mapping with test
  actions, a drag-and-drop layout designer, a visual programming editor for
  scenes, rules and schedules with dry run, staff profiles enforced by the
  driver, diagnostics, backup, publish and rollback. A capability-aware routing
  engine reports one outcome per display and never reports a dispatched command
  as done; audio zones are independent of video; the driver starts in Simulation
  and sends nothing to Control4 until set to Live. **Simulation verified only.**
  On a bench controller it installs, serves its pages, publishes and survives a
  driver restart, all in Simulation; it has not yet controlled real equipment
  (`docs/smartbuildos-venueflow/HARDWARE_VALIDATION.md`). `make venueflow`
  builds just this driver and does not copy it into Composer's folder.

  - **Venue Studio for the client.** A staff profile that holds the new Venue
    Studio permission (the Owner role by default) opens the Studio with its PIN,
    from the tile's profile menu or on the page, and changes scenes, schedules,
    staff and PINs, source names and channel labels and volume presets, and
    publishes that. The driver refuses a client's change to anything else.
    Simulation verified; not yet tried on a Navigator.
  - **Basic source controls.** A source can have channel up, down and last, a
    number keypad, arrows with guide, info and menu, and transport keys, plus up
    to 24 favourite channels dialled with one press. Staff with the new "Use
    source controls" permission get a remote beside the source; the venue edits
    favourites in the Venue Studio. The page names a key from a closed list; the
    driver sends the documented Control4 command to the source's own device.
    Simulation verified only: not yet seen to move a real box, and there is no
    feedback.
  - **Remote Management.** A property (Off by default, Draft only, Draft and
    publish) lets smartbuildos.io read the configuration, fill the draft and,
    where allowed, publish and roll back, through the Agent's module contract
    (module `venueflow`; one Agent allowlist entry and one envelope prefix). It
    never controls equipment. The smartbuildos.io side (System Studio, Drivers &
    Licenses, VenueFlow) is merged and deployed, but the two sides have **never
    been run together with a controller**, and the catalogue row for
    `SBOS_VENUEFLOW` is not applied yet, so no licence can be issued for it.

- **Agent: restarts counted per day.** New property **Director Reloads Today**
  and variable `DIRECTOR_RELOADS_TODAY`: Director reloads since the controller's
  local midnight, back to 0 every midnight. The reload report to SmartBuildOS
  carries the day's count, so the email can say "restart number 3 today" instead
  of only the count since monitoring began. **System Startups Today** and
  **Controller Reboots Observed Today** now also return to 0 at midnight; they
  used to wait for the next restart.

- **Agent: Send Push Notification, with no 4Sight subscription.** A new
  programming command on the SmartBuildOS Agent, `SEND_PUSH_NOTIFICATION`, with
  `TITLE`, `MESSAGE`, `SEVERITY` (Info, Warning, Critical) and four variable
  pickers that work as they do in the Notification Router (`${1}` to `${4}`,
  `${Room->Device::VARIABLE}`, `${1|Open|Closed}`). The Agent posts the message
  to SmartBuildOS on its own connection, and SmartBuildOS sends it as a push to
  the SmartBuildOS Field app and as a web push to the people in the system's
  recipient profile, through each person's own notification settings and quiet
  hours. Control4's Push Notification agent is not involved. The same message is
  sent once in five minutes and at most 30 leave in an hour; *Notification
  Failed* fires when a push was attempted and SmartBuildOS refused it or could
  not be reached. New action *Send Test Push* and read-only property **Last Push
  Notification**. Needs the matching push service on SmartBuildOS; not yet run
  on a controller.

- **A full manual for every driver.** The other 40 drivers now have the same
  kind of manual as the Notification Router and Solar Position: what the driver
  is for and a table of use cases, where the stock way is still the right tool,
  setup as a walkthrough, how it behaves, worked examples that name the exact
  event, conditional, variable or command, a programming reference, how to read
  the status, and what is not claimed. Each was written from the driver's code
  and tests, not from the old page, and every name was checked against
  `driver.xml`. Where the code and the old manual disagreed the manual now
  follows the code (the camera's snapshots and PTZ, the Agent as an agent and
  not a project driver, commands by their real names, limits and defaults), and
  behaviour that surprised us is written down as it is, under the section it
  affects.

- **Solar Position: a ceiling per facade.** `Facade N Max Elevation` (90 = no
  limit) is the highest sun that still counts, for glass under an overhang or a
  balcony and for the midsummer sun that stands in front of south glass without
  entering it. Facade Status says `shade (sun too high)` when that is the
  reason, a ceiling at or under the floor is reported (`facade 2 not used: …`)
  instead of leaving a facade that can never light, and a facade with a ceiling
  can be in the sun twice a day, with two pairs of events.

- **Solar Position: an event at every boundary of the day.** *Sunrise*,
  *Sunset*, *Night Began* (evening twilight over), *Evening Golden Hour Started*
  and *Morning Golden Hour Ended* join *Civil Dawn*, so first light, sunrise,
  full daylight, low evening sun, sunset and dark each have one event, plus the
  conditional *It is night*. *Golden Hour Started* and *Civil Dusk* keep firing
  as before for programming that uses them. The horizon is judged on its own, so
  a late tick still reports the crossing.

- **Solar Position: the manual.** Why a sunrise or sunset schedule cannot do
  this (the driver's own figures for a west and a south facade through the
  year), a table of use cases, walkthroughs for setup and for describing a
  facade, how to choose Max Elevation for an overhang, four worked examples, the
  day boundary by boundary, and a calculator in the page that answers "when is
  the sun on this glass" for any site, date and facade with the driver's own
  rules (checked against the engine on fourteen cases).

- **Interactive manuals for every driver.** A driver's documentation is now one
  self-contained interactive page: a contents list that follows the page,
  search, walkthroughs whose steps you tick (your place is kept), screenshots
  that enlarge, and copy buttons on code. `tools/docs.py` builds it from the
  same `index.md` for all 42 drivers, embeds the screenshots in the page, and
  falls back to the plain document where script does not run (the PDF). The ten
  dealer-tooling drivers carry screenshots taken on the bench and a setup
  walkthrough; the Notification Router's manual adds Telegram, message and
  two-way walkthroughs and a try-it panel for composing a message. It opens with
  what the driver is for and a table of use cases, and has a Webhooks section
  with walkthroughs and worked examples for a Slack or Discord channel and for
  the Generic Webhook (the request as sent, each field, what to answer, a `curl`
  line).

- **Notification Router: a message is written in pieces.** Notify, Notify All
  and Reply now read MESSAGE, VARIABLE 1, MESSAGE 2, VARIABLE 2 … up to VARIABLE
  4 and MESSAGE 5, so words can follow a value: *This system rebooted* + a
  variable + *times* is sent as "This system rebooted 3 times". Pieces are
  joined with one space, tight against punctuation. Programming written before
  sends what it sent; `${1}`..`${4}` still place a value anywhere and word or
  round it.

- **Notification Router: SEPARATOR.** Notify, Notify All and Reply have a
  SEPARATOR list just above MESSAGE: what goes between one message (a text and
  the variable under it) and the next. **Space** (default) keeps everything one
  sentence, as before; **New Line** puts each message on its own line;
  **Period**, **Comma**, **Semicolon**, **Dash** and **Vertical Bar** are the
  others. Asked for after "Home is currently Occupied The security is currently
  Armed Away" arrived run together. Programming written before sends what it
  sent.

- **Notification Router: `MESSAGE_RECEIVED`.** A string variable that takes the
  text of each message the router accepts, for programming written as *when
  MESSAGE_RECEIVED changes, if it is equal to …*. It is not read-only, so
  programming can set or clear it. The same text arriving twice is still a
  change. **Message Received As** can lower-case it so a phone's capital letter
  does not break a condition.

- **Notification Router: Find Telegram Chat ID.** An action that lists the chats
  the bot has heard from, with their ids, in **Telegram Chats Seen**: people who
  wrote to it, groups and channels it was added to. It takes nothing, and the
  token no longer has to be pasted into a browser.

- **Message variables in the Notification Router.** A notification can carry the
  current value of any Control4 variable, value only, set up in the programming
  window the way the Push Notification agent does it. Notify and Notify All have
  four **VARIABLE** parameters that open Composer's own *Select variable…* tree;
  `${1}`..`${4}` in the TITLE or MESSAGE stand for them, and a picked variable
  that is not written into the text is added at the end.
  `${Room->Device::VARIABLE}` written out works too. `${1|Open|Closed}` words an
  on/off value, `${2|.1}` rounds a number. A variable that cannot be read is
  sent as `?`, raises *Message Variable Missing* and never blocks the send; a
  credential-named variable is sent as `[hidden]`. De-duplication compares the
  filled-in text.

- **Two-way messaging in the Notification Router.** With **Telegram Inbound** or
  **Twilio Inbound** on, a message sent to the bot or a text sent to the Twilio
  number becomes variables (`LAST_MESSAGE`, `TELEGRAM_LAST_MESSAGE`,
  `SMS_LAST_MESSAGE`, sender, channel, a counter) and events (*Message
  Received*, per channel, *Message Rejected*). Eight **Keyword** properties each
  have their own event, with the rest of the message as an argument, and a
  **Reply** command answers the sender with message variables. Only the chat or
  number the router already sends to is taken unless more are listed; messages
  older than two minutes are ignored, each is handled once across restarts, and
  an optional **Inbound PIN** is required and stripped. The router polls
  (default every 5 s); nothing has to be opened on the home router. Not yet
  exercised with a real message on a controller.

- **driver.xml guard**: a `DEVICE_SELECTOR` property with no `<items>` filter,
  and a `PASSWORD` property, are refused in every driver (both make Composer Pro
  2026.10.14 raise "Property Invalid" on import).

### Changed

- **Event Tracer and Flight Recorder are one driver**
  (`smartbuildos-flight-recorder`, SKU `SBOS_FLIGHT_RECORDER`, module
  `flight_recorder`). The `smartbuildos-event-tracer` driver is removed; its
  capture engine runs inside the Flight Recorder, on by default with no
  configuration. Both answered "what happened?", and a dealer had to add,
  license and read two drivers to get the events and the values side by side.
  - **One local history.** Device events, variable changes, trace steps, markers
    and the recorder's own notes are kept in one list in the order they happened
    (*Print Recent History*; the list survives a restart).
  - ***Print Last Trace*** prints everything between the start and the end of
    the last routine trace: its own steps, and what the house did in between.
  - ***Print History For Inspect Device*** shows one device's events, changes
    and trace steps, its event coverage and its watched variables.
  - **Snapshots carry the history** (newest 200 entries), the state of event
    capture and any active storm.
  - **One pause, one licence rule.** `PAUSE_RECORDING` and `RESUME_RECORDING`
    release and restore event subscriptions and variable listeners together; a
    definitive licence denial with enforcement on stops both (before, the
    recorder reported `unlicensed` and kept listening).
  - **Names.** `MARK_TIMELINE` is gone: `RECORD_EVENT` is the one marker
    command. Capture → **Event Capture**, Coverage → **Event Coverage**,
    Catalogue → **Event Catalogue**, Upload Budget → **Event Upload Budget**;
    **Recording Status** is the one status; new **Last Trace**. Events *Event
    Storm Detected*, *Event Storm Ended* and *Unknown Event Learned* are now
    events 10 to 12 of the Flight Recorder.
  - **Contract.** `capture.` and `tracer.` event types now belong to
    `flight_recorder` (`src/sbos/envelope.lua`), and the Agent's restricted
    commands for it gain `apply_policy` and `reapply`; the `event_tracer` module
    id is retired. **The web repo must follow** (`MODULE_PREFIXES`,
    `MODULE_OPERATIONS`, the Studio Event Tracer pages, the SKU catalogue):
    until it does, SmartBuildOS refuses the device events this driver uploads.
    Not yet run on a controller.
- **Event envelope: reserved prefixes.** A module with no event-type prefixes of
  its own can no longer emit under another module's prefix
  (`event_type_reserved`). The server has refused such events since the Flight
  Recorder review fixes; the Agent now refuses them at the module frame, so they
  are not queued and uploaded first.

### Fixed

- **AI Core closeout: text bounds, learning default, documentation.** (1) Every
  text field of every cloud-op body now satisfies the platform's rule for that
  field (`rpc/ops.ts` `validateOpBody`): C0 controls, DEL, C1 controls and
  U+2028/U+2029 become spaces, malformed UTF-8 is dropped, the ends are trimmed,
  and room and device names from Director are cut to 64 / 120 characters on a
  character boundary — a long or odd name used to make the whole command fail
  `invalid_args`. Typed text is counted in characters (as the platform counts),
  not bytes, and still refused over its bound. Envelope labels, `Last Error` and
  the `raise_event` detail are cut between UTF-8 characters too. (2) **Learning
  is off by default**: with no configuration, a document that does not mention
  it, or after an invalid document, learning is off (`LEARNING_ACTIVE` false,
  `Learning Status` says so) and nothing is collected; every collection source
  also defaults to off. A valid document that says on turns it on. (3)
  `DRIVER.md` and the dealer manual mark every required parameter
  (`AI_GENERATE_REPORT` `TYPE` and `PERIOD` included) and default, and say that
  `AI_LAST_RESPONSE` holds up to 1024 **bytes**. Tests:
  `test/test_aicore_learning_default.lua` (new), `test_aicore_commands.lua`
  [6]–[7], parity [8] (the `room_name`/`device_name` NOTE lines are now
  assertions). Simulation only.

- **AI Core: four contract mismatches with the platform, found in integration.**
  (1) `raise_event` accepts an optional `correlation_id` (1–96 characters, no
  control characters) — the platform's actions service sends one with every
  approval/action event, and the driver refused the whole operation; it is
  carried into a new `ai_core.event` envelope and the new variable
  `AI_LAST_CORRELATION_ID` (4010). Every other unknown key is still refused. (2)
  A cloud answer `{accepted: true, job_id: null}` (`set_context`,
  `send_notification`, a recorded `learn_preference`) is a completed request: no
  pending job, no `working`, no AI Response Ready (counter `cloud_completed`);
  `rate_limited` is shown as a refusal, not as "no answer"; the `set_context`
  body names the context key `key`, as the platform validates it. (3) The
  Agent's licence inventory keeps every instance of a SKU: removing a second
  instance of a driver no longer drops the SKU for the one that remains, and
  every instance is told its licence. (4) The cross-repo parity test compares
  every restricted-operation argument the platform sends with `operations.lua`
  and every cloud body the driver sends with the platform's `rpc/ops.ts`.
  Simulation only (unit tests and the emulator).

- **Agent: Director system events after pairing at run time.** The Agent
  registered for system events only in a start-up that found it already paired,
  so an Agent paired while running heard none (no Project Changed, Programming
  Changed, OS Update Started, device online/offline) until it was reloaded. It
  now also registers when pairing succeeds, once per event id.

- **AI Core: malformed input fails closed.** A malformed directory or Flight
  Recorder answer no longer throws inside a callback (a diagnostic was lost and
  `run_diagnostic` stayed `Executing`); a corrupted persisted state no longer
  stops start-up before the timers; the persisted buffer is bounded on load;
  module tokens are no longer printed at Log Level 5; platform-chosen text shown
  in properties is bounded. `raise_event ai_provider_error` now also sets
  `AI_LAST_ERROR` / `Last Error` until the next result.

- **Dealer tools: five defects from the review of their pull request**, each
  reproduced by a test first (shim only; not built, not run on a controller).
  Commissioning Matrix: a verdict or an abort while a device is still in its
  test state sends it back at once (it stayed at full brightness, at the test
  position, or on the test source), and an AV room that was off is returned with
  ROOM_OFF (its "off" was read as unknown). PIN Lock: editing a temporary code
  no longer moves its expiry to the end of the day (a one-hour code lasted until
  midnight, and an expired one came back). Daypart Scheduler: a block started by
  hand resumes its volume ramp after a pause or a restart. MQTT Bridge: a child
  driver that reloads gets its retained state again.

- **VenueFlow: client limits, draft ownership, alerts and Composer wiring** (18
  November 2026; simulator and test shim only, not run on a controller). Found
  by an adversarial review and a gap audit. In the Venue Studio, the profile a
  tile opens with and every station's profile are the installer's as whole
  records, PINs included. Every draft save records who made it, and a client can
  no longer publish or discard a draft holding the installer's or the dealer's
  unfinished work. Draft revisions never repeat (across a discard, a publish and
  a backup restore); `PUBLISH` and `DRAFT_DISCARD` take an optional
  `baseRevision`. Operations shown to a staff profile no longer carry `origin`,
  and one the profile sees only part of gets a label counted over that part. A
  channel being dialled finishes across a publish unless its source's device or
  the control mode changed. `SCENE_ACTIVATE` refuses an area outside the
  profile's access, and `ALERT_DISMISS` an alert the profile is not shown. The
  Alerts property, `ALERT_COUNT` and *VenueFlow has alerts* now count the same
  alerts, detected ones included, and *Alert Raised* fires when a detected alert
  appears. *Configuration Published* fires on a rollback, the two true-or-false
  conditionals honour the "closed" and "clear" choices, and *Trigger the
  VenueFlow event* under a restricted licence is refused with a reason in Last
  Error, and a partly run one is reported there too; *Mark the venue* always
  sets the status and writes Last Error for rules a restricted licence kept from
  running. Stored alerts are shown on the operator page only to profiles that
  may see what they concern, and dismissing one updates `ALERT_COUNT` at once. A
  save with no draft keeps the staff PINs (the installer and remote paths
  dropped them). `refresh_status` answers with a one-line summary and the module
  reports the live version as `config_version`. The Agent lists
  `smartbuildos-venueflow.c4z` for its updater and SKU `SBOS_VENUEFLOW`. See
  `docs/smartbuildos-venueflow/RELEASE_NOTES.md`.

- **VenueFlow pages in three browser engines** (19 November 2026; desktop
  engines against the simulator, not a T3, a T4 or a phone). The pages ran for
  the first time in WebKit 27.2 and Firefox 159 as well as Chromium 159
  (Playwright 1.65, touch enabled, both sample venues): every operator, Studio
  and Venue Studio flow passed with no page or console error. Fixed: the floor
  plan now judges a tap from where the finger went down (WebKit and Chromium
  moved it onto a nearby control); an empty page icon (Firefox logged a blocked
  favicon request); toasts let taps through; dialogs size to the visible area
  and buttons no longer trigger double-tap zoom; no Studio control is rebuilt
  under a finger (38 of 288 timed taps were lost before, none after); the phone
  Floor Plan volume slider has its own row (84 to 236 px wide). Removing a
  favourite channel a scene or schedule uses now asks first and names them.
  Known: at 1024x600 the volume sliders are about one pixel per step. Firefox
  159 is not the touch screens' Firefox 96.

- **VenueFlow: device mapping is on site only; a "Tune a channel" step** (19
  November 2026; simulator and test shim only, not run on a controller). Owner
  decisions. Remote Management refuses, whole and with the new code
  `VF_ONSITE_ONLY`, a remote draft that would change which Control4 room or
  device something addresses or which command a custom route or a lighting
  preset sends, a remote publish while the draft's mapping differs from what is
  live, and a remote rollback to a version with another mapping; the detail
  names what was touched (at most 380 bytes) and nothing is stored. Everything
  else stays remote-editable. smartbuildos.io has not been changed to match.
  Scenes, rules and schedules gain a "Tune a channel" step (a favourite or a
  number, to the source's own device through the closed key list; sent, never
  confirmed; stopped with its run; after a cut-off number the next number for
  that box waits about 3 s, an assumption never seen on a box; other boxes are
  not held up). A shade's open and closed levels must be 0 to 100.

- **VenueFlow pages: small screens, stale drafts, the client's reason** (19
  November 2026; desktop Chromium against the simulator only, not on a T3, a T4
  or a phone). Every operator control was measured reachable at seven screen
  sizes from 1024x600 to 1920x1200 and on phones and tablets, the Venue Studio
  at four, the Installer Studio at four. Long names take two lines; the Venue
  Studio's header wraps on a phone. On the floor plan a tap near a display
  selects the nearest one and a tap between two opens "Which display?"; the side
  panel shows when it scrolls. The Studio sends `baseRevision` with Publish and
  Discard and reloads, without retrying, when the draft changed. A client is
  told in plain words whose unfinished changes block publishing, and sees the
  profiles screens open with read-only. Opening or closing the venue under a
  restricted licence says how many automations did not run. A new suite scans
  the pages for features Gecko 96 lacks (static only; none found). The manual
  gains ten screenshots, all from the simulator.

- **VenueFlow: six defects from the review of its pull request**, each
  reproduced by a test first (simulation and shim; not built, not run on a
  controller). Mapping tests on a sample venue left in the draft are refused in
  Live mode (they addressed the sample's invented Control4 ids in the real
  project). Several rules, or a rule and a room's feedback, can watch the same
  Control4 variable. Stopping a scene also stops the commands it had queued and
  not sent. `OPERATION_GET` is filtered by the profile's access. A schedule due
  just after a driver start or a publish is no longer skipped. A display or zone
  remapped to other hardware no longer keeps the old hardware's readings. See
  `docs/smartbuildos-venueflow/RELEASE_NOTES.md`.

- **The Agent registers for Director's system events** (`smartbuildos`).
  `OnDriverLateInit` named a `local function` declared further down the file, so
  the name was an unset global and the guarded init step was nil: one error line
  at start, and no registration. *Project Changed*, *Programming Changed* and
  *OS Update Started* could not fire, **Last Project Change** and **Zigbee
  Events** never moved, a device change waited for the timed poll, and with no
  shutdown notice every reload was classed `unexpected`. The step now calls the
  global `RegisterSystemEvents`. `test/test_locals_before_use.lua` reads every
  driver for the same mistake (a file-level local read above its declaration);
  the Agent was the only one. Not yet seen on a controller.

- **Secrets stay out of the log at Log Level Trace** (`src/lib/persist.lua`,
  Guest Mode). The storage library logged every value it wrote, so the guest PIN
  and Wi-Fi password, and for other drivers a Bond token or a relay token,
  appeared in the Lua tab and the controller log; a value stored encrypted is
  now logged as `<hidden>`. Guest Mode's `SET_GUEST_WIFI_PASSWORD` was also
  printed with its `PASSWORD` parameter by the command dispatcher at Trace; it
  no longer is.

- **Sunrise and sunset use the site's day, not the UTC day** (Atmosphere and
  Solar Position, `src/atmosphere/solar.lua`). In a western evening the UTC date
  has already turned, and the driver answered with tomorrow's sun: at 34°N 118°W
  in June `IS_DAYTIME` went false at 17:00 against a 20:06 sunset,
  `MINUTES_TO_SUNSET` read a day too long and *Sunset Approaching* never fired.
  In an eastern morning it answered with yesterday's, and the next sunrise could
  be in the past. The next sunrise and sunset are now searched over the days
  around today, so they are also right for a driver pointed at coordinates far
  from its controller.

- **Solar Position: `MINUTES_TO_SUNSET` and `MINUTES_TO_SUNRISE` never skip a
  number.** The value is a floor on a 60-second tick, so a few milliseconds of
  drift could take it from 31 straight to 29 and programming on "equals 30"
  would miss that day. The driver now walks the numbers in between.

- **Home Guide, Dealer Settings, Variable Inspector: the tile could be published
  at another device's address.** The controller's address was taken from the
  first `control4_*` device with a network binding; on a project with a second
  Control4 device on the network that was the other device, and all three tiles
  pointed where nothing listened. An address from a device binding is now only a
  candidate: the driver asks its own relay `GET /ping` on each and publishes the
  one that answers by name (`src/lib/relayhost.lua`).
  `C4:GetControllerNetworkAddress()` is tried first; **App Relay Address** still
  overrides everything; when nothing answers, no address is published and **App
  Data Relay** says so. Asked again every 15 minutes, so a changed lease is
  followed. Atmosphere and UniFi Protect use the older lookup and are not
  changed here.

- **Every driver: a plain text value saved by the driver was lost at the next
  restart.** Stored values are read back through Base64 and JSON so a saved
  table can be rebuilt; a saved *string* went the same way, and one the
  controller's decoder turns into nothing (anything with a space, comma, dot,
  dash or underscore) came back empty. Seen on the bench in the Agent: the
  company name was painted after a licence refresh and replaced by *Registered
  (name syncing)* after every driver update, so every dependent driver showed
  `-` for the company. The property name the Agent forwards, its Support ID,
  last-reload time and version, and the three Web View relay tokens were lost
  the same way. A stored string that is not an encoded table is now returned as
  stored. Bench-confirmed: the company name is shown straight after an update.

- **Every licensed driver: License Status stayed on "SmartBuildOS Agent Found -
  Checking..." after a driver update.** The licence ask sent while a driver is
  still starting got no answer on the bench when the Agent was already running,
  and nothing asked again; one press of *Register With Agent Now* painted it at
  once. An unanswered ask is now repeated after 5, 15, 30 and 60 seconds and
  then every five minutes, and stops at the first answer. Licensing stayed
  fail-open throughout: no driver stopped working.

- **Agent: the first real Director reload would have stopped the Agent
  starting.** The reload report to SmartBuildOS named two functions declared
  further down the file, so it threw from `OnDriverLateInit` the first time it
  ran. It had never run: a start was classified as "first" whenever the reload
  count was 0, an update never adds to the count, so an Agent that had only been
  updated read *Last Reload … (first)* for ever and never reached "reload". Both
  are fixed: the count alone no longer decides "first", and the report lives
  below the sender it uses.

- **Event Tracer: the probe could starve the events it already knew.** With
  *Probe Unknown Drivers* on, the subscription budget was spent in device-id
  order, 32 guesses for each unknown device, and catalogued devices with higher
  ids got nothing (bench: `1000 subscriptions on 35 of 186 devices`). Known
  events are now subscribed first and the probe gets what is left.

- **Event Tracer: an event from another day now says which day.** *Last Event*
  and *Print Recent Events* showed the time alone, so a history that spans
  midnight read as out of order.

- **Home Guide: every device was listed twice.** Director lists a driver and its
  proxy as two devices with one name. Entries of one room that share a name are
  now one line; two real devices with the same name and driver are one line
  marked `(2)`. A lamp driver is no longer classed with amplifiers, nor an AV
  switch or a Nintendo Switch with light switches.

- **Home Guide: Last Rebuilt moved every minute.** It was painted with the
  clock, not with the time of the rebuild.

- **Usage Analytics: Last Daily Summary read "none" after every update.** The
  time the summary was sent is now kept across restarts.

- **Notification Router: a notification with only a MESSAGE was sent twice
  over.** Its first 60 characters went out as a title line above the full text
  on Telegram, webhooks and SMS. The text is now sent once.

- Fixed

### Changed

- Changed

### Removed

- Removed -->

## Unreleased

### Added

- **Message variables in the Notification Router.** A notification's TITLE or
  MESSAGE can carry placeholders that are sent as the current value of a
  Control4 variable, value only: `{1}`..`{8}` for a slot (a device and one of
  its variables picked in the driver's properties, or one of the project's
  custom variables) and `{Device:VARIABLE}` inline. `{1|Open|Closed}` words an
  on/off value, `{2|.1}` rounds a number. A placeholder that cannot be filled is
  sent as `?`, raises *Message Variable Missing* and never blocks the send; a
  credential-named variable is sent as `[hidden]`. De-duplication compares the
  filled-in text. A slot's device is picked from a list the driver fills
  (`Name (Room) · id`): a `DEVICE_SELECTOR` property with no driver filter makes
  Composer Pro 2026.10.14 raise "Property Invalid" on import, and the driver.xml
  guard test now refuses it.

### Fixed

- **Dealer PIN property type** (Dealer Settings Panel, Live Variable Inspector):
  `<type>PASSWORD</type>` made Composer Pro 2026.10.14 raise "Property Invalid …
  Object reference not set to an instance of an object" when the driver was
  added; it is now `<type>STRING</type><password>true</password>`, the form
  every other password property in this repo uses. Measured on Beta Site 2, 9
  Nov 2026.

- **Agent discovery for every dependent driver.** Since the Agent moved to
  Composer's Agents panel (`<agent>true</agent>`, PR #31) it is no longer in
  `C4:GetDevices`, so every SmartBuildOS driver read "No SmartBuildOS Agent
  Found" while the Agent sat paired and connected (measured on Beta Site 2, OS
  4.3, 2026-11-09). `sbos.license` now finds the Agent in three tiers — project
  devices, `C4:GetDevicesByC4iName("smartbuildos.c4z")`, then the
  `GetProjectItems("AGENTS")` list (last `<id>` before the Agent's `<c4i>`) —
  and `sbos.mirror`, System Link and Atmosphere delegate to it instead of
  carrying their own copy of the old rule.

- **Composer listing of proxy-less drivers.** Flight Recorder and Event Tracer
  declare `<combo>true</combo>`; without it Composer imports a proxy-less
  `lua_gen` driver and never lists it in Items → Search.

### Added

- **Studio operations for the Event Tracer and Usage Analytics** (Agent
  `MODULE_COMMANDS`): `event_tracer` (apply_policy, pause, resume, reapply,
  refresh_status) and `usage_analytics` (send_summary, reapply, refresh_status),
  mirroring the web repo's `MODULE_OPERATIONS`. An older Agent refuses them by
  name.

- **Event Tracer: a Studio policy is written into the Composer properties.**
  `apply_policy` merges the keys sent over the running policy, refuses the whole
  change if any value is invalid, updates the properties and applies; it
  survives a reload and a later Composer edit wins. `tracer.applied` now reports
  the running policy (`payload.policy`) for Studio.

- **Dealer tooling batch** (new, 8 drivers, `docs/driver-batch-20261109.md`),
  every one licensed through the Agent by its own SKU: **Home Guide**
  (`smartbuildos-user-manual`, SBOS_USER_MANUAL) — a personalised manual
  generated from the project in a Navigator web view; **Guest Mode**
  (`smartbuildos-guest-mode`, SBOS_GUEST_MODE) — iCal short-let calendars → stay
  states, events, per-stay PIN variable; **Usage Analytics**
  (`smartbuildos-usage-analytics`, SBOS_USAGE_ANALYTICS, module
  `usage_analytics`, prefix `usage.`) — media hours, light on-hours, keypad
  presses, daily rollups uploaded through the Agent; **Notification Router**
  (`smartbuildos-notification-router`, SBOS_NOTIFICATION_ROUTER) — Telegram,
  Pushover, Slack/Discord webhook, generic webhook, Twilio SMS with quiet hours,
  dedupe, rate limits, retries; **Logic Pack** (`smartbuildos-logic-pack`,
  SBOS_LOGIC_PACK) — counters, flags, state machine, debounce, throttle,
  once-per-day, named timers for Composer programming; **Solar Position**
  (`smartbuildos-solar`, SBOS_SOLAR) — NOAA sun elevation/azimuth, day phases,
  four facades with hysteresis; **Dealer Settings**
  (`smartbuildos-dealer-panel`, SBOS_DEALER_PANEL) — twelve dealer-defined
  settings as variables, editable from a PIN-gated web view; **Variable
  Inspector** (`smartbuildos-variable-inspector`, SBOS_VARIABLE_INSPECTOR) —
  live device variables, watch list with history, PIN-gated Set. Web views
  follow Atmosphere's relay pattern (ports 47821–47823). 1,018 new test checks;
  **no hardware validation yet**.

- **Build guard** `test/test_driver_require_guard.lua`: every src `require` in a
  driver.lua must be at module scope, or the squish step leaves the module out
  of the .c4z (the tracer shipped without its catalogue this way).

- **Event Tracer** (new): `smartbuildos-event-tracer` captures every Composer
  event every device in the project fires, with no configuration, and keeps the
  sequence in a local ring (printable from Composer without a Pro session) and
  as `capture.event` envelopes through the Agent's pipeline. Event ids come from
  a three-tier catalogue — the project XML (bench PROBE), a built-in table
  generated from the dealer's driver library (`tools/gen-event-catalog.py`: 187
  drivers, 1,303 events), and ids learned at run time from opt-in probe
  subscriptions. Storm detection (one warning, then counted not recorded),
  upload budget (the local ring is not budgeted), subscription cap with
  per-device coverage, exclusions, Composer markers (`MARK_TIMELINE`),
  pause/resume, Studio commands. Licensing: `SBOS_EVENT_TRACER` through the
  Agent; a definitive denial with enforcement on releases every subscription.
  Envelope prefixes `capture.` / `tracer.` owned by `event_tracer`. **No
  hardware validation yet** — `docs/event-tracer/VERIFICATION.md` lists the
  bench plan; the first question is whether `GetProjectItems` without
  `LIMIT_DEVICE_DATA` carries `<events>`.

- **System Link** (new, 7 drivers): `smartbuildos-system-link` bridge links two
  Control4 projects through SmartBuildOS — each project owns its shared
  variables (BOOLEAN/INTEGER/DECIMAL/STRING/CHOICE), the other sees read-only
  mirrors with `.STATE` freshness twins; named one-time events; request/result
  routines with bounded slots; publication filters; freshness and an aggregate
  Remote System State; startup reconciliation that never replays events; loop
  guard; endpoint credential provisioned by the Agent
  (`SBOS_LINK_PROVISION_REQUEST`/`SBOS_LINK_PROVISION`); contentless Realtime
  doorbell plus a 20 s poll fallback; source-device exports with validated
  remote commands, owner-side schedules (controller-local time, fail closed on
  an untrusted clock) and command suspension. Companions
  `smartbuildos-system-link-{light,relay,contact,temperature}` present an export
  natively; `-thermostat` and `-shade` ship feature-gated (THERMOSTAT / SHADE on
  the pair licence) because their proxy vocabulary is taken from shipped
  drivers, not from a documented proxy guide. Licensing: one pair licence per
  link (`SBOS_SYSTEM_LINK`), companions inherit the bridge. **No hardware
  validation yet**; see each driver's documentation tab.

- **System Studio Agent Contract v1:** the existing SmartBuildOS Agent now
  self-applies the versioned `SBOS_AGENT` configuration returned by its normal
  heartbeat, persists startup/service-mode state separately from configuration,
  classifies add/update/startup without inventing controller evidence, records
  optional kernel boot-ID changes, queues authenticated startup observations,
  exposes the declared Composer actions/events/read-only variables/status
  fields, and reports its applied version and runtime state in heartbeat
  evidence. Existing action tokens, variable/event IDs, pairing, entitlement,
  Driver Cloud, and per-SKU configuration forwarding are preserved. Report
  actions record requests without claiming generation or delivery until a
  dedicated platform acknowledgement exists.

- **Driver Store forward-compatibility boundary:** Agent licensing remains
  SKU-generic for every dependent driver that registers through
  `SBOS_REGISTER_DRIVER`; unknown future store metadata is not interpreted on
  the controller. Package inventory and update filenames remain an explicit,
  reviewed allowlist so a storefront change cannot silently install software.

- **Bond driver suite** (new, 6 drivers): `bond-bridge` gateway (one per Bond
  Bridge / Smart by Bond unit — token letterbox stored encrypted, inventory sync
  with hash polling, BPUP push updates over UDP, per-function dynamic CONTROL
  bindings, one-button Auto Configure with rename-guarded naming, SBOS_BOND
  licensing) plus native-proxy children: `bond-fan` (fan proxy, speed clamping
  to the device's real max, direction/breeze/timer commands), `bond-light`
  (light_v2; real dimming only where the device has Brightness), `bond-shade`
  (blind proxy; position inversion handled, positionless shades drop the slider
  honestly, Stop = Hold), `bond-fireplace` (five Navigator tiles with a
  purpose-drawn icon set: power, flame level cycle, flame up/down, fireplace
  fan), and `bond-generic` (state-iconed toggle tile + relay connection for
  switches/heaters/bidets). Binding classes are SBOS\_-prefixed so the suite
  coexists with the official Chowmain-built Bond drivers in the same Drivers
  folder. Round 2 (from a study of that suite's seven-year changelog,
  `docs/bond-asks.md`): Bond **scenes** sync with a Run Bond Scene programming
  command; **PIN pairing** (the PIN printed on the unit unlocks the token
  endpoint — no app, no power-cycle); keypad **button links** with LED tracking
  on every child (toggle/up/down/stop per device type); and shade **movement
  feedback** that animates Navigator using the Bond's own `course_time` scaled
  by travel distance instead of a hardcoded delay.

- **Bond Heater** (`bond-heater.c4z`, 7th driver in the Bond suite): heaters
  with adjustable heat levels (Infratech and similar behind a Bridge Pro) as a
  heat-only thermostat whose dial setpoint IS the heat level 0-100 —
  Celsius-pinned so the ring reads unitless, ambient left blank because these
  devices have no sensor. Extras tab carries the auto-off timer in minutes (the
  factory fire-code cap stays in force). Toggle/heat-up/heat-down button links
  with LED tracking, relay connection, Turn On/Off + Set Heat + Set Timer
  programming. HT devices with SetHeat derive HEATER automatically; power-only
  heaters keep the simpler Bond Switch.

- **Bond mDNS auto-discovery**: the gateway searches for `_bond._tcp.local` at
  startup and on demand (Discover Bonds On Network action) with a one-shot RFC
  6762 resolver — the QU bit makes Bonds reply unicast straight to the driver's
  socket, no multicast group membership needed. Every Bond heard lists in the
  Discovered Bonds property as `id @ address` (with setup mode flagged); a
  factory-fresh instance auto-fills its Bond Address with the first Bond heard,
  and a configured gateway is never re-pointed. The DNS wire parser (name
  compression included) is pure and pinned by its own test suite.

- **Bond Keypad** (`bond-keypad.c4z`, 8th driver): Bond Sidekick remotes as
  Control4 keypads. Key presses arrive over the Bond's push protocol (the only
  way it reports them) and become, per key: Composer events (Tap / Double Tap /
  Hold Start / Hold End, 8 buttons, the event-id layout dealers already know),
  Tap and Double-Tap button links that click, and a Hold link that pushes on
  hold-start and releases on hold-end so a held Sidekick key ramps a bound
  dimmer like a real keypad button. LAST_BUTTON / LAST_EVENT / LAST_HOLD_MS
  variables cover any-key programming; coarse battery bands fire Battery
  OK/Low/Critical on transitions; a Learn New Sidekick gateway action opens the
  Bond's pairing window. Sidekicks sync as keypad pseudo-devices, so bindings,
  provisioning and renames reuse the existing machinery unchanged.

- **Bond Weather** (`bond-weather.c4z`, 9th driver): Breeze weather stations as
  Control4 sensors. Every measurement becomes a programming variable
  (temperature both scales, humidity, wind m/s, rain rate, sun level, both
  batteries) with transition-only events — Rain Started/Stopped, Wind and Sun
  Triggered, battery Low/OK for both cells, Freeze Warning, Data Lost/Restored.
  The differentiator: Outdoor Temperature and Outdoor Humidity provider
  connections (TEMPERATURE_VALUE / HUMIDITY_VALUE) turn the Breeze into any
  thermostat's outdoor sensor, reporting unavailable rather than stale when the
  sensor goes quiet. The gateway polls the sidekicks tree hash alongside devices
  and routes pushed weather state through the same pipeline as everything else.

- **Bond Color Light** (`bond-color-light.c4z`, 10th driver, OS 3.3.0+): Firefly
  bulbs and strips as full Control4 color lights — dimmer, color wheel, and
  white color-temperature picker on a light_v2 proxy. All colorimetry goes
  through the OS C4:Color\* conversion helpers; the color wheel sends
  hue+saturation and leaves brightness on the slider (Bond's own
  recommendation), CCT targets clamp to the device's real Kelvin range or
  degrade honestly to white on devices without the ColorTemp feature, and white
  at a known temperature reports back in CCT mode so the picker lands on the
  right tab. Devices with SetHSV derive the color child automatically; plain
  lights keep the simpler driver.

### Fixed

- **Atmosphere off-LAN state:** replaced the Agent-pulls-local-relay path with
  direct HTTPS publishing from Atmosphere. CORE 1 hardware on OS 4.2 proved an
  Agent request to a sibling driver's `CreateServer` listener hangs through both
  loopback and the controller's LAN address. The paired, licensed Agent now
  provisions a bearer cryptographically restricted to that controller,
  `SBOS_ATMOSPHERE`, the app-token installation, and a revocable generation;
  Atmosphere never receives the Agent bearer or signing secret. A one-time
  request challenge authenticates the Agent's response, state transitions queue
  behind an in-flight upload, and the cloud path no longer depends on the LAN
  listener binding. The old pull handler remains for deployed drivers, accepts
  only addresses Director reports on the controller itself, and HTTP traces
  redact the frozen `?k=` capability token. The Atmosphere upgrade rotates the
  token the field trace exposed. A new build guard also makes SmartBuildOS
  licensing mandatory for every standalone Control4 driver, with suite children
  explicitly inheriting their licensed parent. Bench builds give every package
  one shared UTC stamp so Composer sees the coordinated upgrade.

## v20260830.122926 - 2026-08-30

### Added

- **Mode Composer: device selection is now discoverable from the Properties
  tab.** A read-only **Devices In Selected Mode** property shows a live count of
  the selected mode's device entries (own + inherited) and, while the mode is
  empty, points at the two setup paths (Capture Current State, or the
  Programming tab's Include Device In Mode command). A **Show Device Setup
  Guide** action prints the full step-by-step to Lua Output, and the dealer
  manual's "Selecting devices" section names both surfaces. Composer offers
  third-party drivers no property-tab device picker, so the property is the
  breadcrumb to where selection actually lives.

## v20260829.222717 - 2026-08-29

### Added

- **SmartBuildOS Mode Composer** (`smartbuildos-mode-composer.c4z`) — a
  state-aware mode engine for Control4: Presence (Home/Away/Vacation) +
  Lifestyle (Movie/Party/Sleep/…) modes with stable ids, single inheritance
  (cycle-refused), Set/Ignore/Restore device behaviors, Capture Current State,
  device groups, transition engine (immediate/graceful/sequenced + departure
  countdown with cancel), per-action delays and criticality, preflight checks,
  keypad BUTTON_LINK slots with a deterministic tap/double/triple/hold gesture
  engine, keypad LED feedback with follow-global-mode and color inheritance,
  multi-signal sensor rules with debounce/cooldown/loop protection, clock
  schedules with presence guards, bounded activation history with "why did this
  happen" detail, dry run + test mode, diagnostic snapshot, atomic JSON
  export/import with a versioned+migratable config envelope, and SmartBuildOS
  licensing (`SBOS_MODE_COMPOSER` — enforcement gates configuration writes only;
  mode activation is operational and never refuses).
- **SmartBuildOS Mode Button** (`smartbuildos-mode-button.c4z`) — Navigator
  Experience button satellite: one instance per mode, icon/name/active state
  pushed by the manager, curated 16-glyph icon library with active/inactive art,
  tap-to-activate with hold-to-confirm double-tap guard, guarded auto-rename.
  Licenses through the manager's entitlement.
- Shared mode-engine library under `src/modes/` (model, store, adapters, plan,
  engine, gesture, led, triggers, history, schedule) — pure,
  dependency-injected, covered by five new test suites (229 checks).
