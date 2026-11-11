# SmartBuildOS Atmosphere

Atmosphere brings the US National Weather Service (NWS) into Control4
programming. It reads the observations, the forecast and the official alerts
for the project's location and turns them into things a house can act on: it
is raining, rain is expected within three hours, a freeze is expected tonight,
the wind endangers the awnings, a tornado warning is in effect. Programming
gets an event at each change, conditionals and variables for the state at any
moment, and an outdoor temperature and humidity for the thermostats. Every
Navigator gets a weather app with current conditions, the hourly and daily
forecast, radar and alerts.

It needs Control4 OS 3.2.0 or newer, a location in the United States or its
territories (NWS covers nothing else, and the driver says so instead of
guessing), and internet access from the controller to `api.weather.gov`.
There is no API key, no account and no cost per request. The app's radar is
loaded by the touchscreen or phone itself, from `radar.weather.gov` and
`mapservices.weather.noaa.gov`.

Licensing is through the SmartBuildOS Agent (`smartbuildos.c4z`, SKU
`SBOS_ATMOSPHERE`); **License Status** shows this driver's standing. The
weather side never waits for a licence answer: observations, forecast, alerts,
events and variables run the same in every licence state, and with no Agent in
the project **License Status** reads `No SmartBuildOS Agent Found` while the
weather keeps working. With an Agent the driver also accepts settings sent
through the Agent, passes its four data-health events to it, and publishes its
state so the app can be read away from home.

## Why not a rain or wind sensor

A rain sensor or an anemometer wired to the controller reports what is
happening on this roof, this second. Atmosphere has no sensor. Its current
conditions are the latest report of a nearby NWS station, read every five
minutes, so "raining" means raining at the station.

What a sensor cannot give is what this driver is for:

- **What is coming.** Rain within one, three or six hours, a freeze tonight,
  high wind on the way, each as an event before it happens.
- **Official alerts.** Watches and warnings for the property's forecast zone,
  each announced once.
- **No hardware.** One driver, the same programming on every job, and a
  simulation to test it on a fine day.

