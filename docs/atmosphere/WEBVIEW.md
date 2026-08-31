# Atmosphere — Navigator WebView App

Atmosphere ships its **own** WebView experience (a deliberate decision — it does
not reuse the SmartBuildOS/insights webview). This document is the mechanism and
the driver↔page contract.

**Status honesty:** the page (`www/app/index.html` inside the c4z, currently
build `b7`) is built and has had its first field passes: rendering verified on a
Control4 touchscreen and in the C4 mobile app on iPhone, with the LAN relay
serving live data on the phone. The touchscreen (T4) relay path is pending user
confirmation — the panel had cached the pre-relay page (see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md)). The cloud-mirror channel has not yet
been exercised end-to-end on hardware.

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

### The two measured Navigator traps

Both were measured on the insights driver and are honored here:

1. **Runtime URL changes need `URL_CHANGED`.** The driver publishes
   `SendToProxy(5001, "URL_CHANGED", { url = … })`; Navigator will not change
   the URL of an *open* web view.
1. **A notify sent before project start is silently lost.** The driver publishes
   the URL at LateInit *and again 60 seconds later*
   (`STARTUP_NOTIFY_MS = 60000`, the Control4 WebView sample's value) so a
   controller reboot never leaves a blank tile.

## The three data channels

The original design assumed the official WebView JS API would be the sole data
plane ("no LAN port, no CORS"). **The first hardware pass overturned that**
(field finding, 2026-08-31): on a real Navigator the page renders and the driver
is fully healthy, but the JS API reply channel delivers *nothing* — the app
starves. The page therefore runs three channels in strict priority order,
falling down and climbing back on its own:

1. **Navigator JS API** (`C4.sendCommand` / `onDataToUi`) — kept first because
   it is zero-config and may work on some OS builds, but it has delivered
   nothing on every Navigator measured so far. If it stays silent for 4 s after
   load, the page probes downward.

1. **LAN state relay** — the driver listens on controller port **47815**
   (`C4:CreateServer`); the page fetches plain LAN HTTP. This is the
   Protect-proven snapshot-relay pattern and is the working data plane on real
   Navigators today. Routes (`src/atmosphere/uirelay.lua`, pure and tested):

   | Route          | Method | Auth  | Does                                     |
   | -------------- | ------ | ----- | ---------------------------------------- |
   | `/ping`        | GET    | none  | reachability probe, leaks nothing        |
   | `/state?k=`    | GET    | token | full UI state JSON                       |
   | `/settings?k=` | POST   | token | settings patch through the one validator |
   | `/refresh?k=`  | POST   | token | kick all weather fetches                 |
   | `/simulate?k=` | POST   | token | start/stop a scenario                    |

   Request parsing is chunk-safe (accumulating buffer, 64 KB cap), CORS
   preflights are answered (measured against a stub relay — the page's
   cross-origin JSON POSTs trigger `OPTIONS`), and writes flow through the same
   validator as every other settings path. Two consecutive relay failures fall
   through to the cloud mirror; three mark the channel dead.

1. **SmartBuildOS cloud mirror** — read-only, for off-LAN use (cellular). The
   page GETs the mirrored state from the platform's public capability URL on a
   60 s cadence (the mirror itself updates ~60 s upstream). Every 5 minutes it
   tries to climb back to the richer channels. See
   [SMARTBUILDOS_INTEGRATION.md](SMARTBUILDOS_INTEGRATION.md) for the mirror
   pipeline. *Not yet field-verified end-to-end.*

### The URL query contract

The relay/cloud pointers ride the `web_view_url` query string — the one channel
that provably reaches the page:

```
controller://driver/smartbuildos-atmosphere/app/index.html
  ?relay=http://<controller-ip>:47815    LAN relay endpoint
  &cloud=https://…/api/public/atmosphere/state   off-LAN mirror
  &cid=SBOS-XXXXXX                       mirror support-id handle
  &k=<token>                             one token authorizes both
```

The page reads `location.search`; with no params it stays on the JS API alone.
The parsed values live in memory only — never persisted — and the token is
scrubbed from every console line the page logs. The driver re-publishes the URL
whenever the relay host or cloud pointer changes (URL self-heals when the
controller address becomes discoverable late).

The relay host comes from the **App Relay Address** property (`Auto` = deep-walk
discovery of Director's bindings answers, which vary by project; a manual IP is
the escape hatch), and the read-only **App Data Relay** property reports the
data plane's health without the Lua window.

### Read-only cloud mode

While the cloud mirror is the live channel the page is honest about its powers:
a READ-ONLY banner ("control available on the home network"), every Settings
control disabled, and all writes dropped client-side — the mirror endpoint has
no write path anyway.

### The self-diagnosing waiting screen

Until the first state document arrives, the NOW screen shows "Waiting for
weather data…" plus a live one-line channel status ("Trying Navigator API…" /
"Trying LAN relay (host)…" / "LAN relay unreachable (attempt n)" / "No relay
address received from driver" / "Trying SmartBuildOS cloud…"), suffixed with the
`APP_BUILD` marker (`b7`). One screenshot of a failing panel now diagnoses both
the data plane and whether the panel is running a stale cached page. The same
line appears in the DETAILS diagnostics ("Data channel · Source").

## The JS API contract

The page talks to the driver through the official WebView JS API
(`C4.sendCommand`). Four verbs, registered identically on the UIR (Navigator JS
API), RFP (proxy), and EC (Composer) dispatch tables, all returning **JSON
strings** — and mirrored 1:1 by the relay routes above:

| Verb                 | Params                                           | Returns                                                                                                                                                                         |
| -------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ATMOS_GET_STATE`    | —                                                | the full state document (below). Calling it also marks the UI as subscribed, enabling push                                                                                      |
| `ATMOS_SET_SETTINGS` | `SETTINGS` = JSON-encoded partial settings patch | `{"ok":true,"refused":[{path,reason},…]}` — accepted fields applied and persisted, refusals itemized; `{"ok":false,"error":…}` only when `SETTINGS` is absent or not valid JSON |
| `ATMOS_REFRESH`      | —                                                | `{"ok":true}`; kicks observation + forecast + alert fetches                                                                                                                     |
| `ATMOS_SIMULATE`     | `SCENARIO` = scenario name; empty/absent stops   | `{"ok":true}` / `{"ok":true,"stopped":true}` / `{"ok":false,"error":"unknown scenario"}`                                                                                        |

**Push is best-effort, poll is the contract.** After the page has called
`ATMOS_GET_STATE` once, the driver pushes fresh state documents via
`C4:SendDataToUI` (received as `onDataToUi`) on every engine run — but the push
path's existence is checked at call time, and the field finding above means the
page must (and does) render correctly from polling alone, on whichever channel
is alive.

## The state document

Built by `src/atmosphere/uistate.lua` — one shape, one place, served identically
on all three channels. The page never sees raw NWS JSON, tokens, or anything the
driver would not print in a log; nothing in the document is markup. Units are
converted driver-side; the `units` block says what the numbers already are.

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
  solar: { sunrise, sunset, isDaytime, minutesToSunrise, …,
           moon: { phase, name, illumination } },
  history: [ up to 48 downsampled observation samples
             { t, tempF, pressureInHg } for sparklines ],
  trends: { pressure: "RISING"|"FALLING"|"STEADY" },  // absent = no data
  location: { label, lat, lon, source, radar_station, office,
              time_zone },
  settings: <the full settings document>,
  units: { temperature, wind, pressure, precipitation, distance },
  diagnostics: { api: {per-endpoint health incl. grid}, office, grid,
                 station, zone, radar_station, time_zone, polling,
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

### Interactive radar

The RADAR screen now defaults to a tier-2 interactive view: stacked `<img>`
layers over one shared EPSG:4326 bbox (reference boundaries → MRMS radar frames
→ WWA warning polygons → NHC tropical cone/track when a storm's cone intersects
the view), with City/County/State/Region span presets, drag-to-pan, Home
recenter, and play/pause animation over real catalog-enumerated frame times. It
auto-falls back to the Classic RIDGE2 view when the NOAA map services misbehave,
with a manual retry. Full mechanism, endpoint math, and the honest limits live
in [RADAR.md](RADAR.md).

### Mobile pill nav and the safe-area finding

The Control4 mobile app overlays its **own** persistent bottom bar over the
WebView (field report, iPhone). On phone-width viewports (≤ 520 px) the app's
nav therefore floats as a rounded pill above the host chrome; wide viewports
(T3/T4 panels) keep the field-verified full-width bar. The measured subtlety:
the C4 mobile webview reports `env(safe-area-inset-bottom)` **already
including** the host app's bottom bar (~78 px) — a naive `inset + 84px` doubled
the clearance. The pill sits at `safe-area-inset-bottom + 10px`, right on top of
the C4 buttons (field-verified).

## Animation tiers and themes

- `display.animation`: **OFF / SUBTLE / NORMAL / CINEMATIC** — Canvas-based
  weather animation budget, with automatic fallback: a device-pixel budget plus
  a rAF frame-time probe drops the tier when a T3 can't keep up. WebGL is
  unconfirmed on Navigator hardware and is therefore not a dependency. Actual
  performance per tier on T3/T4 is a hardware-test-plan item.
- `display.theme`: **AUTOMATIC / LIGHT / DARK / OLED / CONTROL4 / AMBIENT**.

The page is self-contained: no CDN, no webfonts, no external scripts or styles —
everything ships in the c4z. Its only external fetches are NWS/NOAA radar
imagery and metadata (`radar.weather.gov`, `mapservices.weather.noaa.gov`) and
its own driver relay / cloud mirror. Baseline is ES2015/flexbox for the Gecko 96
engine that OS 3.2.0 pins.

## Certification reality (Snap One)

Snap One states there is **no Control4 certification path for WebView Experience
drivers** and reserves the right not to list them. Consequences, recorded up
front:

- Atmosphere distributes through the **SmartBuildOS driver store** (our own
  channel), not the Control4 driver database.
- The driver is fully functional without the WebView: variables, events,
  conditionals, and value connections are the automation product; the app is the
  display product.
