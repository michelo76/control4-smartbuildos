# Atmosphere — Changelog

Release versions follow the repo's timestamp scheme once packaged; this
changelog tracks the product. Event and variable IDs are frozen at first ship.

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
  location)
  so a restart is not amnesia; `Clear Cached Weather` and
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