Keep the sensor where the reaction must be local and immediate, such as an
awning that has to come in on the first gust. Atmosphere is not a life-safety
system (see [What is not claimed](#what-is-not-claimed)).

## What it is for

| You want | Use |
| --- | --- |
| Irrigation skipped when it is raining or rain is likely | *Irrigation Skip Recommended* and *Irrigation Skip Cleared*, or `IRRIGATION_SKIP_RECOMMENDED` at watering time |
| Awnings and exterior shades in before the wind reaches them | *Shade Protection Recommended*, *High Wind Started* and *High Wind Ended* |
| Pipes, a pool or a driveway protected from frost | *Freeze Expected*, *Freeze Conditions Started* and *Freeze Conditions Ended* |
| The house to react to an official warning | *Tornado Warning*, *Severe Thunderstorm Warning*, *Flash Flood Warning*, *Hurricane Warning* and the others; *Severe Weather Detected* for any warning |
| A scene or a motion light that behaves differently in rain, wind or frost | The conditionals *Raining*, *High wind* and *Freezing*, or `WEATHER_MODE` |
| Path lights up in fog | *Fog Started* and *Fog Cleared* |
| An outdoor temperature on a thermostat that has no outdoor sensor | The **Outdoor Temperature** and **Outdoor Humidity** connections |
| To be told when the weather feed stops | *Weather Data Stale* and *Weather Data Restored* |
| To test all of this on a fine day | `Start Simulation` |
| A weather screen for the homeowner | The Atmosphere tile on every Navigator |

## Setup

<!-- walkthrough: Set up Atmosphere -->
1. Install and pair the SmartBuildOS Agent.
1. Add `smartbuildos-atmosphere.c4z` with Driver > Add or Update Driver, then
   add SmartBuildOS Atmosphere to the project, once. **Driver Status** reads
   `Online` and **Driver Version** shows a version instead of `unknown` (the
   property exists for exactly this check).
1. Check the location. With a location set in the project,
   **Resolved Location**, **Forecast Office** and **Observation Station** fill
   in within a minute. If **Resolved Location** stays not resolved, set
   **Location Source** to Manual Coordinates and type **Latitude** and
   **Longitude** in decimal degrees (west is negative).
1. Read **Weather Status**: a temperature and a condition, such as
   `86.0°F Partly Cloudy`. **Data Freshness** reads something like
   `obs 3m ago`.
1. Open the Atmosphere tile on a Navigator, then read **App Data Relay**. It
   should say `Listening :47815`, then
   `serving http://<controller>:47815 to the app` with the controller's own
   address in it. If the address belongs to another device, or the line says
   the address is unknown, type the controller's address into
   **App Relay Address**, then close and reopen the tile.
1. Optional: in Connections, bind **Outdoor Temperature** and
   **Outdoor Humidity** to a thermostat. Atmosphere becomes its outdoor
   sensor.
1. Set the thresholds in the app's **Settings** screen (units, thresholds,
   alert filters, radar, themes and simulation all live there; the Composer
   properties stay few on purpose), then test your programming with a
   [simulation](#simulation).

**Location.** Control4 Project reads the latitude and longitude of the
project's location, and reads them again when the controller reports that the
location changed. Manual Coordinates uses the two properties. After any change
of location press *Clear Cached Weather*: the forecast and the alerts move to
the new place at once, but the driver keeps its old observation station until
that station stops answering or the cache is cleared.

**The controller's address.** With **App Relay Address** on `Auto`, the driver
goes through the Control4 devices in the project and takes the first network
address one of them reports. On a project with other Control4 devices on the
network that can be the wrong device, which is why step 5 asks you to look. An
address you type always wins.

**Thermostats.** The driver sends the temperature (Celsius and Fahrenheit) and
the humidity each time it works the weather out. When it has no observation,
or the observation is stale, it reports the value as unavailable, so a
thermostat never shows an old reading as current.

## Where the data comes from

| What | Source | Asked | Stale after |
| --- | --- | --- | --- |
| Current conditions | The latest observation of an NWS station near the property | Every 5 minutes | 30 minutes without an answer |
| Forecast: daily, hourly, rain and snow amounts, thunder probability | The NWS forecast for the property's grid square | Every 15 minutes | 3 hours without an answer |
| Alerts | The NWS active alerts for the property's forecast zone | Every 60 seconds | 5 minutes without an answer |
| Forecast office, grid, zone and station list | An NWS lookup of the coordinates | At start, on a location change, then every 24 hours | |
| Sunrise, sunset and moon phase | Worked out in the driver from the coordinates | Every minute | Never: no internet needed |

Every minute, and each time an answer arrives, the driver works everything out
again: conditions, events, variables, properties, the thermostat values and
the app.

**The station.** NWS returns a list of stations for the grid square. The
driver takes the first whose latest observation is under 90 minutes old,
trying up to four, and names it in **Observation Station**. After three failed
requests in a row it chooses again. A station can leave readings out, and
readings NWS has flagged as bad are dropped: a missing reading stays blank in
the variables and the app. It is never shown as 0.

**What leaves the house.** The requests to `api.weather.gov` carry the
property's coordinates rounded to four decimals, then the grid square, zone
and station NWS gave back for them, and name this driver and its version.
With a paired Agent the app's state, which includes the location, is also
published to SmartBuildOS.

## How events fire

Events mark changes. Nothing fires because a condition holds; it fires when
the condition starts or ends.

### Conditions with a start and an end

Each of these starts at one figure and ends at another, so a reading hovering
at a threshold does not switch your programming back and forth. With the
defaults, wind moving between 23 and 24 mph fires nothing: high wind starts at
25 and ends at 22.

| Condition | Starts when | Ends when | Slider in the app |
| --- | --- | --- | --- |
| Freezing | Air temperature is 32°F or lower | 34°F or higher | Freeze below |
| Hot | Feels-like is 90°F or higher | 87°F or lower | Hot above |
| Extreme heat | Feels-like is 100°F or higher | 96°F or lower | Extreme heat above |
| High wind | Sustained wind is 25 mph or more | 22 mph or less | High wind above |
| Dangerous wind | Sustained wind is 40 mph or more | 35 mph or less | Dangerous wind above |
| High gust | A gust is 35 mph or more | 30 mph or less | High gust above |

Hot has no event, only the variable `IS_HOT`. Two things to know about the
sliders:

- **A slider moves the start only.** The end stays where the table shows; the
  app has no control for it. Keep the start on the far side of the end:
  Freeze below at 33 or lower, Hot above at 88 or higher, Extreme heat above
  at 97 or higher, High wind above at 23 or more, Dangerous wind above at 36
  or more, High gust above at 31 or more. With the start past the end, a
  reading between the two flips the condition every time the driver works the
  weather out, and the Started and Ended events fire in turn about once a
  minute.
- **Until a slider is moved, the driver uses the figures in this manual**,
  whatever the slider shows. Five sliders open on a different figure: Hot
  above shows 92, Dangerous wind above 45, Rain likely at 40, Rain soon
  window 2 and Storm soon window 3. Move a slider and the driver uses what it
  shows.

Rain, snow, thunderstorm, fog and ice have no threshold. They are read from
the station's report (its present-weather list, or words such as rain,
showers, drizzle, thunder, snow, fog, mist or sleet in its description), and
their events fire when that changes.

The first observation the driver ever sees sets these conditions without
firing anything: add the driver while it rains and *Rain Started* does not
fire. A reading the station leaves out changes nothing. For gusts that has a
side effect: once a gust of 35 mph has been seen, *High Gust Detected* cannot
fire again until the station reports a gust of 30 mph or less, and a report
with no gust figure does not count. For shades use
*Shade Protection Recommended*, which looks at each report on its own.

### Forecast events

Each of these fires once, when the forecast first shows the condition. Nothing
fires when it stops being true: read `RAIN_EXPECTED_SOON`, `FREEZE_EXPECTED`
or `STORM_EXPECTED` to ask whether it still holds.

| Event | Fires when |
| --- | --- |
| *Rain Expected Within 1 Hour*, *Rain Expected Within 3 Hours*, *Rain Expected Within 6 Hours* | An hour of the hourly forecast that starts within that time is rainy |
| *Rain Expected Soon* | The same, within the rain-soon window (3 hours) |
| *Heavy Rain Expected* | An hour within the rain-soon window has a chance of 70% or more |
| *Thunderstorm Expected* | An hour within 6 hours has thunder in its forecast text; or a severe thunderstorm alert is active |
| *Snow Expected* | An hour within 6 hours has snow in its forecast text; or a winter alert is active |
| *High Wind Expected* | An hour within 6 hours has a top wind at or above the high-wind start; or a high wind, hurricane or tropical storm alert is active |
| *Freeze Expected* | An hour between now and the next 08:00, at most 12 hours ahead, is at or below the freeze start; or a freeze alert is active |
| *Extreme Heat Expected* | An hour within 24 hours has a temperature at or above the extreme-heat start; or a heat alert is active |

A rainy hour is one with a chance of precipitation of 50% or more, or one
whose forecast text names rain, showers or drizzle. The text counts whatever
the chance: "Slight Chance Rain Showers" at 20% is a rainy hour. The forecast
has one-hour steps, so nothing here claims "within 30 minutes": the data
cannot support it.

The figures in the table are the defaults of these sliders in the app: Rain
likely at (50%), Heavy rain at (70%), Rain soon window (3 hours), Storm soon
window (6 hours, used for thunder and for snow), Wind lookahead (6 hours) and
Freeze lookahead (12 hours).

### Recommendations

- *Irrigation Skip Recommended* fires when the station reports rain, or the
  forecast puts 0.25 inch or more of rain in the next 24 hours, or any hour in
  the next 24 has a chance of 60% or more. *Irrigation Skip Cleared* fires
  when none of the three holds any longer.
- *Shade Protection Recommended* fires when sustained wind reaches 25 mph, a
  gust reaches 30 mph, or *High Wind Expected* holds. It has no "cleared"
  event; `SHADE_PROTECT_RECOMMENDED` goes back to false by itself.

The 0.25 inch, 60%, 25 mph and 30 mph are fixed. They do not follow the
sliders.

### Alerts

At each request the driver compares the list of alerts with the one it holds.
A new alert fires its events once, however long it stays in force. Its level
comes from its NWS name: warning, watch, advisory, or statement. A name with
none of those words is ranked by its NWS severity (Severe or Extreme as a
warning, Moderate as a watch, anything else as an advisory).

- *New Weather Warning*, *New Weather Watch* or *New Weather Advisory* fires
  for every new alert of that level. A statement fires nothing.
- A more specific event fires as well when the name matches. The first row
  that matches wins:

| The NWS name contains | A watch fires | A warning fires |
| --- | --- | --- |
| tornado | *Tornado Watch* | *Tornado Warning* |
| severe thunderstorm | *Severe Thunderstorm Watch* | *Severe Thunderstorm Warning* |
| hurricane, typhoon | *Hurricane Watch* | *Hurricane Warning* |
| tropical | *Tropical Storm Watch* | *Tropical Storm Warning* |
| flash flood | *Flood Watch* | *Flash Flood Warning* |
| flood | *Flood Watch* | *Flood Warning* |
| winter, blizzard, snow, ice storm, freezing | *Winter Storm Watch* | *Winter Storm Warning* |
| frost, freeze, cold, wind chill | | *Freeze Warning* |
| heat | | *Extreme Heat Warning* |
| wind, gale | | *High Wind Warning* |

- *Alert Escalated* fires when NWS replaces an alert the driver holds with a
  more severe one or a higher level.
- *Alert Cleared* fires when one or more alerts end: run out, cancelled, or no
  longer listed. It fires once per request, not once per alert.
- *Severe Weather Detected* fires when the first warning becomes active and
  *Severe Weather Ended* when the last one ends.

Test and exercise messages are ignored. The app's Settings choose which levels
and which kinds of alert count (all of them by default); an alert that is
filtered out fires nothing and is not counted. An alert already in force when
the driver is first added, or after *Clear Cached Weather*, fires its events
on the first request. If a request fails, the alerts the driver holds stay
active until their own end time: "no alerts" is only reported when NWS
actually answered.

### After a restart

The driver saves its conditions, its forecast flags and the active alerts, and
reads them back when the controller or the driver restarts. Rain that never
stopped does not fire *Rain Started* again, and an alert already announced is
not announced again. Two things do repeat:

- The driver starts with no data, so *Weather Data Stale* fires at once and
  *Weather Data Restored* follows when the first observation and the first
  alert list arrive, normally within a minute.
- The forecast events whose condition still holds fire again when the first
  forecast arrives: *Rain Expected Within 3 Hours* with rain still in the
  forecast, for example. The same happens when a forecast returns after being
  stale.

Write programming on those events so that running it twice does no harm.

## When NWS cannot be reached

- A failed request is tried again after 1, 2, 5, 10 and then every 15 minutes
  until an answer comes. Observations, forecast and alerts each keep their own
  count.
- The last good values stay in the variables. Once observations have gone 30
  minutes, or alerts 5 minutes, without an answer, **Weather Status** gains
  `(STALE)`, **Data Freshness** gains `- STALE`, `DATA_STALE` and the
  conditional *Weather data stale* turn true, and *Weather Data Stale* fires.
  The app shows a banner.
- Conditions hold: nothing starts or ends without a new observation. A
  forecast more than 3 hours old is no longer used, so the forecast flags drop
  to false without an event. Once the observations are stale the thermostat
  connections report unavailable.
- *Weather API Unavailable* fires after three failed observation requests in a
  row, or three failed alert requests. *Weather API Recovered* fires when both
  are answering again.
- Sunrise and sunset keep working: they need no internet.

To hear about an outage and not about every restart, put a delay of a few
minutes after *Weather Data Stale* and then test the conditional
*Weather data stale*.

## The app

The Atmosphere tile opens the weather app: Now, Hourly, Forecast, Radar,
Alerts, Details and Settings. Settings holds General (display name, opening
screen), Units, Thresholds, Alerts, Radar, Display, Simulation, License,
Diagnostics and About. Units change what the app shows; the variables always
use the unit in their name.

The app gets its data over three channels, automatically: the Navigator API,
the driver's LAN relay on controller port 47815 (keep it reachable from
touchscreens and phones on the LAN), and, when the SmartBuildOS Agent is
paired, a read-only cloud copy for use away from home. Viewing works on
cellular; changing settings and running a simulation need the home network.
The relay hands out data and takes changes only for requests that carry the
token the driver puts in the tile's address. The app's waiting screen names
the channel it is trying if data does not arrive.

