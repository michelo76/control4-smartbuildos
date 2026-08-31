# Atmosphere — Control4 Programming Reference

Everything Composer programming can see: 64 events, 50 variables, 9
conditionals, 20 actions, 1 programming command. Sources of truth:
`drivers/smartbuildos-atmosphere/driver.xml` (events/conditionals/actions/
commands, ids frozen forever once shipped) and `driver.lua` (variables,
add-order frozen).

## How events fire: transitions only, with hysteresis

Two rules make Atmosphere events safe to program against:

1. **Transition-only, first-sight-is-baseline.** An event fires when a condition
   *changes*, never because it *is*. The first data the engine ever sees
   (including after `Clear Cached Weather`) sets the baseline silently: a
   restart with rain already falling announces nothing. Because engine snapshots
   persist across restarts, a real transition that spans a restart still fires.
   Polling the same active alert twice produces zero events.
1. **Enter/exit hysteresis on every threshold state.** Each boolean state
   asserts at its *enter* threshold and clears only at its *exit* threshold (a
   band, not a line), so a reading hovering at a threshold never bounces your
   automation. Example with defaults: High Wind asserts at ≥ 25 mph and clears
   at ≤ 22 mph — wind oscillating 23–24 mph fires nothing. A nil reading never
   changes a state (missing data is not evidence of anything).

Default bands (all installer-tunable in the app's Settings, each validated
against bounds): freeze 32/34 °F (air temperature — frost forms at air temp, not
feels-like), heat 90/87 °F and extreme heat 100/96 °F (feels- like), high wind
25/22 mph, dangerous wind 40/35 mph, gusts 35/30 mph, poor visibility 1/1.5 mi.

Weather automation is always on — there is no disable switch by design.
Variables, conditionals, connections, and the app keep updating, and the four
data-health events (48–51) still fire — data health *is* the signal, and
simulation start/end events also always fire.

## Events (64, grouped by family)

IDs are frozen forever (Composer programming binds them); the list is
append-only.

### Rain (1–6, 56)

| ID         | Event                                                             |
| ---------- | ----------------------------------------------------------------- |
| 1 / 2      | Rain Started / Rain Stopped                                       |
| 3          | Rain Expected Soon (within the configured lookahead, default 3 h) |
| 4 / 5 / 56 | Rain Expected Within 1 Hour / 3 Hours / 6 Hours                   |
| 6          | Heavy Rain Expected (PoP ≥ heavy-rain threshold, default 70%)     |

### Snow (7–9)

| ID    | Event                       |
| ----- | --------------------------- |
| 7 / 8 | Snow Started / Snow Stopped |
| 9     | Snow Expected               |

### Wind (10–15)

| ID      | Event                                                      |
| ------- | ---------------------------------------------------------- |
| 10 / 11 | High Wind Started / Ended                                  |
| 12 / 13 | Dangerous Wind Started / Ended                             |
| 14      | High Gust Detected (fires on assert only; clears silently) |
| 15      | High Wind Expected                                         |

### Temperature (16–21)

