# Atmosphere — Changelog

Release versions follow the repo's timestamp scheme once packaged; this
changelog tracks the product. Event and variable IDs are frozen at first ship.

## 0.2.0 (2026-08-31)

The first-hardware round: the Navigator app shipped and everything below came
out of the first field passes (Control4 touchscreen + C4 mobile app on iPhone)
plus one intelligence sprint. App build `b7`.

### Navigator app + always-on automation

- The WebView app itself (single self-contained file, closing 0.1.0's biggest
  gap): NOW, HOURLY with SVG temperature curve, FORECAST, RADAR, ALERTS,
  DETAILS, multi-pane SETTINGS; Canvas 2D animated backgrounds with tiered
  auto-fallback; six themes; strict CSP with all external text as text nodes;
  mock mode; guard test pinning the security budget.
- Per user direction, the weather-automation toggle is **removed product-wide**
  — events always fire; the retired settings key is accepted-and-ignored so
  older stored documents never warn.

### App data plane (the big field finding)

- **The Navigator JS API delivers nothing on real Navigators** — the page
  renders, the driver is healthy, the app starves. Fixed with the Protect-proven
  relay pattern: the driver serves token-guarded JSON on controller port 47815
  (`/ping` `/state` `/settings` `/refresh` `/simulate`; chunk-safe parsing, CORS
  preflight answered, writes through the one validator). The relay address +
  minted token ride the `web_view_url` query — the one channel that provably
  reaches the page.
- **Relay-host discovery survives Director's shape drift**: bindings answers are
  deep-walked across BOTH `GetNetworkBindingsByDevice` and `GetBindingsByDevice`
  for the first non-loopback IPv4; new **App Relay Address** property (manual
  override) and **App Data Relay** status property; relay lines in Print
  Diagnostics with the token always redacted.
- **SmartBuildOS cloud mirror (channel 3, read-only, off-LAN)**: the driver asks
  the Agent, the Agent fetches state from the relay on localhost and POSTs it
  bearer-authed to the platform; the app reads the public capability URL
  (`cloud=` + `cid=` in the app URL). Token hashed at rest (SHA-256,
  constant-time compare, uniform 404s), capability dies with pairing revocation,
  mirrors older than 24 h refused. Transitions push immediately; steady state
  throttles to 60 s at both hops. The app treats the mirror as strictly
  read-only and climbs back to richer channels every 5 minutes.
- The waiting screen self-diagnoses: live channel-status line (Navigator API /
  LAN relay / cloud / no relay address) suffixed with the `APP_BUILD` marker, so
  one screenshot identifies both the data plane and a stale cached page.

### Interactive radar (tier 2, was "the V2 path")

- Stacked `<img>` composition over one shared aspect-correct EPSG:4326 bbox:
  reference boundaries → base-reflectivity frames → WWA warning polygons
  (filtered to warnings + watches) → NHC tropical cone/track overlays.
- Frame times enumerated from the mosaic catalog (`idp_validtime`) — never
  wall-clock, which yields blank PNGs. City/County/State/Region presets,
  drag-to-pan + Home, play/pause animation, warning refresh every 2 minutes.
- Per-view polygon-accurate tropical detection: the 15 NHC storm slots (AT/EP/CP
  1–5, fixed layer-id arithmetic) probed with envelope-intersect count queries,
  cached per bbox for 30 minutes.
- Auto-fallback to the Classic RIDGE2 view (kept as the manual mode) on catalog
  failure or repeated imagery errors; webview guard test pins the allowed
  imagery hosts.

### Grid intelligence, trends, moon, recommendations

- NWS gridpoint layers fetched on the forecast cadence (grid-only failures never
  poison core forecast freshness): duration-weighted accumulation math gives
  `SNOWFALL_NEXT_24H_IN`, `RAIN_TOTAL_NEXT_24H_IN`, `THUNDER_PROBABILITY_12H` —
  blank means no data, never zero.
- Observation ring buffer (24 h / 300 samples) feeding `PRESSURE_TREND` (3-h
  barometer read; nil under 2 samples or 90 min span) and app sparklines;
  `MOON_PHASE` from mean-cycle math rides the solar block.
- Six new events (ids 59–64, append-only): Sunset/Sunrise Approaching, Barometer
  Falling Rapidly, Irrigation Skip Recommended/Cleared, Shade Protection
  Recommended — all through the same transition gate, with curated
  recommendation logic (`recommend.lua`) and matching
  `IRRIGATION_SKIP_RECOMMENDED` / `SHADE_PROTECT_RECOMMENDED` variables. Totals
  now 64 events / 50 variables (the 0.1.0 notes said 44 variables; the true
  pre-existing count was 43).

### Mobile fixes (field-verified on iPhone)

- Phone-width viewports float the nav as a pill clear of the C4 mobile app's own
  bottom bar; the measured trap: the C4 webview's `env(safe-area-inset-bottom)`
  already *includes* the host bar, so the pill sits at inset + 10 px (the first
  fix doubled the clearance).

