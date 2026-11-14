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
- **VenueFlow (`smartbuildos-venueflow`, SKU `SBOS_VENUEFLOW`): a commercial
  AV control surface on an existing Control4 project.** Four operator
  screens on one UI Button tile (Visual Floor Plan, Command Center,
  Simplified Room Control, Manager Overview) and Installer Studio, served on
  the venue LAN from the driver's relay: setup wizard, device discovery and
  mapping with test actions, a drag-and-drop layout designer, a visual
  programming editor for scenes, rules and schedules with dry run, staff
  profiles enforced by the driver, diagnostics, backup, publish and rollback.
  A capability-aware routing engine reports one outcome per display and never
  reports a dispatched command as done; audio zones are independent of video;
  the driver starts in Simulation and sends nothing to Control4 until set to
  Live. **Simulation verified only.** On a bench controller it installs,
  serves its pages, publishes and survives a driver restart, all in
  Simulation; it has not yet controlled real equipment
  (`docs/smartbuildos-venueflow/HARDWARE_VALIDATION.md`). `make venueflow`
  builds just this driver and does not copy it into Composer's folder.
- **A full manual for every driver.** The other 40 drivers now have the
  same kind of manual as the Notification Router and Solar Position: what
  the driver is for and a table of use cases, where the stock way is still
  the right tool, setup as a walkthrough, how it behaves, worked examples
  that name the exact event, conditional, variable or command, a programming
  reference, how to read the status, and what is not claimed. Each was
  written from the driver's code and tests, not from the old page, and every
  name was checked against `driver.xml`. Where the code and the old manual
  disagreed the manual now follows the code (the camera's snapshots and PTZ,
  the Agent as an agent and not a project driver, commands by their real
  names, limits and defaults), and behaviour that surprised us is written
  down as it is, under the section it affects.
- **Solar Position: a ceiling per facade.** `Facade N Max Elevation` (90 =
  no limit) is the highest sun that still counts, for glass under an
  overhang or a balcony and for the midsummer sun that stands in front of
  south glass without entering it. Facade Status says `shade (sun too
  high)` when that is the reason, a ceiling at or under the floor is
  reported (`facade 2 not used: …`) instead of leaving a facade that can
  never light, and a facade with a ceiling can be in the sun twice a day,
  with two pairs of events.
- **Solar Position: an event at every boundary of the day.** *Sunrise*,
  *Sunset*, *Night Began* (evening twilight over), *Evening Golden Hour
  Started* and *Morning Golden Hour Ended* join *Civil Dawn*, so first
  light, sunrise, full daylight, low evening sun, sunset and dark each have
  one event, plus the conditional *It is night*. *Golden Hour Started* and
  *Civil Dusk* keep firing as before for programming that uses them. The
  horizon is judged on its own, so a late tick still reports the crossing.
- **Solar Position: the manual.** Why a sunrise or sunset schedule cannot do
  this (the driver's own figures for a west and a south facade through the
  year), a table of use cases, walkthroughs for setup and for describing a
  facade, how to choose Max Elevation for an overhang, four worked examples,
  the day boundary by boundary, and a calculator in the page that answers
  "when is the sun on this glass" for any site, date and facade with the
  driver's own rules (checked against the engine on fourteen cases).
- **Interactive manuals for every driver.** A driver's documentation is now
  one self-contained interactive page: a contents list that follows the
  page, search, walkthroughs whose steps you tick (your place is kept),
  screenshots that enlarge, and copy buttons on code. `tools/docs.py`
  builds it from the same `index.md` for all 42 drivers, embeds the
  screenshots in the page, and falls back to the plain document where
  script does not run (the PDF). The ten dealer-tooling drivers carry
  screenshots taken on the bench and a setup walkthrough; the Notification
  Router's manual adds Telegram, message and two-way walkthroughs and a
  try-it panel for composing a message. It opens with what the driver is
  for and a table of use cases, and has a Webhooks section with walkthroughs
  and worked examples for a Slack or Discord channel and for the Generic
  Webhook (the request as sent, each field, what to answer, a `curl` line).
