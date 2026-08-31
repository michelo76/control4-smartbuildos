# SmartBuildOS Atmosphere — Architecture & Gap Analysis

**Product:** SMARTBUILDOS ATMOSPHERE — Weather Intelligence for Control4
**SKU:** `SBOS_ATMOSPHERE` · **Package:** `smartbuildos-atmosphere.c4z`
**Date:** 2026-08-31 · **Status:** Phase 1 deliverable (audit complete, pre-implementation)

This document records the Phase 1 repository/architecture audit and the decisions
it forces. Every load-bearing claim below is tagged with its provenance:
`VERIFIED_BY_DOCS` (official documentation), `VERIFIED_LIVE` (probed against the
live API on 2026-08-31), `VERIFIED_IN_REPO` (read in this codebase or the
platform repo), or `UNCONFIRMED` (must be proven on hardware; never a design
dependency — repo doctrine).

---

## 1. The four layers and where each one lives

| Layer | Where | What it is |
|---|---|---|
| 1. Control4 driver | this repo, `drivers/smartbuildos-atmosphere/` + `src/atmosphere/` | Combo-style driver family member with a `uibutton` proxy; fetches NWS directly; owns all weather state |
| 2. Weather intelligence engine | `src/atmosphere/*.lua` (pure modules) | Normalization, state machine, thresholds w/ hysteresis, predictive lookahead, alert lifecycle |
| 3. Navigator WebView app | `drivers/smartbuildos-atmosphere/www/app/` | Atmosphere's **own** WebView (user directive: not the SmartBuildOS/insights one), served from the c4z via `controller://driver/…`, live data over the official JS API |
| 4. Cloud management + licensing | platform repo (`smartbuildos`, branch from `origin/main`) | `SBOS_ATMOSPHERE` catalog seed, entitlements via the existing Driver Cloud, installation status, remote settings scaffold, store listing, notifications |

**Independence rule (spec requirement):** layers 1–3 are fully functional with no
SmartBuildOS pairing and no platform reachability. The platform adds licensing,
fleet status, remote settings, and push notifications — it is never in the
weather data path. Weather safety logic never dies because the license server is
unreachable (`sbos.license` uncertainty fails open; only signed definitive
denials under server-set `enforce` mode refuse — VERIFIED_IN_REPO).

---

## 2. Reusable services (audit result — reuse, do not rebuild)

### Driver repo (`control4-smartbuildos`)

| Asset | Reuse |
|---|---|
| `lib.http` (deferred promises, redaction), `lib.persist` (encrypted opt), `lib.logging`, `lib.utils`, `JSON`, `drivers-common-public.global.{handlers,timer,lib,url}` | require, don't rewrite |
| `src/sbos/license.lua` | the entire licensing client — five-line integration, SKU `SBOS_ATMOSPHERE` |
| SmartBuildOS Agent (`drivers/smartbuildos/`) | pairing, HMAC-verified entitlement cache + grace ladder, `REPORT_MEASUREMENT`/`SEND_EVENT` reporting path, self-update |
| `bond-weather` driver | the template for: `TEMPERATURE_VALUE`/`HUMIDITY_VALUE` provider connections, dual-unit variables, transition-only events with first-sight-is-baseline, `Display Units` property |
| `unifi-protect` snapshot relay | the `C4:CreateServer` HTTP relay pattern — held in reserve for radar (see §7); not needed for the UI data path |
| `smartbuildos-insights` | reference only for two measured Navigator facts (`URL_CHANGED` at runtime; notifies before project-start are lost → 60 s re-publish). Its cloud-URL approach is explicitly **not** used |
| Build/test harness | `make build` pipeline (preprocess → gen-squishy → package), `test/c4_shim.lua`, `test_driver_xml_guard.lua`, per-driver `www/documentation/index.md` |
| CI | `publish-to-store.yml` — add one `sku_for()` case |

### Platform repo (`smartbuildos`, on `origin/main` — the local default checkout is on a stale pre-Driver-Cloud branch; all platform work branches from `origin/main`)

