# Bond Fireplace

One instance per fireplace on a Bond. It puts the fireplace in Navigator as
five tiles in the Comfort category: power, flame level, flame up, flame down
and the fireplace's own fan. Each tile's icon shows the current state. If the
fireplace has a light, the light is a separate device served by the Bond Light
driver.

It needs the Bond Bridge Gateway driver in the same project, connected to the
Bond that controls the fireplace. This driver does not talk to the Bond
itself: it gets the fireplace's state from the Gateway and sends its commands
through it.

## Setup

<!-- walkthrough: Add a Bond fireplace -->
1. Set up the Bond Bridge Gateway first, until its **Connection Status** reads
   `Connected`.
1. Run the Gateway's *Auto Configure Bond Devices* action. It adds this driver
   for each fireplace, binds it and names it after the fireplace.
   To do it by hand instead, add this driver and, in Connections, bind its
   **Bond Fireplace** connection to the fireplace's connection on the Gateway.
1. Check **Bond Device**: it shows the fireplace's name. **Gateway Link**
   reads `OK - identified as` and the name.
1. Tap the power tile with the fireplace in view. **Last Control** shows
   `TogglePower` and `ok` with the time, and **Fireplace** reads `On`.
1. Hide the tiles this fireplace has no use for (no flame level, no fan), per
   room, in Composer. The driver cannot remove them.

## What works

| Tile | A tap sends | Icon shows |
| --- | --- | --- |
| Power (carries the fireplace's name) | `TogglePower` | `On` or `Off` |
| Flame Level | The next stop: 33, 66, 100 (`SetFlame`), then off (`TurnOff`) | `Off`, `Low`, `Medium` or `High` |
| Flame Up | `IncreaseFlame` by 20 | |
| Flame Down | `DecreaseFlame` by 20 | |
| Fireplace Fan | The next stop: 33, 66, 100 (`SetFpFan`), then off (`TurnFpFanOff`) | `Off`, `Low`, `Medium` or `High` |

The flame and fan icons read `Low` up to 40 percent, `Medium` up to 75 and
`High` above. While the fireplace is off the flame tile shows `Off`, even
though the Bond remembers the last level.

A tile whose feature the fireplace lacks answers a tap with a line in the log
and sends nothing: Flame Level without `SetFlame`, Flame Down without
`DecreaseFlame`, Fireplace Fan without `SetFpFan`. Flame Up without
`IncreaseFlame` acts like a tap on Flame Level.

Feedback comes from the Gateway each time the Bond reports a change.
**Fireplace** reads `On` or `Off`; **Flame** and **Fireplace Fan** read a
percentage or `Off`.

## Programming

- Events: *Fireplace On*, *Fireplace Off*, *Flame Changed*. They fire on a
  change; the first state received after the driver starts sets the baseline
  and fires nothing.
- Conditional: `BOND_FIREPLACE_ON`, shown as Fireplace flame state, `On` or
  `Off`.
- Variables: `FIREPLACE_ON`, `FLAME_LEVEL` (0 while off),
  `FIREPLACE_FAN_SPEED` (0 while the fan is off).

| Command | Parameter | What it does |
| --- | --- | --- |
| `Turn On` | | Turns the fireplace on |
| `Turn Off` | | Turns the fireplace off |
| `Set Flame` | `Level` | Sets the flame to 1 to 100 percent. A value below 1 is ignored; use `Turn Off` |
| `Set Fireplace Fan` | `Speed` | Sets the fireplace's fan to that percent; 0 turns the fan off |
| `Set Timer` | `Seconds` | Turns the fireplace off after that many seconds; 0 cancels |

Three keypad connections are in Connections: **Toggle Button Link**, **Flame
Up Link** and **Flame Down Link**. A click on a bound keypad button does what
the matching tile does; the LED of a button bound to **Toggle Button Link**
follows the fireplace's power.

## Examples

**A fireplace that cannot be left on.** In the programming that lights it, add
`Turn On` and then `Set Timer` with `Seconds` 7200. Two hours later the
fireplace turns off. On your goodnight and away events, add `Turn Off` inside
the conditional `BOND_FIREPLACE_ON`, so the Bond transmits only when its
record says the fireplace is on.

**A set flame for the evening scene.** Add `Set Flame` with `Level` 66. The
flame tile then shows `Medium`.

## Actions and troubleshooting

| Action | What it does |
| --- | --- |
| *Refresh From Gateway* | Asks the Gateway again which fireplace this is and for its state |
| *Print Diagnostics To Log* | Gateway found or not, the fireplace's identity, power, flame, fan |
| *Forget Device* | Clears what this instance remembers about its fireplace and asks the Gateway again |

**Gateway Link** tells you where the link stands. `Not bound` means the **Bond
Fireplace** connection is not bound. `Asked gateway at` a time, `waiting for a
reply`, means the connection is not bound or the Gateway has no device list
yet: run the Gateway's *Sync Devices Now*, then *Refresh From Gateway* here.
The driver asks again by itself every 60 seconds until it is answered.

**Last Control** reads `FAILED` with the Gateway's reason when a command did
not go through.

## Safety and limits

- The Bond transmits the same RF codes as the fireplace's factory remote. The
  state shown is the Bond's own record of what it sent, not a flame sensor.
  Program a fireplace with the same care as any RF fireplace remote: timers
  and occupancy conditions are the installer's responsibility.
- A change made with a remote the Bond does not know about is not seen, and
  leaves the state wrong until the next command.
- `Set Timer` and `Set Fireplace Fan` are sent whether or not the Bond lists
  the action for this fireplace. **Last Control** shows whether the Bond
  accepted it.
- The five tiles are fixed. Unused ones can be hidden, not removed.
- When the driver names itself after the fireplace it renames only the power
  tile; the other four keep their function names. The Gateway's *Auto Rename
  Bound Drivers* renames the driver regardless of a name you gave it.