- **Notification Router: a message is written in pieces.** Notify, Notify
  All and Reply now read MESSAGE, VARIABLE 1, MESSAGE 2, VARIABLE 2 … up to
  VARIABLE 4 and MESSAGE 5, so words can follow a value: *This system
  rebooted* + a variable + *times* is sent as "This system rebooted 3
  times". Pieces are joined with one space, tight against punctuation.
  Programming written before sends what it sent; `${1}`..`${4}` still place
  a value anywhere and word or round it.
- **Notification Router: SEPARATOR.** Notify, Notify All and Reply have a
  SEPARATOR list just above MESSAGE: what goes between one message (a text
  and the variable under it) and the next. **Space** (default) keeps
  everything one sentence, as before; **New Line** puts each message on its
  own line; **Period**, **Comma**, **Semicolon**, **Dash** and **Vertical
  Bar** are the others. Asked for after "Home is currently Occupied The
  security is currently Armed Away" arrived run together. Programming
  written before sends what it sent.
- **Notification Router: `MESSAGE_RECEIVED`.** A string variable that takes
  the text of each message the router accepts, for programming written as
  *when MESSAGE_RECEIVED changes, if it is equal to …*. It is not
  read-only, so programming can set or clear it. The same text arriving
  twice is still a change. **Message Received As** can lower-case it so a
  phone's capital letter does not break a condition.
- **Notification Router: Find Telegram Chat ID.** An action that lists the
  chats the bot has heard from, with their ids, in **Telegram Chats Seen**:
  people who wrote to it, groups and channels it was added to. It takes
  nothing, and the token no longer has to be pasted into a browser.
- **Message variables in the Notification Router.** A notification can
  carry the current value of any Control4 variable, value only, set up in
  the programming window the way the Push Notification agent does it.
  Notify and Notify All have four **VARIABLE** parameters that open
  Composer's own *Select variable…* tree; `${1}`..`${4}` in the TITLE or
  MESSAGE stand for them, and a picked variable that is not written into
  the text is added at the end. `${Room->Device::VARIABLE}` written out
  works too. `${1|Open|Closed}` words an on/off value, `${2|.1}` rounds a
  number. A variable that cannot be read is sent as `?`, raises *Message
  Variable Missing* and never blocks the send; a credential-named variable
  is sent as `[hidden]`. De-duplication compares the filled-in text.
- **Two-way messaging in the Notification Router.** With **Telegram
  Inbound** or **Twilio Inbound** on, a message sent to the bot or a text
  sent to the Twilio number becomes variables (`LAST_MESSAGE`,
  `TELEGRAM_LAST_MESSAGE`, `SMS_LAST_MESSAGE`, sender, channel, a counter)
  and events (*Message Received*, per channel, *Message Rejected*). Eight
  **Keyword** properties each have their own event, with the rest of the
  message as an argument, and a **Reply** command answers the sender with
  message variables. Only the chat or number the router already sends to is
  taken unless more are listed; messages older than two minutes are
  ignored, each is handled once across restarts, and an optional **Inbound
  PIN** is required and stripped. The router polls (default every 5 s);
  nothing has to be opened on the home router. Not yet exercised with a
  real message on a controller.
- **driver.xml guard**: a `DEVICE_SELECTOR` property with no `<items>`
  filter, and a `PASSWORD` property, are refused in every driver (both make
  Composer Pro 2026.10.14 raise "Property Invalid" on import).

