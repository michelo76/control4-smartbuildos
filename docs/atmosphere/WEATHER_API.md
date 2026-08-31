# Atmosphere — NWS Integration

How the driver talks to `api.weather.gov`, what it does with the answers, and —
just as important — what the data cannot support. Client:
`src/atmosphere/nws.lua`; normalization: `src/atmosphere/normalize.lua`;
cadence/backoff: `src/atmosphere/scheduler.lua`. Facts marked *measured* were
live-verified against the API on 2026-08-31 (see
`docs/atmosphere-architecture.md` for the full provenance record).

## Endpoints used

| Endpoint                                 | Purpose                                                                                                                                                                                                                                |
| ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /points/{lat},{lon}`                | Discovery: office, gridX/Y, forecast + hourly + grid URLs, station-list URL, forecast zone, county, fire zone, radar station, IANA timezone. Coordinates are rounded to 4 decimals (~11 m) — the API redirects higher precision anyway |
| `GET {observationStations}`              | Ordered station candidates (observed nearest-first; ordering is not documented by NWS)                                                                                                                                                 |
| `GET /stations/{id}/observations/latest` | Current conditions                                                                                                                                                                                                                     |
| `GET {forecast}` and `{forecastHourly}`  | Daily and hourly forecast periods (both URLs come from `/points`, never constructed by hand)                                                                                                                                           |
| `GET /alerts/active?zone={forecastZone}` | Active alerts. Zone is preferred — zone-scoped products can miss a point query. Falls back to `?point={lat},{lon}` when no zone is known yet                                                                                           |
| `GET {forecastGridData}`                 | Raw gridpoint layers. The client and interval-expansion normalizer exist (`nws.gridData` / `normalize.gridLayer`) but **the driver does not poll this endpoint in V1** — predictions run off the hourly forecast only                  |

All responses are GeoJSON; the payload of interest is `.properties` (or
`.properties.periods`). Every decode is `pcall`'d; an undecodable body is a
failure, never a crash.

## Polling cadences

| Data                    | Healthy cadence                         | Trigger                                                    |
| ----------------------- | --------------------------------------- | ---------------------------------------------------------- |
| Observations            | 5 min                                   | timer                                                      |
| Daily + hourly forecast | 15 min (same tick, fetched in parallel) | timer                                                      |
| Alerts                  | 60 s                                    | timer                                                      |
| `/points`               | 24 h re-check                           | plus: startup, location change, Rediscover Location action |

Startup polls are phase-jittered per controller (deterministic hash of the
device id) so a fleet never aligns on the same second. Steady-state cadence
after the first fetch is fixed.

## Failure backoff

NWS documents rate limiting only as "an error… typically retryable within 5
seconds" — a 429 is NOT promised (*measured against the docs*). The scheduler
therefore backs off on **any** failure, never keying on a status code:

```
1 min → 2 min → 5 min → 10 min → 15 min (held at the top until recovery)
```

Per endpoint class, independently. One floor: alerts backoff never polls alerts
*faster* than the healthy 60 s cadence. `/points` failures ride the same ladder
while the cached discovery record keeps serving.

While failing, the driver retains last-good data, marks it `STALE` past its
freshness threshold (observations > 30 min, forecast > 3 h, alerts > 5 min, all
installer-tunable), and fires the data-health events — an API outage is loud,
never silently "calm weather" or "no alerts".

Note: the architecture doc calls for honoring `Cache-Control`/`Expires` response
headers where present; the current client does not read response headers. The
fixed cadences above are comfortably conservative for every NWS endpoint
involved, but header-driven caching is not implemented.

## Identification and the future API key

- Every request carries an identifying User-Agent, required by NWS policy:
  `SmartBuildOS Atmosphere (smartbuildos.io, support@smartbuildos.io)`. (The
  architecture doc specifies a `/{version}` in the UA; the current default omits
  it. `nws.setUserAgent()` exists if that changes.)
- NWS has announced a future API-key scheme. A key slot exists **now**
  (`nws.setApiKey` → `X-Api-Key` header) so the installed fleet survives that
  day with a settings push rather than a driver update.

## Normalization rules

Built around measured realities of live NWS data:

- **Observations are strict SI regardless of locale** (*measured*): degC, km/h,
  Pa (not hPa), metres. All conversions happen driver-side
  (`src/atmosphere/units.lua`) and every converter is nil-safe: nil in, nil out.
  **A missing reading never becomes 0.** A null temperature is UNKNOWN, never 0
  °F.
- **Every observation quantity is `{value, unitCode, qualityControl}` and any of
  them can be null in an otherwise healthy response** (*measured: one good
  observation carried six nulls*). Every field is independently nil-guarded
  end-to-end.
- **MADIS quality control:** values flagged `X` (rejected), `Q` (questionable),
  or `B` (subjected & failed) are dropped rather than displayed. `V`, `Z`, `C`,
  etc. pass through.
- **Forecast periods mix conventions** (*measured*): temperature is a *bare
  number* in the unit named by `temperatureUnit` (usually F, C honored),
  dewpoint is an *object* in degC, `windSpeed` is a *human string* — `"5 mph"`
  and `"5 to 10 mph"` are parsed to a lo/hi range; anything else yields nil.
- **Hourly quirks** (*measured*): period `name` is an empty string;
  `probabilityOfPrecipitation.value` can be null and stays null.
- **Gridpoint layers** use interval-with-duration timestamps
  (`2026-08-31T00:00:00+00:00/PT6H`); the parser expands them and refuses
  month/year durations (no fixed length — guessing would corrupt the expansion).
- **Timestamps** are parsed with our own civil-day math, never `os.time()` on a
  broken-down table — that would silently skew every parse by the controller's
  UTC offset.
- Cloud cover is derived from METAR layer amounts (worst layer wins: CLR/SKC 0,
  FEW 19, SCT 44, BKN 75, OVC/VV 100). `presentWeather` is authoritative for "is
  it precipitating right now" when populated; the text description is the
  fallback.
- Unparseable forecast periods are dropped individually — one bad period never
  fails the batch.

## Station selection and fallback

`/points` yields an ordered candidate list. The driver walks it nearest-first
and adopts the first station whose latest observation parses and is under 90
minutes old (up to 4 candidates per pass). A chosen station that fails three
consecutive polls is dropped and selection re-runs — partial or dead stations
are normal in the NWS network, and "blank" always means *not reported*, never
zero.

## The honest limits

- **US and territories only.** A `/points` answer with no grid means no NWS
  coverage; the driver states it and stops, rather than inventing weather.
- **1-hour forecast resolution.** NWS hourly data cannot support sub-hour
  claims. There is deliberately **no** "rain expected within 30 minutes"
  anywhere in the product — the gap is documented, not faked.
- **Alert latency is bounded by the 60 s poll.** Atmosphere is a convenience and
  automation layer, not a NOAA weather radio and not a life-safety system.
- **"No alerts" is only reported when the alerts endpoint actually answered.** A
  failed poll retains the active set; alerts age out only by their own
  `ends`/`expires` clocks.