### Still unverified at 0.2.0

- Cloud mirror end-to-end (no production controller has mirrored state and had
  the app read it back).
- T4/touchscreen relay path (panel had cached the pre-relay page; awaiting
  re-open/reboot confirmation).
- Interactive radar on T3/T4 panels.

## 0.1.0 (2026-08-31)

Initial build. Everything below is new; nothing has run on hardware yet (see
TESTING.md for the hardware test plan).

### Weather engine (`src/atmosphere/`)

- `api.weather.gov` client: points discovery (4-decimal coordinates),
  station-list walk with stale-station fallback, latest observations, daily +
  hourly forecasts, zone-preferred active alerts, gridpoint layers (client only;
  unpolled in V1). Identifying User-Agent; reserved `X-Api-Key` slot for NWS's
  announced future key scheme.
- Normalization hardened against measured NWS realities: strict-SI observations,
  MADIS QC filtering (drop X/Q/B), per-field null guards (nil never becomes 0),
  bare-F vs degC-object forecast units, human wind strings, METAR cloud layers,
  `presentWeather` precedence, ISO8601 interval expansion with
  host-timezone-independent parsing.
- Intelligence engine: 16 weather modes + 6 severity levels; installer
  thresholds with enter/exit hysteresis; predictive flags from the hourly
  forecast (1/3/6 h rain windows, freeze-tonight, storm/wind/heat lookaheads)
  with a stale-forecast fabrication guard; CAP alert lifecycle (dedupe by id,
  supersede via references, cancel/expire by `ends`/`expires`, escalation
  detection, sensitivity + class admission with Test-status rejection);
  transition-only events with first-sight-is-baseline, persisted across
  restarts.
- NOAA solar math (sunrise/sunset/solar noon/minutes-to, polar-day refusal) —
  DriverWorks has no sunrise getter.
- Polling scheduler: 5 m observations / 15 m forecasts / 60 s alerts / 24 h
  points re-check; failure backoff 1→2→5→10→15 m on any failure; deterministic
  per-controller jitter.
- 16 simulation scenarios (clear → hurricane_warning) running the identical
  engine path, loudly flagged, with auto-timeout.
- Versioned settings store (v1): field-by-field validation with itemized
  refusals, bounds-checked thresholds, deep merge, migration table,
  future-document handling.
- WebView state-document builder: one JSON-able shape with driver-side unit
  conversion; no raw NWS JSON, no markup, no secrets.

### Control4 driver (`drivers/smartbuildos-atmosphere/`)

- 58 programming events (rain/snow/wind/temperature/storm/severity/ generic + 16
  specific alerts/data health/fog/ice/simulation), 44 variables, 9 conditionals,
  13 actions, 3 programming commands.
- Location chain: Control4 Project (default, with re-resolution on Director
  location-change system events 52/53/54) → Manual Coordinates; SmartBuildOS
  property coordinates applicable when paired.
- Provider connections `Outdoor Temperature` (100) / `Outdoor Humidity` (101)
  for thermostat outdoor-sensor binding, with `VALUE_UNAVAILABLE` on stale data.
- Failure model: last-good retention, per-component staleness with always-firing
  data-health events, no fabricated values or events.
- WebView surface: `uibutton` proxy 5001,
  `controller://driver/smartbuildos-atmosphere/app/index.html`, JS API verbs
  `ATMOS_GET_STATE` / `ATMOS_SET_SETTINGS` / `ATMOS_REFRESH` / `ATMOS_SIMULATE`,
  best-effort `SendDataToUI` push, URL re-publish 60 s after startup. (The
  Navigator page itself ships in a later release — the driver-side contract is
  complete.)
- SmartBuildOS licensing client wired for SKU `SBOS_ATMOSPHERE` (observe-mode,
  LEGACY without an Agent, weather path never gated); remote-settings receiver
  `SBOS_ATMOSPHERE_CONFIG` with validation and `SBOS_ATMOSPHERE_CONFIG_ACK`.
- Persisted caches (points, station, settings, snapshot, forecasts, alerts,
  location) so a restart is not amnesia; `Clear Cached Weather` and
  `Reinitialize Weather Services` recovery actions; diagnostics action and
  per-endpoint health tracking.

### Documentation & tests

- In-c4z installer manual (`www/documentation/index.md`); this documentation
  suite (`docs/atmosphere/`); Phase 1 architecture audit with provenance tags
  (`docs/atmosphere-architecture.md`).
- Four test suites, 331 checks: pure core (94), engine (105),
  settings/UI/scheduler/simulator (61), full driver integration under the C4
  shim with a fake transport (71).

### Known gaps at 0.1.0

- Navigator app page (`www/app/`) not yet built.
- Platform-side pieces pending: `driver_catalog` seed, store CI SKU mapping,
  Agent heartbeat `atmosphere` config forwarding, weather-health fleet
  reporting, push notifications.
- Zero hardware verification — the PRD field pass is the next milestone.
