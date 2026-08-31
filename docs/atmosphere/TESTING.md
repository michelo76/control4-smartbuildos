# Atmosphere — Testing

Four suites, 331 checks, all green as of 2026-08-31. And a hard line: the suites
prove the logic; only hardware proves the product. The hardware-only items are
listed at the bottom and mirror the repo's `docs/TEST_PLAN.md` discipline.

## Running the suites

From the repo root:

```
make test                # runs every test/test_*.lua under the C4 shim
```

Or one suite directly (note: run from the **repo root** — the driver integration
suite loads `drivers/smartbuildos-atmosphere/driver.lua` by relative path):

```
LUA_PATH="$(pwd)/test/?.lua;$(pwd)/src/?.lua;$(pwd)/src/?/init.lua;$(pwd)/vendor/?.lua;$(pwd)/vendor/?/init.lua;;" \
  luajit -e "require('c4_shim')" test/test_atmosphere_driver.lua
```

Repo style throughout: plain `check()` assertions, `test/c4_shim.lua` preloaded,
exit 1 on any failure.

## The four suites

### `test_atmosphere_core.lua` — 94 checks

The pure data layer: units, intervals, normalize, solar. Proves:

- nil in, nil out everywhere — a missing reading never becomes 0.
- ISO8601 parsing is host-timezone-independent (offsets, Z, fractional seconds;
  garbage → nil), durations refuse months, interval expansion is end-exclusive.
- MADIS `qualityControl` X/Q/B values are dropped; V/Z pass.
- The live-measured "six nulls in one healthy observation" payload normalizes
  with no error and no fabricated values (gust and wind chill stay nil).
- Forecast unit traps: bare-F temperature, `temperatureUnit: "C"` honored, degC
  dewpoint objects, `"5 to 10 mph"` wind strings, null PoP stays null, garbage
  periods dropped individually.
- `/points` normalization extracts zone/county ids, radar station; missing grid
  → nil (the outside-NWS-coverage signal).
- Solar math against NOAA-derived expectations: equinox day length ~12 h in DC,
  sunrise/noon/sunset ordering, polar midnight-sun refusal, day/night flag and
  minutes-to-sunrise around local midnight.

### `test_atmosphere_engine.lua` — 105 checks

The intelligence layer: thresholds, predictions, mode/severity, alert lifecycle,
and the engine's transition-only event semantics. Proves:

- Hysteresis: asserts at enter, holds inside the band, clears at exit, both
  polarities; nil readings never change a state; threshold overrides validate
  against bounds with itemized refusals.
- Alert lifecycle (`reconcile`): the same alert polled twice fires zero events;
  an Update supersedes its predecessor via `references[]` silently (updated, not
  new, not canceled); escalation detected on severity/level rise; a **failed
  poll retains alerts** (never "all clear") while clock-based expiry still runs;
  an absent alert on a successful poll cancels; Test-status alerts are never
  admitted; sensitivity modes and class filters admit/deny correctly with
  unknown classes fail-open.
- Predictions: 1/3/6-hour rain windows, freeze-tonight, wind lookahead; **a
  stale forecast disables forecast-driven predictions** (fabrication guard)
  while alert-driven intelligence still works.
- Mode precedence (thunderstorm beats rain, freezing rain → ICE, hurricane
  warning forces the mode) and severity ranking (Extreme warning → EMERGENCY).
- Engine transitions: first sight is baseline (rain at step one fires nothing),
  no repeats on steady state, no bounce inside the hysteresis band,
  data-stale/restored and API-down/recovered pairs, automation-off silences
  weather events but **not** data-health events, simulation start/end plus a
  simulated storm firing the real Thunderstorm Started.
- Event-table sanity: 58 unique ids and names.

### `test_atmosphere_settings.lua` — 61 checks

Settings, the UI payload builder, the scheduler, the simulator. Proves:

- Field-by-field validation: one bad field never discards nine good ones; every
  refusal carries path + reason; unknown keys/classes/units/themes refused;
  non-table patches refused whole.
- `load()`: nil/garbage → complete defaults; stored values restored, gaps
  filled; a version-99 "document from the future" keeps known fields and drops
  unknown ones.
