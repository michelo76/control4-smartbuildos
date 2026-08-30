# Bond Heater

One instance per Bond heater with an adjustable heat level (Infratech and
similar behind a Bond Bridge Pro). Add it with the Gateway's **Auto Configure
Bond Devices** action, or bind its **Bond Heater** connection to the Bond Bridge
Gateway manually. Heaters that are on/off-only get the simpler **Bond Switch**
driver instead — the Gateway picks automatically.

## The Navigator face

A heat-only thermostat: the dial's setpoint **is the heat level, 0-100** — turn
the dial, the heater follows. The centre of the dial stays blank on purpose:
these heaters have no temperature sensor, and the driver does not invent
readings. Modes are **Off** and **Heat**.

The **Extras** tab carries the auto-off **Timer (in minutes)**. Heaters with a
factory fire-code cap keep it — the Bond clamps the timer to the cap and
restarts it on every state change; the driver surfaces this, never fights it.

## Connections

- **Toggle / Heat Up / Heat Down button links** for keypads (LED tracks power on
  the toggle link). Heat Down below one step turns the heater off.
- **Relay Control** — treat the heater as a relay in programming (CLOSE = on,
  OPEN = off).

## Programming

- **Turn On / Turn Off / Set Heat / Set Timer** commands.
- Events: **Heater On**, **Heater Off**, **Heat Level Changed**; variables
  `HEATER_ON`, `HEAT_LEVEL`, `TIMER_REMAINING`.

## Safety note

The Bond transmits the same RF codes the factory remote uses; state is the
Bond's own tracking, not a heat sensor. Program outdoor heaters with the same
care as the factory remote — the factory fire-code timer stays in force either
way.