### Changed
- **Event Tracer and Flight Recorder are one driver** (`smartbuildos-flight-recorder`,
  SKU `SBOS_FLIGHT_RECORDER`, module `flight_recorder`). The
  `smartbuildos-event-tracer` driver is removed; its capture engine runs
  inside the Flight Recorder, on by default with no configuration. Both
  answered "what happened?", and a dealer had to add, license and read two
  drivers to get the events and the values side by side.
  - **One local history.** Device events, variable changes, trace steps,
    markers and the recorder's own notes are kept in one list in the order
    they happened (*Print Recent History*; the list survives a restart).
  - ***Print Last Trace*** prints everything between the start and the end
    of the last routine trace: its own steps, and what the house did in
    between.
  - ***Print History For Inspect Device*** shows one device's events,
    changes and trace steps, its event coverage and its watched variables.
  - **Snapshots carry the history** (newest 200 entries), the state of
    event capture and any active storm.
  - **One pause, one licence rule.** `PAUSE_RECORDING` and
    `RESUME_RECORDING` release and restore event subscriptions and variable
    listeners together; a definitive licence denial with enforcement on
    stops both (before, the recorder reported `unlicensed` and kept
    listening).
  - **Names.** `MARK_TIMELINE` is gone: `RECORD_EVENT` is the one marker
    command. Capture → **Event Capture**, Coverage → **Event Coverage**,
    Catalogue → **Event Catalogue**, Upload Budget → **Event Upload
    Budget**; **Recording Status** is the one status; new **Last Trace**.
    Events *Event Storm Detected*, *Event Storm Ended* and *Unknown Event
    Learned* are now events 10 to 12 of the Flight Recorder.
  - **Contract.** `capture.` and `tracer.` event types now belong to
    `flight_recorder` (`src/sbos/envelope.lua`), and the Agent's restricted
    commands for it gain `apply_policy` and `reapply`; the `event_tracer`
    module id is retired. **The web repo must follow** (`MODULE_PREFIXES`,
    `MODULE_OPERATIONS`, the Studio Event Tracer pages, the SKU catalogue):
    until it does, SmartBuildOS refuses the device events this driver
    uploads. Not yet run on a controller.
- **Event envelope: reserved prefixes.** A module with no event-type
  prefixes of its own can no longer emit under another module's prefix
  (`event_type_reserved`). The server has refused such events since the
  Flight Recorder review fixes; the Agent now refuses them at the module
  frame, so they are not queued and uploaded first.

### Fixed
- **Sunrise and sunset use the site's day, not the UTC day** (Atmosphere and
  Solar Position, `src/atmosphere/solar.lua`). In a western evening the UTC
  date has already turned, and the driver answered with tomorrow's sun: at
  34°N 118°W in June `IS_DAYTIME` went false at 17:00 against a 20:06
  sunset, `MINUTES_TO_SUNSET` read a day too long and *Sunset Approaching*
  never fired. In an eastern morning it answered with yesterday's, and the
  next sunrise could be in the past. The next sunrise and sunset are now
  searched over the days around today, so they are also right for a driver
  pointed at coordinates far from its controller.
- **Solar Position: `MINUTES_TO_SUNSET` and `MINUTES_TO_SUNRISE` never skip
  a number.** The value is a floor on a 60-second tick, so a few
  milliseconds of drift could take it from 31 straight to 29 and programming
  on "equals 30" would miss that day. The driver now walks the numbers in
  between.
- **Home Guide, Dealer Settings, Variable Inspector: the tile could be
  published at another device's address.** The controller's address was
  taken from the first `control4_*` device with a network binding; on a
  project with a second Control4 device on the network that was the other
  device, and all three tiles pointed where nothing listened. An address
  from a device binding is now only a candidate: the driver asks its own
  relay `GET /ping` on each and publishes the one that answers by name
  (`src/lib/relayhost.lua`). `C4:GetControllerNetworkAddress()` is tried
  first; **App Relay Address** still overrides everything; when nothing
  answers, no address is published and **App Data Relay** says so. Asked
  again every 15 minutes, so a changed lease is followed. Atmosphere and
  UniFi Protect use the older lookup and are not changed here.
- **Every driver: a plain text value saved by the driver was lost at the
  next restart.** Stored values are read back through Base64 and JSON so a
  saved table can be rebuilt; a saved *string* went the same way, and one
  the controller's decoder turns into nothing (anything with a space, comma,
  dot, dash or underscore) came back empty. Seen on the bench in the Agent:
  the company name was painted after a licence refresh and replaced by
  *Registered (name syncing)* after every driver update, so every dependent
  driver showed `-` for the company. The property name the Agent forwards,
  its Support ID, last-reload time and version, and the three Web View relay
  tokens were lost the same way. A stored string that is not an encoded
  table is now returned as stored. Bench-confirmed: the company name is
  shown straight after an update.
