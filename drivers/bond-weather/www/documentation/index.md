# Bond Weather

One instance per Bond Breeze weather sensor (BWS-1000 and similar). It brings
the sensor's readings into Control4: temperature, humidity, wind speed, rain
rate and sun level as variables, an event when it starts or stops raining and
when the sensor's wind or sun trigger goes off, and two connections that hand
the outdoor temperature and humidity to a thermostat. It has no tile in
Navigator.

It needs the Bond Bridge Gateway driver in the same project, connected to the
Bond the sensor is paired with. This driver does not talk to the Bond itself:
readings arrive from the Gateway, at once when its push updates are
delivering and otherwise at its next poll that finds a change.

## Setup

<!-- walkthrough: Add a Breeze weather sensor -->
1. Set up the Bond Bridge Gateway first, until its **Connection Status** reads
   `Connected`.
1. Run the Gateway's *Auto Configure Bond Devices* action. It adds this driver
   for each weather sensor, binds it and names it after the sensor. To do it
   by hand instead, add this driver and, in Connections, bind its **Bond
   Weather** connection to the sensor's connection on the Gateway.
1. Check **Bond Device**: it shows the sensor's name. **Gateway Link** reads
   `OK - identified as` and the name.
1. Read **Temperature**, **Humidity** and **Last Measured** and compare them
   with the weather outside. Set **Display Units** to `Celsius` if you prefer;
   it changes only how **Temperature** is shown.
1. To give a thermostat the outdoor reading, bind **Outdoor Temperature** and
   **Outdoor Humidity** in Connections.

## What it reports

| Property | Shows | Example |
| --- | --- | --- |
| **Temperature** | In the unit chosen in **Display Units** | `70.2 F` |
| **Humidity** | Percent | `65%` |
| **Wind Speed** | Metres per second | `3.2 m/s` |
| **Rain** | Millimetres per hour | `4 mm/h` |
| **Sun Level** | The sensor's sun level; `Dark` at zero | `Dark` |
| **Solar Battery**, **Backup Battery** | Percent, with the voltage when the Bond gives it | `80% (2.4V)` |
| **Sensor Status** | The Bond's status word for the sensor | `idle` |
| **Last Measured** | Date and time of the sensor's last measurement | |

**Sensor Status** reads `idle`, or names the trigger that is active:
`triggered_wind`, `triggered_wind_manual`, `triggered_rain` or
`triggered_sun_high`. The driver adds `, NO DATA` while the sensor has gone
quiet and `, freeze warning` while its low-temperature flag is up.

**The outdoor sensor connections.** **Outdoor Temperature** and **Outdoor
Humidity** are value connections. Bound to a thermostat, or to anything else
that takes a temperature or humidity value, they pass each new reading on,
the temperature in both scales. While the sensor has no data they report
unavailable; the consumer is not left holding a stale reading.

## Programming

Events fire on a change only. The first state received after the driver
starts sets the baseline, so a restart does not announce again rain that
never stopped.

| Event | Fires when |
| --- | --- |
| *Rain Started*, *Rain Stopped* | The sensor's raining flag turns on, turns off |
| *Wind Triggered* | The sensor's status changes to a wind trigger |
| *Sun Triggered* | The sensor's status changes to the sun trigger |
| *Solar Battery Low*, *Solar Battery OK* | The solar battery's low flag turns on, turns off |
| *Backup Battery Low*, *Backup Battery OK* | The backup AA battery's low flag turns on, turns off |
| *Freeze Warning*, *Freeze Warning Cleared* | The low-temperature flag turns on, turns off |
| *Data Lost*, *Data Restored* | The no-data flag (no measurements for more than 30 minutes) turns on, turns off |

- Conditional: `BOND_WEATHER_RAINING`, shown as Raining, `Raining` or `Dry`.
- Variables: `TEMPERATURE_C` and `TEMPERATURE_F` (both always filled, one
  decimal), `HUMIDITY`, `WIND_SPEED_MS`, `RAIN_RATE_MMH`, `SUN_LEVEL`,
  `IS_RAINING`, `SOLAR_BATTERY`, `BACKUP_BATTERY`, `NO_DATA`.
- No commands: the driver only listens.

## Examples

**Awnings in when the wind picks up.** On *Wind Triggered*, add the command
that retracts the awnings. The wind level that trips it is the threshold set
for the sensor in the Bond Home app.

**No irrigation in the rain.** In the irrigation programming, put the start
inside the conditional `BOND_WEATHER_RAINING` set to `Dry`. For a rule on how
hard it rains, compare `RAIN_RATE_MMH`.

**A message when the sensor needs attention.** On *Backup Battery Low* and on
*Data Lost*, send a notification to whoever services the site.

## Actions and troubleshooting

| Action | What it does |
| --- | --- |
| *Refresh From Gateway* | Asks the Gateway again which sensor this is and for its state |
| *Print Diagnostics To Log* | Gateway found or not, the sensor's identity, temperature, humidity, status, raining, no data |
| *Forget Device* | Clears what this instance remembers about its sensor and asks the Gateway again |

**Gateway Link** tells you where the link stands. `Not bound` means the **Bond
Weather** connection is not bound. `Asked gateway at` a time, `waiting for a
reply`, means the connection is not bound or the Gateway has no device list
yet: run the Gateway's *Sync Devices Now*, then *Refresh From Gateway* here.
The driver asks again by itself every 60 seconds until it is answered.

Readings that stop changing: look at **Last Measured** and **Sensor Status**.
`NO DATA` means the Bond itself has heard nothing from the sensor.

## Limits

- The driver only listens. Whatever the sensor is set to do on the Bond side
  keeps happening, with or without Control4.
- Trigger thresholds for wind and sun are set in the Bond Home app. Control4
  hears the result, not the setting.
- There is no event for a wind or sun trigger ending; **Sensor Status** goes
  back to `idle`. *Rain Stopped* covers rain.
- Wind speed is in metres per second and rain in millimetres per hour only.
- **Last Control** is not used: this driver sends no commands.
- The driver names itself after the sensor only while it still has its
  default name or the name it gave itself. The Gateway's *Auto Rename Bound
  Drivers* renames it regardless.