- `uistate`: driver-side unit conversion (C, km/h, hPa, km), gust stays nil,
  alerts sorted severe-first, the `units` block describes the numbers.
- Scheduler: healthy cadences (300 s obs / 60 s alerts), ladder
  60→120→300→600→900 clamped at the top, alerts never faster than 60 s under
  backoff, jitter deterministic per seed and inside its spread.
- Every advertised simulation scenario builds; the simulated tornado is a real
  normalized `TORNADO`/`WARNING` alert with SIMULATED in its text; unknown
  scenarios are nil.

### `test_atmosphere_driver.lua` — 71 checks

Integration: loads the real `driver.lua` under the C4 shim with a fake
`lib.http` and drives the full startup chain — LateInit → project-location parse
→ `/points` discovery → station selection → observation → forecast → alerts →
engine → every published surface. Proves:

- Startup: Online, version painted, points hit with 4-decimal coordinates,
  **User-Agent identifies the product**, office/station/location properties
  painted.
- Variables: temperature (86.0 from 30 °C), feels-like from heat index, wind
  converted from km/h, **gust stays empty (never 0)**, forecast high/low, alert
  count/severity/name, LEGACY license without an Agent, sunrise set.
- Events + conditionals: the fixture's Severe Thunderstorm Warning fires the
  specific and generic events; no Rain Started on baseline.
- Connections: `VALUE_CHANGED` on bindings 100/101 with correct payloads; the
  WebView URL published on binding 5001.
- The WebView JSON contract: `ATMOS_GET_STATE` returns a decodable document with
  current/alerts/hourly (≤48)/daily/settings/license and no token/secret
  strings; settings patches apply, persist, and convert the UI's units; bad
  patches are refused with reasons and not applied.
- Simulation parity: `tornado_warning` fires the real event; property, variable,
  conditional, and UI all flag simulation; stop restores the real alert.
- Failure honesty: a failed observation poll keeps the last temperature and
  fires no weather events; a failed alert poll keeps the active alert and does
  not fire Alert Cleared.

## Fixtures approach

Fixtures are synthetic payloads written **inline in the suites**, modeled
field-for-field on live-verified shapes captured from `api.weather.gov` on
2026-08-31: the six-null observation, the mixed-unit forecast period, the
empty-name hourly period, the CAP alert with `references[]`. Synthetic rather
than recorded so each test controls its clock and ids, but never invented: every
quirk a fixture encodes was first measured live. (The architecture doc planned a
`test/fixtures/atmosphere/` directory of recorded sets; the inline approach
superseded it for V1.)

## Hardware test plan — what only hardware can prove

Zero hardware passes have happened. These items cannot be proven by the shim and
stay open until a physical controller + Navigator pass:

1. **WebView JS API reply channel** — does `C4.sendCommand`'s return value reach
   the page, or only the `onDataToUi` push? The page must be built to work
   either way; measure which actually functions.
1. **`C4:SendDataToUI` existence** across the supported OS builds (the driver
   existence-checks it at call time).
1. **External radar image loading in Navigator** — can the webview load
   `radar.weather.gov` GIFs? If not, activate the controller relay fallback
   ([RADAR.md](RADAR.md)).
1. **Animation performance tiers on T3/T4** — verify the auto-fallback probe
   drops CINEMATIC/NORMAL appropriately on real hardware.
1. **VALUE connection binding to a thermostat** — bind Outdoor
   Temperature/Humidity to a real thermostat and confirm it consumes the values
   and the stale `VALUE_UNAVAILABLE` behavior.
1. **Director project-location XML shape** — the `GetProjectItems` parsing is
   tolerant, but the real Director XML must be captured and confirmed (the
   vendored GetLocationInfo has a known pattern quirk that silently yields nil
   on shape drift).
1. **Variables added in OnDriverInit survive a Director restart** with
   programming attached (the official guidance the add-order rule is built on).

Plus the standing field checklist: verify the 60 s startup re-publish recovers
the tile after a controller reboot, and confirm the Composer event-cache quirk
(restart Composer after a driver update) on this driver's 58-event list.
