# Bond Switch

One instance per Bond device that is "just power": generic templates, smart
switches, heaters, bidets. Add it with the Gateway's **Auto Configure Bond
Devices** action, or bind its **Bond Switch** connection to the Bond Bridge
Gateway manually.

It appears in Navigator as a single tile with On/Off state icons — tap to
toggle. A **Relay Control** provider connection is also exposed so Composer
programming and integrations can treat the device as a relay (CLOSE = on, OPEN =
off).

## Programming

- **Turn On / Turn Off / Set Timer** commands.
- Events: **Turned On**, **Turned Off**; variable `SWITCH_ON`.
- Heater levels: use the Gateway's **Run Bond Action** command with `SetHeat`
  and a 1-100 argument until a dedicated heater driver ships.
