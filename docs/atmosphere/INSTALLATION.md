# Atmosphere — Dealer Installation

Target: a working install in about 10 minutes. This document is the long-form
version of the manual that ships in the c4z
(`drivers/smartbuildos-atmosphere/www/documentation/index.md`).

## Prerequisites

- **Control4 OS 3.2.0 or newer.** The floor is deliberate: 3.2.0 pins
  Navigator's WebView engine at Gecko 96+ on T3/T4 (the Chrome-30 era is OS ≤
  3.1.2) and covers the WebView JS API (3.1.3+). The driver refuses to start
  below the minimum and reports it on `Driver Status`.
- **A US location.** NWS covers the United States and its territories. Outside
  coverage the driver reports "Location is outside NWS coverage (US only)"
  instead of guessing.
- **Internet access from the controller** to `api.weather.gov` (weather data)
  and `radar.weather.gov` (radar imagery). No API key, no account, no per-call
  cost.
- **SmartBuildOS Agent driver (`smartbuildos.c4z`).** Every SmartBuildOS
  Control4 product licenses through the Agent. It also provisions Atmosphere's
  driver-scoped cloud upload so app data works off-LAN. Weather safety logic
  remains fail-open during an Agent or cloud outage.

## Adding the driver

1. Composer Pro → Driver → **Add or Update Driver or Agent** →
   `smartbuildos-atmosphere.c4z`.
1. Add **SmartBuildOS Atmosphere** to the project (Composer category: Sensors).
1. Confirm the **Driver Version** property populates. It exists for exactly this
   check — a version still reading `unknown` means the Lua never ran (see
   [TROUBLESHOOTING.md](TROUBLESHOOTING.md)).

Note the repo-wide Composer quirk: after **updating** an existing driver,
restart Composer before programming against it — Composer caches the event list
and may show the old set.

## Location: the resolution chain

The driver needs one thing from you: coordinates. It resolves them in this
order, controlled by the **Location Source** property:

1. **Control4 Project** (default, zero-config). The driver reads the project
   location from Director at startup and whenever Director fires a
   location-changed system event (zipcode / latitude / longitude changes
   re-resolve automatically). If the project has a location set in Composer,
   there is nothing to do. *Hardware note:* the Director XML shape this parse
   expects is on the hardware test plan; the parser is tolerant, but a project
   whose location reads 0,0 or fails to parse falls through to "Not resolved".
1. **Manual Coordinates.** Set **Location Source** to Manual Coordinates and
   type **Latitude** / **Longitude** in decimal degrees (validated to ±90 /
   ±180). Use this when the project location is unset or wrong.
1. **SmartBuildOS property location** (when paired). The property's coordinates
   can be applied from the app's Settings screen via the SmartBuildOS
   remote-settings path — see
   [SMARTBUILDOS_INTEGRATION.md](SMARTBUILDOS_INTEGRATION.md). This is a
   convenience over the same two mechanisms above, not a third data source
   inside the driver.

Exact latitude/longitude is preferred internally. From the coordinates the
driver discovers everything else itself via the NWS `/points` endpoint: forecast
office, grid, forecast zone, observation station list, radar station, and IANA
timezone. Discovery results are cached and survive restarts; they re-resolve on
location change plus a slow daily re-check (the NWS office/grid mapping for a
fixed coordinate can change).

## Verification checklist

Within about a minute of adding the driver with a valid location, confirm:

- [ ] **Driver Status** reads `Online`.
- [ ] **Driver Version** shows a real version (not `unknown`).
- [ ] **Resolved Location** shows the label and coordinates actually in use,
  e.g. `Fort Lauderdale (26.1224, -80.1373)`.
- [ ] **Forecast Office** shows an NWS office + grid, e.g. `MFL grid 110,50`.
- [ ] **Observation Station** shows a station id, e.g. `KFLL`.
- [ ] **Weather Status** shows a temperature and condition, e.g.
  `86.0°F Partly Cloudy`.
- [ ] **Data Freshness** shows a recent age, e.g. `obs 3m ago`.

If any of these stall, run the **Test Weather API** action and read the Lua
output; then see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Thermostat outdoor-sensor binding

Atmosphere publishes two provider connections:

| Connection          | Binding | Class               |
| ------------------- | ------- | ------------------- |
| Outdoor Temperature | 100     | `TEMPERATURE_VALUE` |
| Outdoor Humidity    | 101     | `HUMIDITY_VALUE`    |

In Composer's Connections view, bind them to any thermostat that consumes an
outdoor temperature/humidity sensor — Atmosphere becomes the project's outdoor
sensor with no extra hardware. Values are pushed on every observation with both
Celsius and Fahrenheit. When observations go stale the driver deliberately sends
`VALUE_UNAVAILABLE` rather than a stale number — a thermostat holding an
hours-old outdoor reading is worse than one showing none.

*Hardware note:* the VALUE connection binding against a real thermostat is a
hardware-test-plan item; it follows the proven bond-weather pattern but has not
yet been exercised on a physical system.

## Composer properties (reference)

Properties stay minimal on purpose — detailed configuration (units, thresholds,
alert filters, radar, themes, simulation) lives in the app's Settings screen.

| Property                                                                   | Meaning                                                                                                 |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Driver Status / Driver Version                                             | Health + install verification                                                                           |
| Weather Status                                                             | Current temp + condition; flags SIMULATION and STALE                                                    |
| Data Freshness                                                             | Age of the last observation                                                                             |
| Active Alerts                                                              | Count and highest active alert                                                                          |
| Simulation                                                                 | Off, or the running scenario                                                                            |
| Location Source / Latitude / Longitude                                     | The resolution chain above                                                                              |
| Resolved Location                                                          | What the driver is actually using                                                                       |
| Forecast Office / Observation Station                                      | NWS discovery results                                                                                   |
| License Status / License Source / Subscription Tier / SmartBuildOS Company | Licensing display — see [LICENSING.md](LICENSING.md)                                                    |
| Log Level / Log Mode                                                       | Standard repo logging controls                                                                          |
