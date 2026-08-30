# Bond Fireplace

One instance per Bond fireplace. Add it with the Gateway's **Auto Configure Bond
Devices** action, or bind its **Bond Fireplace** connection to the Bond Bridge
Gateway manually.

It appears in Navigator as five tiles (Comfort category), each with live state
icons:

- **Power** — tap to toggle; icon lights amber while the flame is on.
- **Flame Level** — tap to cycle Low → Medium → High → Off; the flame icon grows
  with the level.
- **Flame Up / Flame Down** — one step at a time.
- **Fireplace Fan** — tap to cycle the fireplace's own fan (FpFan feature),
  independent of the flame.

Tiles for features the fireplace lacks (no flame level, no fan) answer taps with
a log line instead of doing something wrong. Hide unused tiles per room in
Composer.

If the fireplace has a light, the Gateway creates a separate **Bond Light**
connection for it.

## Programming

- **Turn On / Turn Off / Set Flame / Set Fireplace Fan / Set Timer** commands.
- Events: **Fireplace On**, **Fireplace Off**, **Flame Changed**; variables
  `FIREPLACE_ON`, `FLAME_LEVEL`, `FIREPLACE_FAN_SPEED`.

## Safety note

The Bond transmits the same RF codes the factory remote uses; state is the
Bond's own tracking, not a flame sensor. Program fireplaces with the same care
as any RF fireplace remote — timers and occupancy conditions are the installer's
responsibility.
