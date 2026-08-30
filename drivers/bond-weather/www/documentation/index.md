# Bond Weather

One instance per Bond **Breeze** weather sensor (BWS-1000 and friends). Add it
with the Gateway's **Auto Configure Bond Devices** action, or bind its **Bond
Weather** connection to the Bond Bridge Gateway manually.

Measurements refresh on every gateway sync and arrive immediately over the
Bond's push protocol when a new reading lands.

## The outdoor sensor trick

Two provider connections in the Connections view:

- **Outdoor Temperature** (`TEMPERATURE_VALUE`)
- **Outdoor Humidity** (`HUMIDITY_VALUE`)

Bind either to a thermostat and the Breeze becomes the project's outdoor sensor
— the thermostat's outdoor display and humidity logic run off real on-site
measurements instead of an internet feed. When the Breeze goes quiet (No Data),
the connections report *unavailable* rather than holding a stale reading.

## Programming

- **Events** (transitions only, never spam): Rain Started/Stopped, Wind
  Triggered, Sun Triggered, Solar/Backup Battery Low/OK, Freeze Warning /
  Cleared, Data Lost / Restored.
- **Variables**: `TEMPERATURE_C`, `TEMPERATURE_F`, `HUMIDITY`, `WIND_SPEED_MS`,
  `RAIN_RATE_MMH`, `SUN_LEVEL`, `IS_RAINING`, `SOLAR_BATTERY`, `BACKUP_BATTERY`,
  `NO_DATA`.
- **Conditional**: Raining / Dry.

The classic programs write themselves: retract the awnings on Wind Triggered,
pause irrigation while `IS_RAINING`, close the shades on Sun Triggered, notify
on Backup Battery Low.

## Properties

Temperature (Fahrenheit or Celsius via **Display Units** — variables always
carry both), Humidity, Wind Speed (m/s), Rain (mm/h), Sun Level ("Dark" at
zero), both batteries with voltages, Sensor Status (idle / which trigger is
active, with unstable / no-data / freeze flags appended), and Last Measured.

## Notes

- The Breeze keeps running its own Bond-side automations (its wind/rain/sun
  event links to shades) regardless of Control4 — this driver adds Control4 to
  the audience.
- Wind gust levels and trigger thresholds are configured in the Bond Home app;
  Control4 hears the results.