| Asset | Reuse |
|---|---|
| `src/lib/server/weather-nws.ts` + `src/lib/weather/*` | existing keyless NWS client + pure hazard engines; extend (hourly + observations) rather than duplicate |
| Driver Cloud (`src/lib/driver-cloud/*`, 8 tables, controller + platform routes, Studio surfaces) | licensing, packages/updates, fleet health, devices, incidents — all data-driven off one `driver_catalog` row |
| `finalizePairing` / `authenticateController` | identity + tenancy; company/property ids come from the token, never the body |
| `control4_monitor_config` + heartbeat response | **the** remote-settings precedent: declarative config rides an existing outbound poll; clamped defaults; no inbound channel to the controller |
| `control4_commands` allowlisted queue | imperative one-shots if ever needed (not V1) |
| `dispatchNotification` (`control4` channel, opt-in dedupe keyed to the source event's own timestamp) | weather alert push to customers/dealers |
| Guard tests | route-gating / orphan-routes / admin-tenant-scope / schema-drift / tenant-tables — each has a documented compliance path |

---

## 3. Driver architecture (layer 1 + 2)

### 3.1 Shape

One driver, `drivers/smartbuildos-atmosphere/` — **proxy driver** (not combo): a
single `uibutton` proxy (binding 5001) carries the Navigator experience, and
provider CONTROL connections publish sensor values. Modeled on
`smartbuildos-insights` (proxy/UI) × `bond-weather` (sensor/value connections).
`minimum_os_version` **3.2.0** — this pins Navigator's engine at Firefox 96+
(VERIFIED_BY_DOCS: T3 ≥3.1.3 and T4 ≥3.2.1 run Gecko 96; the Chrome-30 era is
OS ≤3.1.2, below our floor) and gives the WebView JS API (OS 3.1.3+).

Connections (provider, `facing 6`, `type 1`, `linelevel`):
`Outdoor Temperature` (`TEMPERATURE_VALUE`, 100), `Outdoor Humidity`
(`HUMIDITY_VALUE`, 101) — bindable to any thermostat as its outdoor sensor
(bond-weather pattern, VERIFIED_IN_REPO).

### 3.2 Lua modules — `src/atmosphere/` (shared-lib layout, auto-bundled by gen-squishy)

Pure modules (no `C4`, dependency-injected clock/config — unit-testable under
the plain harness):

| Module | Responsibility |
|---|---|
| `units.lua` | SI→display conversions (NWS observations are strict SI: degC, km/h, **Pa**, **metres** — VERIFIED_LIVE); nil-safe, never nil→0 |
| `normalize.lua` | raw NWS JSON → normalized observation/forecast objects; per-field null guards + MADIS `qualityControl` filter (drop `X`/`Q`/`B`); wind-string parsing ("5 to 10 mph"); interval expansion for grid data |
| `state.lua` | weather mode (CLEAR…HURRICANE, UNKNOWN) + severity (NORMAL…EMERGENCY); retained across polls; meaningful-transition detection |
| `thresholds.lua` | installer thresholds + hysteresis (enter/exit bands); boolean states IS_RAINING…DATA_STALE |
| `predict.lua` | lookahead intelligence from hourly forecast + grid PoP (rain expected ≤1/3/6 h, freeze tonight, storm soon, …). Granularity honesty: NWS hourly is 1 h resolution — **no "within 30 minutes" claim is possible from this data**; that feature is documented as unsupported rather than faked |
| `alerts.lua` | alert lifecycle: dedupe by CAP `id`, supersede via `references[]` (an Update does NOT retire its predecessor for you — VERIFIED_LIVE), Cancel/expiry handling (`ends` = event over, `expires` = message stale — distinct semantics), category filters + sensitivity modes, severity ranking |
| `solar.lua` | NOAA solar-position math from project lat/lon (no `C4:GetSunrise` exists — VERIFIED_BY_DOCS negative finding; Director only exposes sunrise via Scheduler *entries*, not readable values). Offline, deterministic, unit-tested against published NOAA tables. Cross-checked against forecast `isDaytime` |
| `simulator.lua` | canned condition/alert payloads injected at the top of the same normalize→state→events path real data uses; SIMULATION flag rides the state; auto-timeout |
| `intervals.lua` | ISO8601 interval/duration parsing (`2026-08-31T00:00:00+00:00/PT6H`) and time math in the site's IANA zone from `/points` |

C4-coupled modules:

| Module | Responsibility |
|---|---|
| `nws.lua` | HTTP client over `lib.http`: points discovery, station selection w/ stale-station fallback down the (nearest-first, UNCONFIRMED ordering) list, observations, daily+hourly forecast, targeted gridpoint layers, alerts by point/zone. Identifying User-Agent (`SmartBuildOS Atmosphere/<ver> (smartbuildos.io, support@smartbuildos.io)`) — required by policy; **config slot reserved for a future API key** (docs announce one is coming — VERIFIED_BY_DOCS) |
| `scheduler.lua` | polling cadences (obs 5 m / forecast 15 m / alerts 60 s), jitter, failure backoff ladder 1→2→5→10→15 m per endpoint class, respect for `Cache-Control`/`Expires` where present, periodic `/points` re-resolution (grid mapping can CHANGE for a fixed coordinate — VERIFIED_BY_DOCS) |
| `store.lua` | persisted cache of last-good data + fetched-at stamps via `lib.persist`; staleness computation; survives restart |
| `c4surface.lua` | variables (stable add order), events (XML ids + re-AddEvent at init), conditionals, VALUE_CHANGED publishing, transition-only firing |
| `ui.lua` | WebView data plane: serves `onDataToUi` snapshots + handles `C4.sendCommand` verbs from the app (state, forecast, alerts, settings get/set, diagnostics, simulate) |
| `settingsstore.lua` | versioned settings schema (`settings_version`), validation, migration table, apply/ack for remote settings |
| `diag.lua` | per-endpoint health, last success/failure, HTTP codes, latency, cache ages, license/agent state; feeds property + WebView + Agent reporting |

`driver.lua` is thin composition + handler wiring. This satisfies the
no-monolith requirement; the split mirrors the module map in the product spec
(names adjusted to repo conventions).

### 3.3 Location discovery chain

1. **Director project location** (default, zero-config): lat/lon read at
   LateInit; system events 52/53/54 (`OnZipcodeChanged`/`OnLatitudeChanged`/
   `OnLongitudeChanged`) trigger re-discovery (VERIFIED_IN_REPO: handlers.lua
   documents the events; the exact read API — `C4:GetLocationInfo`/project
   properties — is verified in code during Phase 2 since `C4:GetGeoSettings`
   returns only country, VERIFIED_BY_DOCS).
2. **SmartBuildOS property coordinates** when paired (rides Agent link).
3. **Installer manual entry**: lat/lon typed directly, or address/ZIP/city
   geocoded through SmartBuildOS (Apple→Census chain, VERIFIED_IN_REPO) when
   paired.

Exact lat/lon preferred internally; `/points` result (office, gridX/Y, zone,
county, fire zone, station list URL, radarStation, IANA timeZone) cached in
persist and re-resolved only on location change **plus** a slow periodic check.

### 3.4 Failure model

Per spec: last-good state retained + `DATA_STALE` after threshold; ages exposed;
no fabricated events; no `nil→0` conversions (a null temperature is UNKNOWN,
never 0 °F); API outage ≠ "no alerts"; UI shows stale banner. Missing fields are
normal in live NWS data — a single healthy observation carried six nulls
(VERIFIED_LIVE) — so every field is independently nullable end-to-end.
Rate-limit guidance: docs promise only "an error… typically retryable within
5 seconds" (429 NOT documented) — backoff keys on any non-2xx, not a status code.

---

## 4. WebView architecture (layer 3) — Atmosphere's own

**User directive:** do not reuse the SmartBuildOS webview; the driver ships its
own. Confirmed mechanism (VERIFIED_BY_DOCS, ui_button proxy docs):

- `<web_view_url proxybindingid="5001">controller://driver/smartbuildos-atmosphere/app/index.html</web_view_url>`
  — `controller://driver/<name>/` roots at the c4z `www/` directory; the driver
  name MUST equal the c4z filename. `mobile_web_view_enabled` for OS 3.0+ apps.
- **Data plane = the official WebView JavaScript API** (`C4.sendCommand`,
  `C4.subscribeToVariable`, `C4.subscribeToDataToUi` / `onDataToUi`), which is
  available **only to driver-hosted pages** — a cloud URL gets nothing
  (VERIFIED_BY_DOCS). This is why the app must live in the c4z, and it removes
  the need for a driver-side HTTP server for UI data: no LAN port, no CORS, no
  secrets in the page. (The earlier C4:CreateServer plan is superseded for UI
  data; the relay pattern stays available for radar edge cases only.)
- Known traps honored: runtime URL changes need `SendToProxy(5001,
  "URL_CHANGED", …)`; Navigator will not change the URL of an *open* web view;
  a notify sent before project start is lost → 60 s LateInit re-publish
  (VERIFIED_IN_REPO, insights).

**App:** single-page, zero external dependencies (no CDN, no webfonts —
everything in the c4z), ES2015/flexbox baseline for Firefox 96, Canvas-based
weather animations with `OFF/SUBTLE/NORMAL/CINEMATIC` tiers + automatic
fallback (device-pixel budget + rAF frame-time probe → drop tier). WebGL is
UNCONFIRMED on Navigator hardware and therefore not a dependency. Screens: NOW /
HOURLY / FORECAST / RADAR / ALERTS / DETAILS / SETTINGS with bottom navigation.
All NWS-originated text (headlines, descriptions, instructions, station names)
is rendered as **text nodes, never innerHTML** — external weather content is
untrusted (spec + common sense); a strict CSP meta tag is set although Navigator
enforcement is UNCONFIRMED.

**Certification honesty (material finding):** Snap One states there is **no
Control4 certification for WebView Experience drivers** and reserves the right
not to list them (VERIFIED_BY_DOCS). Consequence: Atmosphere distributes through
the **SmartBuildOS driver store** (our own channel — already live), not the
Control4 driver database; the driver remains fully functional without the
WebView (variables/events/conditionals/value connections are the automation
product; the app is the display product). This is recorded in KNOWN_LIMITATIONS
and the store listing.

---

## 5. Radar & maps (decision)

- `api.weather.gov` serves **no radar pixels** (VERIFIED_BY_DOCS FAQ + live probe).
- **V1 default: RIDGE2 pre-rendered imagery** — `https://radar.weather.gov/ridge/standard/{SITE}_0.gif` and `{SITE}_loop.gif` (+ `CONUS`), VERIFIED_LIVE (200, image/gif). Boundaries, cities, and warning polygons are already composited by NWS; public domain; one `<img>`; no basemap licensing problem, no tile stack, no key. Station comes from `/points.radarStation`. Loop = animation with play/pause implemented by swapping loop/static frames; timestamp from fetch time.
- **V1.x enhanced view (flagged, best-effort):** `mapservices.weather.noaa.gov` `radar_base_reflectivity_time` ImageServer `exportImage` (time-enabled, VERIFIED_LIVE) + `WWA/watch_warn_adv` polygons for zoom/pan by bbox — **export-only, no tile cache exists** (`singleFusedMapCache:false`, VERIFIED_LIVE), so this is composed-image-per-view, NOT a slippy map. Self-drawn state/county vectors (Census TIGER, public domain) if a custom basemap is ever needed.
- **Never:** `tile.openstreetmap.org` (policy prohibits fleet/bulk use — VERIFIED_BY_DOCS), CARTO (key required), screen-scraping. USGS National Map noted as the only clean no-key imagery fallback (rate/uptime UNCONFIRMED).
- The WebView loads radar images directly from `radar.weather.gov` (public, keyless). If Navigator's webview cannot load external images (UNCONFIRMED until hardware), fallback = the proven `C4:CreateServer` relay serving the GIF from the controller.

## 6. Solar

No DriverWorks sunrise getter exists (§3.2). `solar.lua` implements the NOAA
solar equations locally → `SUNRISE`, `SUNSET`, `MINUTES_TO_SUNRISE`,
`MINUTES_TO_SUNSET`, `IS_DAYTIME` — offline-capable, timezone-correct via the
`/points` IANA zone, DST-safe (computed per-day in local time), verified in
tests against NOAA reference tables.

---

## 7. Control4 programming surface

- **Variables** (stable add-order at init, categories per spec): CURRENT_*/
  FEELS_LIKE_F/HUMIDITY_PERCENT/…/WEATHER_MODE/WEATHER_SEVERITY/RAIN_PROBABILITY/
  IS_* booleans/ACTIVE_ALERT_COUNT/HIGHEST_ALERT_SEVERITY/LATEST_ALERT_*/
  LAST_WEATHER_UPDATE/DATA_AGE_SECONDS/DATA_STALE/API_STATUS/LICENSE_STATUS +
  SUNRISE/SUNSET/MINUTES_TO_*/IS_DAYTIME. Curated, not raw-dump.
- **Events**: static XML ids (frozen forever once shipped) + re-AddEvent at
  init; the full rain/wind/temperature/storm/alert matrix from the spec.
  NWS's 111 event types (live vocabulary endpoint) map to the alert event set
  via a normalized mapping table in `alerts.lua`; unmapped types fire the
  generic advisory/watch/warning events by severity.
- **Transition-only firing** with first-sight-is-baseline (bond-weather
  pattern): a restart never re-announces rain that never stopped; simulation
  and threshold changes go through the same transition gate.
- **Conditionals**: IS_RAINING / IS_FREEZING / IS_HIGH_WIND / DATA_STALE /
  ALERT_ACTIVE / SIMULATION_ACTIVE etc.
- **Actions**: Refresh Weather/Forecast/Alerts/All, Open <screen>×7, Enable/
  Disable Weather Automation, Clear Cached Weather, Reinitialize, Test Weather
  API / Alerts API / SmartBuildOS Licensing, Start/Stop Simulation, Refresh
  License, Print Diagnostics To Log.
- **Composer properties kept minimal** (spec): pairing/license block (house
  style), Location (display), Driver/Weather Status, Data Freshness, Log
  Level/Mode, Open Settings/Diagnostics pointers. Everything else lives in the
  WebView Settings app.

---

## 8. Licensing (layer 4a)

Exactly the existing machinery; nothing new is invented:

- Driver: `license.setup({ sku = "SBOS_ATMOSPHERE" })` + `EC.SBOS_ENTITLEMENT`
  + `EC.REFRESH_LICENSE` + the four license display properties.
- Agent: already generic — caches HMAC-verified assertions (canonical string
  NEVER reordered), 24 h revalidate / 7 d as-issued / 10 d dated grace →
  `CLOUD_VALIDATION_REQUIRED`; refusals never improve with age; clock-anomaly
  clamps. Offline states map to the spec's VALID/VALID_OFFLINE/GRACE/EXPIRED/
  REVOKED/INVALID vocabulary via the existing status set.
- License models: catalog row supports subscription-included ×
  tier / PERPETUAL / TRIAL / GRACE / DEVELOPER / NFR — covers trial, NFR,
  single-system, perpetual, annual (subscription), dealer (NFR/DEVELOPER),
  enterprise (tier) from the spec.
- **Enforcement posture:** ships `observe`. If later set to `enforce`
  server-side, the gated surface is the WebView premium screens (radar,
  animations) and predictive engine — **never** current conditions, never
  safety-relevant alert events. Weather safety logic is exempt from enforcement
  by design (spec requirement).
- Platform: one seed migration inserts the `driver_catalog` row (modeled on the
  Mode Composer seed). `features[]` inside the signed envelope reserved for
  future feature gating. `canonicalAssertion` untouched.

## 9. Cloud management + remote settings (layer 4b)

- **Installation status**: free — `driver_installations`, fleet health,
  devices, incidents, Studio surfaces all key off the SKU. Atmosphere
  additionally reports weather-service health (API up/stale, last obs/forecast/
  alert refresh, location, office/grid/station) via the Agent's existing
  `SEND_EVENT`/`REPORT_*` path into `driver_events` — visible in the Studio
  events surface. A dedicated Atmosphere panel in Driver Cloud Studio follows
  the ROUTE_COMPONENTS + nav registration recipe (server-module rule honored).
- **Remote settings** (scaffold now, full UI later): new table
  `driver_atmosphere_config` (key `(company_id, system_id)`, RLS revoke-first,
  service_role-only, clamped defaults, co-located COLUMNS list) copied from
  `control4_monitor_config`; delivered as an `atmosphere` block on the
  **Agent heartbeat response** (the platform never dials the controller). Agent
  forwards to the driver via `SendToDevice` (`SBOS_ATMOSPHERE_CONFIG`); driver
  validates against its versioned settings schema, applies or refuses loudly,
  and acks via a `CONFIGURATION` driver_event (audit trail). Invalid config is
  never silently applied (spec).
- **Notifications**: `dispatchNotification` with the `control4` channel;
  customer kinds (`weather.alert_warning`, `weather.freeze_expected`, …) and
  dealer kinds (`driver.atmosphere_offline`, `driver.weather_stale`, …) added
  to the catalogue; dedupe keyed to the **alert's own CAP id/onset**, never
  Date.now() (repo doctrine); role separation honored by the existing
  recipients machinery.
- **Store**: catalog row + `category` (add `CATEGORY_ICON` entry), screenshots/
  description; product detail page is new ground (the store currently uses a
  modal) — planned as the store's first detail page per the spec's store
  architecture note.

## 10. Database changes (platform)

1. `20260831XXXXXX_driver_catalog_atmosphere.sql` — seed `SBOS_ATMOSPHERE`
   (display name, description, category `Climate` (new icon entry), tier,
   `subscription_included`, `perpetual_price_cents`, `supported_os_min '3.2.0'`,
   `on conflict do nothing`).
2. `20260831XXXXXX_driver_atmosphere_config.sql` — remote-settings table
   (monitor-config clone; RLS + revoke-first + service_role; NO new grants
   pattern violations; added to `tenant-tables.txt` + `PENDING_MIGRATION_SCHEMA`).

No other schema. Entitlements/installations/events/packages tables are generic.
⚠ `apply_migration` stamps its own version — verify ledger + rename files after
applying (repo trap, twice bitten).

## 11. API caching strategy

| Data | Poll | Cache | Backoff on failure |
|---|---|---|---|
| Observations | 5 m | persist last-good + age | 1→2→5→10→15 m ladder, per endpoint |
| Daily forecast | 15 m | persist | same |
| Hourly forecast | 15 m (same tick) | persist | same |
| Alerts | 60 s | persist active set | same, floor 60 s |
| /points | on location change + 24 h re-check | persist | n/a |
| Radar GIF | on view open + loop refresh | none (image) | UI-level |

Stale thresholds: obs > 30 m, forecast > 3 h, alerts > 5 m → `DATA_STALE`
components; overall staleness = worst safety-relevant component. All fetches
carry the identifying User-Agent; server cache headers honored where present;
polls jittered to avoid fleet-synchronized load.

## 12. Security

- No secrets exist in the weather path (NWS is keyless); the only secrets on
  the controller are the Agent's (existing model, unchanged).
- WebView: driver-hosted page, no external script/style, JSON-only data plane
  via the official JS API, all external text escaped, no tokens ever passed to
  the page, no localStorage of anything sensitive.
- Remote settings: validated against a versioned schema before apply; refused
  payloads reported; platform side writes via permission-gated route + audit log.
- Platform tables: revoke-first RLS pattern; controller identity always from
  `authenticateController`, never the body.
- Malformed NWS responses: every decode `pcall`'d, every field null-guarded,
  qualityControl filtering; fixtures include malformed/missing/hostile payloads.

## 13. Versioning & upgrade path

- Releases use the repo's current timestamp scheme; ⚠ the `YYYYMMDD.N` scheme
  switch is **cross-repo staged and must not ship one-sided** (platform PR #223
  pending) — Atmosphere follows whatever the repo ships, it does not fork the
  scheme.
- Driver settings carry `settings_version` + a migration table from v1 so
  renames/additions never lose installed settings.
- Event/variable IDs are frozen at first ship (Composer binds them).
- `.c4z` filename is the update key — chosen once (`smartbuildos-atmosphere`),
  never renamed (icons + updater + store all key on it).

## 14. Test plan (repo-style)

Pure-module suites under `test/test_atmosphere_*.lua` (shim harness, local
`check()` style): units, normalize (incl. all-null observation, malformed JSON,
mixed unit traps: bare-F temperature vs degC dewpoint objects, wind strings,
interval expansion), state transitions, hysteresis, predict windows, alert
lifecycle (new/update-with-references/cancel/expire/dedupe/filters), solar vs
NOAA reference tables, scheduler backoff, settings migration/validation,
simulation parity (simulated tornado fires the identical event path), license
integration, XML guard extension. Fixtures: `test/fixtures/atmosphere/` —
clear/rain/freeze/high-wind/hurricane/tornado/severe-thunder/flood/winter-storm/
multi-alert/malformed/missing-obs/stale sets, captured from live API shapes.
Hardware-only items go to `docs/TEST_PLAN.md` (WebView rendering, external
image load, animation perf tiers, value-connection binding).

## 15. Phase → commit map

Follows the spec's 20-phase sequence; commits are per-phase on `main` (repo
convention) touching only Atmosphere-owned paths; the three shared files
(`publish-to-store.yml`, Agent updater list, `CHANGELOG.md`) are edited last
with selective staging because a peer session holds uncommitted changes there.

## 16. Known limitations (honest NOs, recorded up front)

- US + territories only (NWS coverage). Non-US location → clear "unsupported
  location" state, never a crash.
- No minute-level precipitation timing (NWS hourly floor) — "within 30 min" is
  not offered.
- No Control4 certification path for the WebView portion (Snap One policy);
  distribution is the SmartBuildOS store.
- Alert latency is bounded by 60 s polling — a NOAA weather-radio replacement
  this is not, and docs/marketing must say so.
- WebGL, Navigator external-image loading, animation perf: UNCONFIRMED until
  hardware passes.
