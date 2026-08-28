# UniFi Protect Sensor

One instance per Protect sensor, bound to the UniFi Protect Gateway (SBOS)
in the Connections view. No credentials live here.

- **Contact** and **Motion** CONTACT_SENSOR connections for Control4-native
  security programming (motion active = closed).
- Events: motion, contact open/close, water leak, tamper, battery low, audio
  alarm, button press, CO fault, online/offline, and configurable
  temperature/humidity threshold crossings.
- Variables: CONTACT_STATE, MOTION_DETECTED, TEMPERATURE, HUMIDITY,
  LIGHT_LEVEL, BATTERY, LAST_MOTION.
- Auto-names itself after the sensor; readings appear only for hardware the
  sensor actually has.