- **Every licensed driver: License Status stayed on "SmartBuildOS Agent
  Found - Checking..." after a driver update.** The licence ask sent while a
  driver is still starting got no answer on the bench when the Agent was
  already running, and nothing asked again; one press of *Register With
  Agent Now* painted it at once. An unanswered ask is now repeated after 5,
  15, 30 and 60 seconds and then every five minutes, and stops at the first
  answer. Licensing stayed fail-open throughout: no driver stopped working.
- **Agent: the first real Director reload would have stopped the Agent
  starting.** The reload report to SmartBuildOS named two functions declared
  further down the file, so it threw from `OnDriverLateInit` the first time
  it ran. It had never run: a start was classified as "first" whenever the
  reload count was 0, an update never adds to the count, so an Agent that
  had only been updated read *Last Reload … (first)* for ever and never
  reached "reload". Both are fixed: the count alone no longer decides
  "first", and the report lives below the sender it uses.
- **Event Tracer: the probe could starve the events it already knew.** With
  *Probe Unknown Drivers* on, the subscription budget was spent in device-id
  order, 32 guesses for each unknown device, and catalogued devices with
  higher ids got nothing (bench: `1000 subscriptions on 35 of 186 devices`).
  Known events are now subscribed first and the probe gets what is left.
- **Event Tracer: an event from another day now says which day.** *Last
  Event* and *Print Recent Events* showed the time alone, so a history that
  spans midnight read as out of order.
- **Home Guide: every device was listed twice.** Director lists a driver and
  its proxy as two devices with one name. Entries of one room that share a
  name are now one line; two real devices with the same name and driver are
  one line marked `(2)`. A lamp driver is no longer classed with amplifiers,
  nor an AV switch or a Nintendo Switch with light switches.
- **Home Guide: Last Rebuilt moved every minute.** It was painted with the
  clock, not with the time of the rebuild.
- **Usage Analytics: Last Daily Summary read "none" after every update.**
  The time the summary was sent is now kept across restarts.
- **Notification Router: a notification with only a MESSAGE was sent
  twice over.** Its first 60 characters went out as a title line above the
  full text on Telegram, webhooks and SMS. The text is now sent once.

- Fixed

### Changed
- Changed

### Removed
- Removed
-->

## Unreleased

