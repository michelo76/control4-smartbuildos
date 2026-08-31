# SmartBuildOS Atmosphere

Weather intelligence for Control4, powered by the National Weather Service.

**SKU:** `SBOS_ATMOSPHERE` · **Package:** `smartbuildos-atmosphere.c4z` ·
**Minimum OS:** 3.2.0 · **Coverage:** United States and territories (NWS)

Atmosphere is not a temperature display. It is a weather engine that turns
official NWS data into automation decisions — rain approaching, freeze expected
tonight, shades at risk from wind, a tornado warning active at this property —
surfaced as 58 Composer events, 44 variables, 9 conditionals, and two sensor
connections any thermostat can bind as its outdoor sensor. A Navigator WebView
app (Atmosphere's own, served from the c4z) is the display layer on top.

Repo doctrine applies throughout these docs: **docs are a hypothesis, hardware
is the answer.** Anything not yet proven on a physical controller is tagged
"hardware-unverified" — see [TESTING.md](TESTING.md) for the hardware test plan.
As of this writing the driver has zero hardware passes.

## The four layers

| Layer                           | Where                                              | Status                                                                                                                                           |
| ------------------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1. Control4 driver              | `drivers/smartbuildos-atmosphere/`                 | Built; 331 checks green; hardware-unverified                                                                                                     |
| 2. Weather intelligence engine  | `src/atmosphere/*.lua` (14 pure/near-pure modules) | Built and unit-tested                                                                                                                            |
| 3. Navigator WebView app        | `drivers/smartbuildos-atmosphere/www/app/`         | **Not yet in the repo.** The driver-side contract (JS API verbs, state document, URL publishing) is built and tested; the page itself is pending |
| 4. Cloud management + licensing | platform repo (`smartbuildos`)                     | Driver-side client built; platform catalog seed, Agent config forwarding, and store CI wiring are pending                                        |

**Independence rule:** layers 1–3 are fully functional with no SmartBuildOS
pairing and no platform reachability. The platform adds licensing, fleet status,
and remote settings — it is never in the weather data path, and weather safety
logic is never gated on the license server.

## What is built today

- `api.weather.gov` client with identifying User-Agent, pcall'd decodes, and a
  reserved future-API-key slot ([WEATHER_API.md](WEATHER_API.md)).
- Normalization that survives real NWS data: SI units, MADIS quality-control
  filtering, per-field null guards (a missing reading is never 0), mixed
  forecast unit conventions, human wind strings.
- A pure intelligence engine: weather mode + severity, installer thresholds with
  enter/exit hysteresis, hourly-forecast predictions, CAP alert lifecycle
  (dedupe, supersede, cancel, expire), transition-only events with
  first-sight-is-baseline ([CONTROL4_PROGRAMMING.md](CONTROL4_PROGRAMMING.md)).
- NOAA solar math (sunrise/sunset/daytime) computed locally — DriverWorks has no
  sunrise getter.
- 16 simulation scenarios that run through the identical engine path as live
  data, loudly flagged.
- Versioned settings with field-by-field validation and refusal reporting,
  shared by the WebView app, Composer, and remote settings
  ([SMARTBUILDOS_INTEGRATION.md](SMARTBUILDOS_INTEGRATION.md)).
- SmartBuildOS licensing client wired for `SBOS_ATMOSPHERE`
  ([LICENSING.md](LICENSING.md)).

## What Atmosphere deliberately does NOT do

- No "rain within 30 minutes" claims — NWS hourly data is 1-hour resolution; the
  gap is documented, not faked.
- No non-US operation — outside NWS coverage the driver says so plainly.
- No life-safety role — alerts poll every 60 seconds over the internet; this is
  not a NOAA weather radio.
- No Control4 certification for the WebView portion — Snap One offers no
  certification path for WebView Experience drivers; distribution is the
  SmartBuildOS driver store ([WEBVIEW.md](WEBVIEW.md)).

## Documentation map

| Document                                                   | Audience                                           |
| ---------------------------------------------------------- | -------------------------------------------------- |
| [INSTALLATION.md](INSTALLATION.md)                         | Dealers: prerequisites, setup, verification        |
| [WEATHER_API.md](WEATHER_API.md)                           | Engineers: NWS integration, polling, normalization |
| [CONTROL4_PROGRAMMING.md](CONTROL4_PROGRAMMING.md)         | Dealers: events, variables, recipes                |
| [WEBVIEW.md](WEBVIEW.md)                                   | Engineers: Navigator app mechanism + JS contract   |
| [LICENSING.md](LICENSING.md)                               | Dealers + engineers: license states and rules      |
| [SMARTBUILDOS_INTEGRATION.md](SMARTBUILDOS_INTEGRATION.md) | Engineers: what pairing adds                       |
| [RADAR.md](RADAR.md)                                       | Engineers: the radar/basemap decision record       |
| [TESTING.md](TESTING.md)                                   | Engineers: test suites + hardware test plan        |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md)                   | Dealers: symptom → cause → fix                     |
| [SECURITY.md](SECURITY.md)                                 | Engineers: threat model                            |
| [CHANGELOG.md](CHANGELOG.md)                               | Everyone                                           |

The installer-facing manual that ships inside the c4z lives at
`drivers/smartbuildos-atmosphere/www/documentation/index.md` (shown in Composer
as the driver's Documentation tab); it is the condensed dealer version of this
suite. The Phase 1 architecture audit, with provenance tags for every
load-bearing claim, is `docs/atmosphere-architecture.md`.
