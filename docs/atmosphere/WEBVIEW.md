# Atmosphere — Navigator WebView App

Atmosphere ships its **own** WebView experience (a deliberate decision — it does
not reuse the SmartBuildOS/insights webview). This document is the mechanism and
the driver↔page contract.

**Status honesty:** the driver side of everything below is built and covered by
tests (URL publishing, JS API verbs, the state document). The page itself —
`www/app/` inside the c4z — is **not yet in the repo**; `driver.xml` already
points at its final URL. Screens, animation tiers, and themes below are the
contract the settings schema already validates and the page must implement.
Nothing in this document has run on real Navigator hardware yet.

## Mechanism: uibutton proxy + web_view_url

- The driver's primary proxy is a `uibutton` (proxy binding **5001**) — the
  Navigator tile.

- `driver.xml` declares:

  ```xml
  <web_view_url proxybindingid="5001">
    controller://driver/smartbuildos-atmosphere/app/index.html
  </web_view_url>
  <mobile_web_view_enabled>true</mobile_web_view_enabled>
  ```

  `controller://driver/<name>/` roots at the c4z's `www/` directory, and the
  driver name in the URL MUST equal the c4z filename (`smartbuildos-atmosphere`)
  — the c4z filename is also the update key and is never renamed.

- Serving the page from the c4z is what makes the data plane work: the official
  WebView JavaScript API is available **only to driver-hosted pages**. A cloud
  URL gets nothing. This also removes any need for a driver-side HTTP server —
  no LAN port, no CORS, no secrets in the page.

### The two measured Navigator traps

Both were measured on the insights driver and are honored here:

1. **Runtime URL changes need `URL_CHANGED`.** The driver publishes
   `SendToProxy(5001, "URL_CHANGED", { url = … })`; Navigator will not change
   the URL of an *open* web view.
1. **A notify sent before project start is silently lost.** The driver publishes
   the URL at LateInit *and again 60 seconds later*
   (`STARTUP_NOTIFY_MS = 60000`, the Control4 WebView sample's value) so a
   controller reboot never leaves a blank tile.

## The JS API contract

The page talks to the driver through the official WebView JS API
(`C4.sendCommand`). Four verbs, registered identically on the UIR (Navigator JS
API), RFP (proxy), and EC (Composer) dispatch tables, all returning **JSON
strings**:

| Verb                 | Params                                           | Returns                                                                                                                                                                         |
| -------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ATMOS_GET_STATE`    | —                                                | the full state document (below). Calling it also marks the UI as subscribed, enabling push                                                                                      |
| `ATMOS_SET_SETTINGS` | `SETTINGS` = JSON-encoded partial settings patch | `{"ok":true,"refused":[{path,reason},…]}` — accepted fields applied and persisted, refusals itemized; `{"ok":false,"error":…}` only when `SETTINGS` is absent or not valid JSON |
| `ATMOS_REFRESH`      | —                                                | `{"ok":true}`; kicks observation + forecast + alert fetches                                                                                                                     |
| `ATMOS_SIMULATE`     | `SCENARIO` = scenario name; empty/absent stops   | `{"ok":true}` / `{"ok":true,"stopped":true}` / `{"ok":false,"error":"unknown scenario"}`                                                                                        |

**Push is best-effort, poll is the contract.** After the page has called
`ATMOS_GET_STATE` once, the driver pushes fresh state documents via
`C4:SendDataToUI` (received as `onDataToUi`) on every engine run — but
`C4.SendDataToUI`'s existence is checked at call time because it is unconfirmed
on all OS builds, and whether `C4.sendCommand`'s return value actually reaches
the page (vs. only the `onDataToUi` channel) is a hardware-test-plan item. The
page must render correctly from polling `ATMOS_GET_STATE` alone.

## The state document

Built by `src/atmosphere/uistate.lua` — one shape, one place. The page never
sees raw NWS JSON, tokens, or anything the driver would not print in a log;
nothing in the document is markup. Units are converted driver-side; the `units`
block says what the numbers already are.

```
{
  v: 1, now: epoch,
  mode: "RAIN", severity: "ADVISORY", simulation: false,
  stale: { any, observations, forecast, alerts, api_ok },
  current: {            // null until the first observation
    temp, feels_like, dewpoint, humidity, wind, gust, wind_dir,
    wind_deg, pressure, visibility, cloud_cover, condition,
    station, observed_at        // every field independently nullable
  },
  states: { is_raining, is_freezing, … },        // threshold booleans
  predictions: { rain_expected_1h, freeze_expected_tonight, … },
  hourly: [ up to 48 periods: {start, end, is_day, temp, pop,
            wind_lo, wind_hi, wind_dir, short, flags} ],
  daily:  [ up to 14 periods, same shape + detail ],
  alerts: [ sorted severe-first: {id, event, headline, severity,
            urgency, certainty, level, class, onset, ends, expires,
            area, description, instruction, sender, rank} ],
  alert_count: n,
  solar: { sunrise, sunset, isDaytime, minutesToSunrise, … },
  location: { label, lat, lon, source, radar_station, office,
              time_zone },
  settings: <the full settings document>,
  units: { temperature, wind, pressure, precipitation, distance },
  diagnostics: { api: {per-endpoint health}, office, grid, station,
                 zone, radar_station, time_zone, polling,
                 driver_version, agent },
  license: { status, label, operational }
}
```

## The seven screens

Bottom-navigation single-page app; the settings schema validates
`display.default_screen` against exactly this set:

**NOW** (current conditions + mode animation) · **HOURLY** (48 h) · **FORECAST**
(14 periods) · **RADAR** (see [RADAR.md](RADAR.md)) · **ALERTS** (full CAP
detail: headline, description, instruction) · **DETAILS** (pressure, visibility,
solar, station, diagnostics) · **SETTINGS** (units, thresholds, alert filters,
radar, theme, animation, simulation).

## Animation tiers and themes

- `display.animation`: **OFF / SUBTLE / NORMAL / CINEMATIC** — Canvas-based
  weather animation budget, with automatic fallback: a device-pixel budget plus
  a rAF frame-time probe drops the tier when a T3 can't keep up. WebGL is
  unconfirmed on Navigator hardware and is therefore not a dependency. Actual
  performance per tier on T3/T4 is a hardware-test-plan item.
- `display.theme`: **AUTOMATIC / LIGHT / DARK / OLED / CONTROL4 / AMBIENT**.

The page is fully self-contained: no CDN, no webfonts, no external scripts or
styles — everything ships in the c4z. Baseline is ES2015/flexbox for the Gecko
96 engine that OS 3.2.0 pins.

## Certification reality (Snap One)

Snap One states there is **no Control4 certification path for WebView Experience
drivers** and reserves the right not to list them. Consequences, recorded up
front:

- Atmosphere distributes through the **SmartBuildOS driver store** (our own
  channel), not the Control4 driver database.
- The driver is fully functional without the WebView: variables, events,
  conditionals, and value connections are the automation product; the app is the
  display product.