### Added
- **Message variables in the Notification Router.** A notification's TITLE
  or MESSAGE can carry placeholders that are sent as the current value of a
  Control4 variable, value only: `{1}`..`{8}` for a slot (a device and one
  of its variables picked in the driver's properties, or one of the
  project's custom variables) and `{Device:VARIABLE}` inline. `{1|Open|Closed}`
  words an on/off value, `{2|.1}` rounds a number. A placeholder that cannot
  be filled is sent as `?`, raises *Message Variable Missing* and never
  blocks the send; a credential-named variable is sent as `[hidden]`.
  De-duplication compares the filled-in text. A slot's device is picked
  from a list the driver fills (`Name (Room) · id`): a `DEVICE_SELECTOR`
  property with no driver filter makes Composer Pro 2026.10.14 raise
  "Property Invalid" on import, and the driver.xml guard test now refuses it.

### Fixed
- **Dealer PIN property type** (Dealer Settings Panel, Live Variable Inspector): `<type>PASSWORD</type>` made Composer Pro 2026.10.14 raise "Property Invalid … Object reference not set to an instance of an object" when the driver was added; it is now `<type>STRING</type><password>true</password>`, the form every other password property in this repo uses. Measured on Beta Site 2, 9 Nov 2026.

- **Agent discovery for every dependent driver.** Since the Agent moved to
  Composer's Agents panel (`<agent>true</agent>`, PR #31) it is no longer in
  `C4:GetDevices`, so every SmartBuildOS driver read "No SmartBuildOS Agent
  Found" while the Agent sat paired and connected (measured on Beta Site 2,
  OS 4.3, 2026-11-09). `sbos.license` now finds the Agent in three tiers —
  project devices, `C4:GetDevicesByC4iName("smartbuildos.c4z")`, then the
  `GetProjectItems("AGENTS")` list (last `<id>` before the Agent's `<c4i>`)
  — and `sbos.mirror`, System Link and Atmosphere delegate to it instead of
  carrying their own copy of the old rule.
- **Composer listing of proxy-less drivers.** Flight Recorder and Event
  Tracer declare `<combo>true</combo>`; without it Composer imports a
  proxy-less `lua_gen` driver and never lists it in Items → Search.

### Added
- **Studio operations for the Event Tracer and Usage Analytics** (Agent `MODULE_COMMANDS`): `event_tracer` (apply_policy, pause, resume, reapply, refresh_status) and `usage_analytics` (send_summary, reapply, refresh_status), mirroring the web repo's `MODULE_OPERATIONS`. An older Agent refuses them by name.
- **Event Tracer: a Studio policy is written into the Composer properties.** `apply_policy` merges the keys sent over the running policy, refuses the whole change if any value is invalid, updates the properties and applies; it survives a reload and a later Composer edit wins. `tracer.applied` now reports the running policy (`payload.policy`) for Studio.

- **Dealer tooling batch** (new, 8 drivers, `docs/driver-batch-20261109.md`),
  every one licensed through the Agent by its own SKU: **Home Guide**
  (`smartbuildos-user-manual`, SBOS_USER_MANUAL) — a personalised manual
  generated from the project in a Navigator web view; **Guest Mode**
  (`smartbuildos-guest-mode`, SBOS_GUEST_MODE) — iCal short-let calendars →
  stay states, events, per-stay PIN variable; **Usage Analytics**
  (`smartbuildos-usage-analytics`, SBOS_USAGE_ANALYTICS, module
  `usage_analytics`, prefix `usage.`) — media hours, light on-hours, keypad
  presses, daily rollups uploaded through the Agent; **Notification Router**
  (`smartbuildos-notification-router`, SBOS_NOTIFICATION_ROUTER) — Telegram,
  Pushover, Slack/Discord webhook, generic webhook, Twilio SMS with quiet
  hours, dedupe, rate limits, retries; **Logic Pack**
  (`smartbuildos-logic-pack`, SBOS_LOGIC_PACK) — counters, flags, state
  machine, debounce, throttle, once-per-day, named timers for Composer
  programming; **Solar Position** (`smartbuildos-solar`, SBOS_SOLAR) — NOAA
  sun elevation/azimuth, day phases, four facades with hysteresis; **Dealer
  Settings** (`smartbuildos-dealer-panel`, SBOS_DEALER_PANEL) — twelve
  dealer-defined settings as variables, editable from a PIN-gated web view;
  **Variable Inspector** (`smartbuildos-variable-inspector`,
  SBOS_VARIABLE_INSPECTOR) — live device variables, watch list with history,
  PIN-gated Set. Web views follow Atmosphere's relay pattern (ports
  47821–47823). 1,018 new test checks; **no hardware validation yet**.
- **Build guard** `test/test_driver_require_guard.lua`: every src `require`
  in a driver.lua must be at module scope, or the squish step leaves the
  module out of the .c4z (the tracer shipped without its catalogue this way).

- **Event Tracer** (new): `smartbuildos-event-tracer` captures every Composer
  event every device in the project fires, with no configuration, and keeps
  the sequence in a local ring (printable from Composer without a Pro session)
  and as `capture.event` envelopes through the Agent's pipeline. Event ids come
  from a three-tier catalogue — the project XML (bench PROBE), a built-in table
  generated from the dealer's driver library (`tools/gen-event-catalog.py`:
  187 drivers, 1,303 events), and ids learned at run time from opt-in probe
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