The Radar screen has two modes. **Interactive** has panning, span presets from
city to region, animation, official warning polygons, and hurricane cones when
a storm's cone touches the view. **Classic** shows the NWS station and
national loops. Interactive falls back to Classic by itself if the NOAA map
services are unavailable.

## Simulation

`Start Simulation` (a programming command, also in the app's Settings) replaces
the live observation and the live alerts with a scenario and runs it through
the same logic as real data. The same events fire, the variables and
conditionals change, and a thermostat bound to **Outdoor Temperature** shows
the simulated temperature. *Simulation Started* fires, **Simulation** reads
`Running:` and the scenario, **Weather Status** begins with `SIMULATION:`,
`SIMULATION_ACTIVE` and the conditional *Simulation mode* are true, and the
app shows a banner. The hourly forecast stays the real one.

| `SCENARIO` | What it sets |
| --- | --- |
| `clear`, `cloudy`, `fog` | 70°F and a 5 mph wind under a clear sky, an overcast one, or fog with 0.3 mile of visibility |
| `rain`, `heavy_rain` | Rain at the station; `heavy_rain` adds an 18 mph wind and 1.5 miles of visibility |
| `thunderstorm` | Rain and thunder, wind 22 mph, gusts 38 mph |
| `high_wind`, `dangerous_wind` | Wind 28 mph gusting 40; wind 45 mph gusting 60 |
| `freeze`, `extreme_heat`, `snow` | 28°F; 101°F feeling like 108; snow at 30°F |
| `tornado_watch` | A Tornado Watch on top of the live conditions |
| `tornado_warning`, `severe_thunderstorm_warning`, `flood_warning`, `hurricane_warning` | That warning, with storm conditions to match |

It stops by itself after 30 minutes, or when you press *Stop Simulation* on
the Actions tab or in the app. There is no programming command to stop it.
Stopping goes back to live data, and that change fires events too
(*Rain Stopped*, *High Wind Ended*, *Severe Weather Ended*,
*Simulation Ended*), so the "put it back" half of your programming is tested
as well.

- Everything programmed on those events really runs: shades move and
  announcements play.
- **Real alerts are set aside while a simulation runs.** An alert that begins
  during a simulation fires no event of its own, then or afterwards; if it is
  a warning, *Severe Weather Detected* fires when the simulation stops. If a
  real warning is active when you start, *Severe Weather Ended* fires at the
  start, unless the scenario is a warning itself. Keep simulations short and
  do not run one in bad weather.

## Sun times, and Solar Position

Atmosphere works out today's sunrise and sunset so that weather programming
can ask "is it day" without a second driver: `SUNRISE`, `SUNSET`,
`MINUTES_TO_SUNRISE`, `MINUTES_TO_SUNSET`, `IS_DAYTIME`, the conditional
*Daytime*, and *Sunrise Approaching* and *Sunset Approaching* 30 minutes
before each. It does not know where the sun is. SmartBuildOS Solar Position
does: it follows the sun's height and direction every minute, has an event at
sunrise and at sunset themselves, and knows which side of the house is in the
sun. For shades, glare and anything timed by the sun, use Solar Position.

"Today" is the controller's own calendar day, so the values are right in the
evening and the morning at any site: at 34°N 118°W on 21 June, with sunset at
20:06, `IS_DAYTIME` stays true until sunset and *Sunset Approaching* fires
at about 19:36.

## Worked examples

### Awnings in before the wind

<!-- walkthrough: Awnings in before the wind, tested today -->
1. In Programming, select Atmosphere and the event
   *Shade Protection Recommended*. Add the commands that retract the awnings
   and raise the exterior shades.
1. Select the event *High Wind Ended* and add the commands that put them
   back, if you want that done for you.
1. Test it. In the app open Settings, then Simulation, choose High wind and
   press Start simulation. (From programming, the same thing is the command
   `Start Simulation` with `SCENARIO` set to `high_wind`.)
1. Watch. **Weather Status** reads `SIMULATION: 70.0°F Windy`, **Simulation**
   reads `Running: high_wind`, and *High Wind Started* and
   *Shade Protection Recommended* fire. The awnings come in.
1. Press *Stop Simulation* on the Actions tab. *High Wind Ended* fires and
   the awnings go back.

In real weather *Shade Protection Recommended* also fires on a 30 mph gust, or
as soon as the forecast shows high wind within 6 hours, so the awnings can be
in before the front arrives. *High Wind Ended* fires only if the sustained
wind had reached 25 mph and has fallen to 22 or less. When the recommendation
came from a gust or from the forecast, nothing fires afterwards: put the
awnings back on a schedule or by hand, and test `SHADE_PROTECT_RECOMMENDED`
first.

### Irrigation that skips when rain makes it pointless

On the event that starts watering, add a conditional on this driver's variable
`IRRIGATION_SKIP_RECOMMENDED` and water only when it is false. Or hold and
release the irrigation controller on *Irrigation Skip Recommended* and
*Irrigation Skip Cleared*. The recommendation goes by amount (0.25 inch in the
next 24 hours) and by a 60% chance, which makes it a better test for watering
than *Rain Expected Within 3 Hours*, where the word "showers" in the forecast
is enough.

### Freeze protection

- *Freeze Expected*: heat trace on, and tell the owner. At 22:00 it looks as
  far as 08:00; at 14:00 it looks 12 hours ahead, to 02:00.
- *Freeze Conditions Started* (the station reads 32°F or lower): run the pool
  pump.
- *Freeze Conditions Ended* (34°F or higher): pump off.

There is no "no longer expected" event. Turn the heat trace off on
*Freeze Conditions Ended*, or in the morning after testing `FREEZE_EXPECTED`.

### A tornado warning

- *Tornado Warning*: close the shades, lights to full, pause the music and
  the video, make the announcement.
- *Severe Weather Ended*: put the house back. It fires when no warning of any
  kind is left.

Test it with the scenario `tornado_warning`. Besides *Tornado Warning*,
*New Weather Warning* and *Severe Weather Detected*, the storm it simulates
fires *Rain Started*, *Thunderstorm Started*, *High Wind Started* and
*Shade Protection Recommended*, so anything programmed on those runs too.
Read [What is not claimed](#what-is-not-claimed) before you promise this to a
client.

## Programming reference

**Events** (64).

- From the station's report: *Rain Started*, *Rain Stopped*, *Snow Started*,
  *Snow Stopped*, *Thunderstorm Started*, *Thunderstorm Ended*, *Fog Started*,
  *Fog Cleared*, *Ice Conditions Started*, *Ice Conditions Ended*,
  *Freeze Conditions Started*, *Freeze Conditions Ended*,
  *Extreme Heat Started*, *Extreme Heat Ended*, *High Wind Started*,
  *High Wind Ended*, *Dangerous Wind Started*, *Dangerous Wind Ended*,
  *High Gust Detected*.
- From the forecast: *Rain Expected Soon*, *Rain Expected Within 1 Hour*,
  *Rain Expected Within 3 Hours*, *Rain Expected Within 6 Hours*,
  *Heavy Rain Expected*, *Snow Expected*, *Thunderstorm Expected*,
  *High Wind Expected*, *Freeze Expected*, *Extreme Heat Expected*.
- From alerts: *New Weather Advisory*, *New Weather Watch*,
  *New Weather Warning*, *Alert Escalated*, *Alert Cleared*,
  *Severe Weather Detected*, *Severe Weather Ended*, and the sixteen named in
  the table under [Alerts](#alerts).
- Recommendations, sun and barometer: *Irrigation Skip Recommended*,
  *Irrigation Skip Cleared*, *Shade Protection Recommended*,
  *Sunset Approaching*, *Sunrise Approaching*, and *Barometer Falling Rapidly*
  (the pressure fell 0.10 inHg or more across the last three hours of
  observations; it needs at least 90 minutes of them).
- Health and simulation: *Weather Data Stale*, *Weather Data Restored*,
  *Weather API Unavailable*, *Weather API Recovered*, *Simulation Started*,
  *Simulation Ended*.

**Conditionals.** Each reads as one of two answers.

| Conditional | Answers |
| --- | --- |
| *Raining* | Raining / Dry |
| *Snowing* | Snowing / Not snowing |
| *Thunderstorm* | Thunderstorm / No thunderstorm |
| *Freezing* | Freezing / Above freezing |
| *High wind* | High wind / Calm |
| *Weather alert active* | Alert active / No alerts |
| *Weather data stale* | Stale / Fresh |
| *Daytime* | Day / Night |
| *Simulation mode* | Simulating / Live data |

**Variables** (50). A reading the station did not send is blank, and the
current readings are blank from a restart until the first observation.

| Variables | What they hold |
| --- | --- |
| `CURRENT_TEMPERATURE_F`, `CURRENT_TEMPERATURE_C`, `FEELS_LIKE_F`, `DEW_POINT_F`, `HUMIDITY_PERCENT` | The station's readings, to one decimal (humidity as a whole number) |
| `WIND_SPEED_MPH`, `WIND_GUST_MPH`, `WIND_DIRECTION` | Sustained wind, gust, and the direction as a compass point such as `SSW` |
| `PRESSURE_INHG`, `PRESSURE_TREND`, `VISIBILITY_MILES`, `CLOUD_COVER_PERCENT`, `CURRENT_CONDITION` | Pressure; `RISING`, `FALLING` or `STEADY` over three hours (blank until 90 minutes of readings exist); visibility; cloud cover; the station's description |
| `WEATHER_MODE` | One word for the weather now: `CLEAR`, `PARTLY_CLOUDY`, `CLOUDY`, `FOG`, `RAIN`, `HEAVY_RAIN`, `THUNDERSTORM`, `SEVERE_STORM`, `SNOW`, `ICE`, `HIGH_WIND`, `FREEZE`, `EXTREME_HEAT`, `TROPICAL`, `HURRICANE` or `UNKNOWN` |
| `WEATHER_SEVERITY` | `NORMAL`; `INFORMATIONAL` (a statement, dangerous wind or extreme heat); `ADVISORY`; `WATCH`; `WARNING`; `EMERGENCY` (a warning NWS rates Extreme) |
| `IS_RAINING`, `IS_SNOWING`, `IS_STORMING`, `IS_FOGGY`, `IS_FREEZING`, `IS_HOT`, `IS_HIGH_WIND` | The conditions, true or false |
| `RAIN_PROBABILITY`, `FORECAST_HIGH_F`, `FORECAST_LOW_F`, `FORECAST_CONDITION` | The chance of precipitation in the first hour of the hourly forecast; the next daytime period's high and description; the next night's low |
| `RAIN_TOTAL_NEXT_24H_IN`, `SNOWFALL_NEXT_24H_IN`, `THUNDER_PROBABILITY_12H` | Forecast rain and snow for the next 24 hours in inches, and the highest thunder probability in the next 12 hours. Blank means no data, not none expected |
| `RAIN_EXPECTED_SOON`, `FREEZE_EXPECTED`, `STORM_EXPECTED` | Whether *Rain Expected Soon*, *Freeze Expected* and *Thunderstorm Expected* hold now |
| `IRRIGATION_SKIP_RECOMMENDED`, `SHADE_PROTECT_RECOMMENDED` | The two recommendations, true or false |
| `ACTIVE_ALERT_COUNT`, `HIGHEST_ALERT_SEVERITY`, `LATEST_ALERT_NAME`, `LATEST_ALERT_HEADLINE` | The number of active alerts; the highest NWS severity among them (`None`, `Minor`, `Moderate`, `Severe`, `Extreme`); the name and headline of the most severe one, the newest among equals |
| `SUNRISE`, `SUNSET`, `MINUTES_TO_SUNRISE`, `MINUTES_TO_SUNSET`, `IS_DAYTIME`, `MOON_PHASE` | Local HH:MM, minutes to the next of each, day or night, and the moon's phase by name |
| `LAST_WEATHER_UPDATE`, `DATA_AGE_SECONDS`, `DATA_STALE`, `API_STATUS` | When the last observation was received and how long ago; stale or not; `Online` or `Unavailable` |
| `LICENSE_STATUS`, `SIMULATION_ACTIVE` | The licence state as the Agent names it; whether a simulation is running |

**Command.** `Start Simulation`, with one parameter, `SCENARIO`: the list
under [Simulation](#simulation).

## Properties

| Property | Meaning |
| --- | --- |
| **Driver Status**, **Driver Version** | `Online` once started; the installed version |
| **Weather Status** | Current temperature and condition; flags `SIMULATION:` and `(STALE)` |
| **Data Freshness** | Minutes since the last observation was received |
| **Active Alerts** | `None`, or the count and the most severe alert, such as `2 active - highest: Tornado Warning (Extreme)` |
| **Simulation** | `Off`, or `Running:` and the scenario |
| **Location Source** | Control4 Project (default) or Manual Coordinates |
| **Latitude**, **Longitude** | Used only with Manual Coordinates |
| **Resolved Location** | What the driver is actually using |
| **Forecast Office**, **Observation Station** | What NWS returned for the location |
| **App Relay Address** | `Auto`, or the controller's LAN address typed by hand |
| **App Data Relay** | Live status of the app's data connection |
| **License Status**, **License Source**, **Subscription Tier**, **SmartBuildOS Company** | Licensing, as the Agent reports it |
| **Log Level**, **Log Mode** | Logging; the actions below print without them |

## Actions

| Action | What it does |
| --- | --- |
| Refresh Weather, Refresh Forecast, Refresh Alerts, Refresh All | Asks NWS now instead of waiting |
| Rediscover Location | Reads the coordinates again and looks the office, grid and zone up again |
| Test Weather API, Test Alerts API | Asks NWS once and prints `OK` or `FAILED` with the HTTP code in the Lua tab |
| Clear Cached Weather | Forgets the station, the forecast, the alerts and the saved conditions, then starts over. Active alerts and forecast events are announced again |
| Reinitialize Weather Services | Stops every timer, reads the location again and starts the requests again. Stop a simulation first: its automatic stop is cancelled too |
| Stop Simulation | Ends a simulation now |
| Print Diagnostics To Log | Prints the full picture in the Lua tab: location, office and zone, station, the last success and failure of each request with its HTTP code, alerts, staleness, simulation, licence and the app's address |
| Test SmartBuildOS Licensing, Refresh License | Asks the Agent again; the first also prints the result |
| Open Weather App | Publishes the app's address to the Navigators again |
| Open Current Weather, Open Forecast, Open Radar, Open Alerts, Open Settings, Open Diagnostics | Sets the screen the app opens on (Open Diagnostics picks Settings). A driver cannot open the app on a touchscreen, and a device that has used the app opens on the screen it showed last |

## Reading the status

| You see | It means | Do |
| --- | --- | --- |
| **Driver Status** begins `DRIVER DISABLED` | The controller's OS is older than 3.2.0 | Update the OS |
| **Driver Version** stays `unknown` | The driver did not start | Read **Driver Status**; add the driver again |
| **Resolved Location** says not resolved | No usable coordinates: the project has no location, or the manual latitude and longitude are missing or out of range | Set the project's location, or use Manual Coordinates |
| **Resolved Location** ends in `(unsupported)` | NWS has no forecast grid for these coordinates: the place is outside its coverage. **Weather Status** says `Location is outside NWS coverage (US only)` until its next update | Check the sign of the longitude. Outside the United States the driver has no data |
| **Weather Status** reads `No observation yet` | No station has answered yet | Wait a minute, then press *Test Weather API* |
| **Weather Status** ends in `(STALE)` | The controller cannot reach `api.weather.gov`, or NWS is down. Normal for under a minute after a restart | Check the controller's internet. *Test Weather API* and *Test Alerts API* print the HTTP code. It recovers by itself |
| A station shows but a reading is blank | The station did not send that reading | Nothing: blank means not reported, never zero |
| **Observation Station** changed | The station stopped answering and the driver chose again | Nothing |
| A Started and an Ended event fire in turn every minute | A slider's start is past the condition's end | See [Conditions with a start and an end](#conditions-with-a-start-and-an-end) |
| **App Data Relay** says the port is unavailable | Something else is listening on port 47815, such as a second Atmosphere | Keep one Atmosphere in the project |
| **App Data Relay** says the address is unknown, or the app's waiting screen says `No relay address received from driver` | No controller address was found | Type it into **App Relay Address**, then close and reopen the tile |
| The tile opens a blank page after a reboot | The driver publishes the app's address again 60 seconds after it starts | Wait a minute. If it stays blank press *Open Weather App*, then close and reopen the tile |
| The app shows READ-ONLY | It is reading the cloud copy | Nothing: on the home network it goes back by itself within 5 minutes |
| The app says some changes were refused by the driver | The driver did not accept a value. Of the app's unit choices it takes miles per hour for wind, and inches of mercury or hectopascals for pressure | Choose one of those |
| **License Status** is not a licence | `No SmartBuildOS Agent Found`, or the Agent is still being asked | Install and pair the Agent, then press *Refresh License*. The weather does not wait for it |

## What is not claimed

- **It is not a sensor.** Conditions are a nearby station's, read every five
  minutes. Rain on the house and rain at the station are different things.
- **Alerts are for the forecast zone**, asked for every 60 seconds over the
  internet. The driver depends on that connection, on NWS and on the
  controller. It is a convenience and automation layer: not a NOAA weather
  radio, and not a life-safety system.
- **United States only.** Elsewhere there is no data.
- **The forecast has one-hour steps.** No "within 30 minutes".
- **Sunrise and sunset are good to about a minute.** The moon's phase comes
  from the average lunar cycle and can be a day out; it is for display.
- **It sends no notifications of its own.** Program them on its events.
- **A simulation hides real alerts** while it runs.
- No bench record covers the thermostat connections against a real thermostat
  or the app away from home. Treat both as untested until you have seen them
  work on the job.
