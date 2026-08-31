# SmartBuildOS Atmosphere

Weather intelligence for Control4, powered by the National Weather Service.
Not a temperature display: a weather engine that turns official NWS data into
automation decisions — rain approaching, freeze expected tonight, shades at
risk from wind, a tornado warning active at this property — plus a premium
Navigator weather app with radar, forecasts, alerts, and animated conditions.

## Requirements

- Control4 OS 3.2.0 or newer (the Navigator app uses the WebView engine and
  JS API introduced earlier; 3.2.0 pins a modern browser on T3/T4).
- A US location (NWS covers the United States and its territories). Outside
  coverage the driver says so plainly instead of guessing.
- Internet access from the controller to `api.weather.gov` and
  `radar.weather.gov`. No API key, no account, no per-call cost.
- Optional: the SmartBuildOS Agent driver for licensing, remote settings,
  fleet status, and push notifications. Weather automation works without it.

## Setup (10 minutes)

1. Add `smartbuildos-atmosphere.c4z` via Driver > Add or Update Driver.
2. Confirm the **Driver Version** property populates (it exists for exactly
   this check).
3. Location: with a project location set in Composer, the driver discovers
   everything itself — **Resolved Location**, **Forecast Office**, and
   **Observation Station** fill within a minute. No project location? Set
   **Location Source** to Manual Coordinates and type Latitude/Longitude.
4. Open the Atmosphere tile on any Navigator to see the weather app. All
   detailed configuration (units, thresholds, alert filters, radar, themes,
   simulation) lives in the app's **Settings** screen — Composer properties
   stay minimal on purpose.
5. Optionally bind **Outdoor Temperature** / **Outdoor Humidity** to a
   thermostat: Atmosphere becomes the project's outdoor sensor.

## Programming

Events fire on meaningful transitions only — a restart never re-announces
rain that never stopped, and a value hovering at a threshold never bounces
your automation (enter/exit hysteresis).

Examples that work out of the box:

- WHEN **Rain Expected Within 3 Hours** → skip irrigation.
- WHEN **High Wind Started** → retract awnings, raise exterior shades.
- WHEN **Freeze Expected** → activate pipe-protection heat.
- WHEN **Tornado Warning** → close shades, lights full, stop entertainment,
  announce.
- WHEN **Weather Data Stale** → notify the dealer (data health is its own
  event family; an API outage never silently looks like calm weather).

Variables for conditionals include `CURRENT_TEMPERATURE_F/C`, `FEELS_LIKE_F`,
`WIND_SPEED_MPH`, `RAIN_PROBABILITY`, `WEATHER_MODE`, `WEATHER_SEVERITY`,
`IS_RAINING`, `IS_FREEZING`, `IS_HIGH_WIND`, `ACTIVE_ALERT_COUNT`,
`HIGHEST_ALERT_SEVERITY`, `SUNRISE`, `SUNSET`, `DATA_STALE`, and more.

## Simulation

Test programming without waiting for weather: **Start Simulation** (a
programming command, also in the app's Settings) with scenarios from `clear`
to `tornado_warning`. Simulated conditions fire the exact same events real
data would; the app, the `Simulation` property, and the
`SIMULATION_ACTIVE` variable all say loudly that simulation is running.
Simulation auto-stops after a configurable timeout (default 30 minutes).

## Data honesty

- Missing readings stay blank — never a fake 0°F.
- If the NWS API fails, the last good data is kept, marked STALE with its
  age, and polling backs off (1→2→5→10→15 min) until recovery.
- "No alerts" is only reported when the alerts endpoint actually answered.
- Predictions come from the NWS hourly forecast (1-hour resolution). The
  driver deliberately offers no "within 30 minutes" claims — the data
  cannot support them.

## Properties

| Property | Meaning |
| --- | --- |
| Weather Status | Current temp + condition; flags SIMULATION and STALE |
| Data Freshness | Age of the last observation |
| Active Alerts | Count and highest active alert |
| Location Source | Control4 Project (default) or Manual Coordinates |
| Resolved Location | What the driver is actually using |
| Forecast Office / Observation Station | NWS discovery results |
| License Status | SmartBuildOS licensing state; driver runs without an Agent |

## Troubleshooting

- **"Location is outside NWS coverage"** — the property is outside the US;
  NWS has no data there. This driver is honest about it.
- **Station shows but temperature is blank** — some NWS stations report
  partial data; nearby fields fill as observations arrive. Blank means
  "not reported", never zero.
- **Weather Status says STALE** — the controller cannot reach
  `api.weather.gov` (or NWS is having an outage). Automation holds last
  known state; the app shows a stale banner. Check `Test Weather API`.
- **Navigator tile opens a blank page** — reboot recovery re-publishes the
  app URL 60 s after startup; if it persists, run action `Reinitialize
  Weather Services`.
- **Print Diagnostics To Log** prints the full picture: endpoints, HTTP
  codes, failure counters, cache ages, license state.

## Safety note

Atmosphere polls alerts every 60 seconds and depends on internet, NWS
uptime, and the Control4 controller. It is a convenience and automation
layer — not a NOAA weather radio, and not a life-safety system.