| ID      | Event                                                         |
| ------- | ------------------------------------------------------------- |
| 16 / 17 | Freeze Conditions Started / Ended                             |
| 18      | Freeze Expected (freezing temps in tonight's forecast window) |
| 19 / 20 | Extreme Heat Started / Ended                                  |
| 21      | Extreme Heat Expected (within 24 h)                           |

### Thunderstorm and severity (22–26)

| ID      | Event                                                       |
| ------- | ----------------------------------------------------------- |
| 22 / 23 | Thunderstorm Started / Ended                                |
| 24      | Thunderstorm Expected                                       |
| 25 / 26 | Severe Weather Detected / Ended (severity crossing WARNING) |

### Generic alerts (27–31)

| ID           | Event                                                |
| ------------ | ---------------------------------------------------- |
| 27 / 28 / 29 | New Weather Advisory / Watch / Warning               |
| 30           | Alert Escalated (an update raised severity or level) |
| 31           | Alert Cleared (canceled or expired)                  |

Every one of NWS's ~111 alert event types classifies into these; the specific
events below fire *in addition to* the generic level event.

### Specific alerts (32–47)

| ID           | Event                                             |
| ------------ | ------------------------------------------------- |
| 32 / 33      | Tornado Watch / Tornado Warning                   |
| 34 / 35      | Severe Thunderstorm Watch / Warning               |
| 36 / 37 / 38 | Flood Watch / Flood Warning / Flash Flood Warning |
| 39 / 40      | Hurricane Watch / Warning                         |
| 41 / 42      | Tropical Storm Watch / Warning                    |
| 43 / 44      | Winter Storm Watch / Warning                      |
| 45           | Freeze Warning                                    |
| 46           | Extreme Heat Warning                              |
| 47           | High Wind Warning                                 |

### Data health (48–51) — always fire, even with automation disabled

| ID      | Event                                      |
| ------- | ------------------------------------------ |
| 48 / 49 | Weather Data Stale / Weather Data Restored |
| 50 / 51 | Weather API Unavailable / Recovered        |

### Fog and ice (52–55)

| ID      | Event                          |
| ------- | ------------------------------ |
| 52 / 53 | Fog Started / Fog Cleared      |
| 54 / 55 | Ice Conditions Started / Ended |

### Simulation (57–58)

| ID      | Event                                 |
| ------- | ------------------------------------- |
| 57 / 58 | Simulation Started / Simulation Ended |

### Solar timing, barometer, recommendations (59–64)

| ID      | Event                                                                 |
| ------- | --------------------------------------------------------------------- |
| 59 / 60 | Sunset Approaching / Sunrise Approaching (within 30 minutes)          |
| 61      | Barometer Falling Rapidly (≥ 0.10 inHg fall over 3 h)                 |
| 62 / 63 | Irrigation Skip Recommended / Irrigation Skip Cleared                 |
| 64      | Shade Protection Recommended (wind endangers extended shades/awnings) |

These ride the same transition gate as every other event (first sight is
baseline; a tick with missing inputs carries the previous flags forward —
missing data never reads as "all cleared"). Only the irrigation pair announces
in both directions; 59/60/61/64 fire on assert and clear silently. The
recommendation logic (`src/atmosphere/recommend.lua`): irrigation skip when rain
is falling, ≥ 0.25 in is expected in 24 h (gridpoint QPF), or peak PoP ≥ 60%;
shade protect when sustained wind ≥ 25 mph, gusts ≥ 30 mph, or high wind is
expected. Thresholds are defaults, not yet installer-tunable.

## Variables (50)

String numbers are formatted with one decimal; **blank means "not reported",
never zero**.

Current conditions: `CURRENT_TEMPERATURE_F`, `CURRENT_TEMPERATURE_C`,
`FEELS_LIKE_F`, `HUMIDITY_PERCENT`, `DEW_POINT_F`, `WIND_SPEED_MPH`,
`WIND_GUST_MPH`, `WIND_DIRECTION` (16-point compass), `PRESSURE_INHG`,
`VISIBILITY_MILES`, `CLOUD_COVER_PERCENT`, `CURRENT_CONDITION`.

Interpretation: `WEATHER_MODE` (CLEAR, PARTLY_CLOUDY, CLOUDY, FOG, RAIN,
HEAVY_RAIN, THUNDERSTORM, SEVERE_STORM, SNOW, ICE, HIGH_WIND, FREEZE,
EXTREME_HEAT, TROPICAL, HURRICANE, UNKNOWN), `WEATHER_SEVERITY` (NORMAL,
INFORMATIONAL, ADVISORY, WATCH, WARNING, EMERGENCY).

Forecast: `RAIN_PROBABILITY` (next hourly period's PoP), `FORECAST_HIGH_F`,
`FORECAST_LOW_F`, `FORECAST_CONDITION`.

Booleans (`true`/`false` strings): `IS_RAINING`, `IS_SNOWING`, `IS_STORMING`,
`IS_FREEZING`, `IS_HOT`, `IS_HIGH_WIND`, `IS_FOGGY`, `IS_DAYTIME`,
`RAIN_EXPECTED_SOON`, `FREEZE_EXPECTED`, `STORM_EXPECTED`, `DATA_STALE`,
`SIMULATION_ACTIVE`.

Alerts: `ACTIVE_ALERT_COUNT` (number), `HIGHEST_ALERT_SEVERITY` (Minor /
Moderate / Severe / Extreme / None), `LATEST_ALERT_NAME`,
`LATEST_ALERT_HEADLINE`.

Solar: `SUNRISE`, `SUNSET` (local HH:MM), `MINUTES_TO_SUNRISE`,
`MINUTES_TO_SUNSET`.

Health: `LAST_WEATHER_UPDATE`, `DATA_AGE_SECONDS`, `API_STATUS`
(Online/Unavailable), `LICENSE_STATUS`.

Grid-layer intelligence (from the NWS gridpoint forecast, fetched on the
forecast cadence; **blank means the layer carried no data for the window, never
zero**): `SNOWFALL_NEXT_24H_IN`, `RAIN_TOTAL_NEXT_24H_IN` (duration-weighted
accumulation sums, inches), `THUNDER_PROBABILITY_12H` (peak percent). A
grid-only fetch failure keeps last-good samples and never marks the core
forecast stale.

Trend and moon: `PRESSURE_TREND` (RISING / FALLING / STEADY from a 3-h
observation window; blank until ≥ 2 pressure samples span ≥ 90 min —
insufficient evidence is never "STEADY"), `MOON_PHASE` (eight common names from
mean-cycle math; a phase display, not an almanac).

Recommendations (booleans): `IRRIGATION_SKIP_RECOMMENDED`,
`SHADE_PROTECT_RECOMMENDED` — the same flags behind events 62–64, for
IF-condition checks at decision time.

## Conditionals (9)

For WHEN/IF logic without variable comparisons: `ATMOSPHERE_RAINING`,
`ATMOSPHERE_SNOWING`, `ATMOSPHERE_STORMING`, `ATMOSPHERE_FREEZING`,
`ATMOSPHERE_HIGH_WIND`, `ATMOSPHERE_ALERT_ACTIVE`, `ATMOSPHERE_DATA_STALE`,
`ATMOSPHERE_DAYTIME`, `ATMOSPHERE_SIMULATION`.

## Actions (Composer Actions tab, 20)

Refresh Weather / Refresh Forecast / Refresh Alerts / Refresh All · Rediscover
Location · Test Weather API · Test Alerts API · Test SmartBuildOS Licensing ·
Refresh License · Clear Cached Weather · Reinitialize Weather Services · Stop
Simulation · Print Diagnostics To Log · Open Weather App / Open Current Weather
/ Open Forecast / Open Radar / Open Alerts / Open Settings / Open Diagnostics
(deep-link the Navigator app to a screen from programming).

## Programming command (device command)

- **Start Simulation** — `SCENARIO` from a 16-item list (`clear`, `cloudy`,
  `rain`, `heavy_rain`, `thunderstorm`, `high_wind`, `dangerous_wind`, `freeze`,
  `extreme_heat`, `snow`, `fog`, `tornado_watch`, `tornado_warning`,
  `severe_thunderstorm_warning`, `flood_warning`, `hurricane_warning`).
  Simulated conditions run the identical engine path as live data; auto-stops
  after the configured timeout (default 30 min).

## Recipes

Test every recipe with **Start Simulation** before the weather does it for you —
a simulated `tornado_warning` fires the real `Tornado Warning` event, loudly
flagged as simulation everywhere.

**1. Irrigation skip** WHEN `Rain Expected Within 3 Hours` fires → set an
"irrigation hold" variable / disable the irrigation schedule. Optionally: at the
scheduled watering time, IF `ATMOSPHERE_RAINING` is true OR `RAIN_EXPECTED_SOON`
is `true` → skip the cycle. Re-enable on `Rain Stopped` plus a delay.

**2. Wind protection for shades and awnings** WHEN `High Wind Started` → retract
awnings, raise exterior shades. WHEN `High Wind Ended` → restore positions.
Hysteresis (25 mph in, 22 mph out by default) guarantees the pair never
chatters. For motorized pergolas or umbrellas, use `Dangerous Wind Started` (40
mph) or the momentary `High Gust Detected`.

**3. Freeze protection** WHEN `Freeze Expected` (fires in the evening when
tonight's forecast dips to freezing) → enable pipe-heat-trace relay, notify the
owner. WHEN `Freeze Conditions Ended` → restore. For pools: condition on
`CURRENT_TEMPERATURE_F` and run the pump on `Freeze Conditions Started`.

**4. Tornado response** WHEN `Tornado Warning` → close all shades, all lights to
100%, pause AV, Announcement: "A tornado warning is in effect for this area —
move to an interior room." WHEN `Alert Cleared` → restore lighting scene.
(Remember the safety note: 60 s alert polling over the internet is a convenience
layer, not a substitute for a weather radio.)

**5. Heavy-cloud lighting compensation** Every 15 minutes (or on a lighting
scene trigger), IF `ATMOSPHERE_DAYTIME` is true AND `CLOUD_COVER_PERCENT` > 70 →
raise interior daytime scene levels; ELSE restore. `WEATHER_MODE` = `CLOUDY`
works as a coarser test.

**6. Stale-data dealer notification** WHEN `Weather Data Stale` → push a
4Sight/notification to the dealer ("Atmosphere data stale at <client>"). WHEN
`Weather Data Restored` → push the all-clear. This is the health loop that
guarantees an API outage never silently looks like calm weather.
`Weather API Unavailable` / `Recovered` (three consecutive failures) is the
harder version.

**7. Fog: exterior visibility lighting** WHEN `Fog Started` → drive
path/driveway lighting to full, enable fog scene on landscape lighting. WHEN
`Fog Cleared` → return to schedule.

**8. Extreme-heat pre-cooling** WHEN `Extreme Heat Expected` (24 h lookahead) →
pre-cool overnight, drop west-facing shades at `MINUTES_TO_SUNSET` < 240. WHEN
`Extreme Heat Started` → hold shades, lock out heat-generating loads.

**9. Ice on the drive** WHEN `Ice Conditions Started` → enable driveway/gutter
melt, notify. WHEN `Ice Conditions Ended` → off after a timer.

**10. Storm-aware media room** WHEN `Thunderstorm Expected` → surge-sensitive
projector off at the end of the current session. WHEN `Severe Weather Detected`
→ pause outdoor audio, recall shades. WHEN `Severe Weather Ended` → resume.

**11. Sunrise/sunset without the Scheduler** `IS_DAYTIME`, `MINUTES_TO_SUNRISE`,
`MINUTES_TO_SUNSET` are computed locally (NOAA solar math — works offline). Use
them for conditionals in weather programming ("close shades on high wind only
during the day") without touching Scheduler entries.

**12. Sunset lighting scene** WHEN `Sunset Approaching` (30 minutes out) → run
the evening lighting scene, drop west-facing shades, switch landscape lighting
to its dusk program. WHEN `Sunrise Approaching` → the reverse. These fire from
the same local solar math as recipe 11, so they work with the internet down —
and unlike a Scheduler entry, they live next to the rest of the weather
programming.

**13. Irrigation skip, wired** The curated version of recipe 1. WHEN
`Irrigation Skip Recommended` → set the irrigation hold. WHEN
`Irrigation Skip Cleared` → release it. Or condition at watering time on
`IRRIGATION_SKIP_RECOMMENDED` = `true`. The flag asserts on rain falling, ≥ 0.25
in expected in 24 h (gridpoint QPF — actual amounts, not just PoP), or peak PoP
≥ 60%, and it clears itself: no delay timers to hand-tune.

**14. Shade protect, wired** The curated version of recipe 2. WHEN
`Shade Protection Recommended` → retract awnings, raise exterior shades. It
asserts on sustained wind ≥ 25 mph, gusts ≥ 30 mph, *or* forecast high wind — so
shades can come in before the front arrives, not after the first gust hits them.
There is no "cleared" event by design; restore on `High Wind Ended` or a timer,
when you know the hardware is safe.

## Properties for the app data plane

Two Composer properties back the Navigator app's LAN data channel (see
[WEBVIEW.md](WEBVIEW.md)): **App Relay Address** (`Auto` = discover the
controller's LAN IP from the project; set an IP manually when discovery fails)
and the read-only **App Data Relay** status line ("Listening :47815 — serving
http://… to the app", or what is wrong). They exist for troubleshooting, not
programming — no events or variables hang off them.
