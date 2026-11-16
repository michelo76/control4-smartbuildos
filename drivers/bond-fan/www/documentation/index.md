# Bond Fan

One instance per ceiling fan on a Bond. It makes the fan a normal Control4 fan
with speeds in Navigator, and adds direction, breeze mode and a turn-off timer
to programming. If the fan has a light, the light is a separate device served
by the Bond Light driver, not part of this one.

It needs the Bond Bridge Gateway driver in the same project, connected to the
Bond that controls the fan. This driver does not talk to the Bond itself: it
gets the fan's state from the Gateway and sends its commands through it.

## Setup

<!-- walkthrough: Add a Bond fan -->
1. Set up the Bond Bridge Gateway first, until its **Connection Status** reads
   `Connected`.
1. Run the Gateway's *Auto Configure Bond Devices* action. It adds this driver
   for each fan the Bond has, binds it and names it after the fan. To do it by
   hand instead, add this driver and, in Connections, bind its **Bond Fan**
   connection to the fan's connection on the Gateway.
1. Check **Bond Device**: it shows the fan's name. **Gateway Link** reads
   `OK - identified as` and the name.
1. Change the speed in Navigator. **Last Control** shows the action sent and
   `ok` with the time, and **Speed** follows.

## What works

| You do | The driver sends to the Bond |
| --- | --- |
| On | `TurnOn`. The Bond restores the fan's own last speed |
| Off | `TurnOff` |
| Toggle | `TogglePower` |
| Pick a speed | `SetSpeed` with that speed; speed 0 sends `TurnOff` |
| Speed up | `IncreaseSpeed` by 1 |
| Speed down | `DecreaseSpeed` by 1; at speed 1 it sends `TurnOff` |

Navigator offers six speed steps. The driver reads the fan's real top speed
from the Bond and caps what it sends: on a four-speed fan, picking 6 sets
speed 4. When the Bond gives no top speed, 6 is used.

Feedback comes from the Gateway each time the Bond reports a change, including
one made on the fan's own remote when the Gateway's push updates are
delivering. **Fan** reads `On` or `Off`, **Speed** reads for example `3 of 6`
(0 while the fan is off), and **Direction** reads `forward` or `reverse` when
the Bond reports a direction.

## Programming

- Events: *Fan On*, *Fan Off*, *Speed Changed*. They fire on a change; the
  first state received after the driver starts sets the baseline and fires
  nothing.
- Conditional: `BOND_FAN_ON`, shown as Fan power state, `On` or `Off`.
- Variables: `FAN_ON`, `FAN_SPEED` (0 while off), `FAN_DIRECTION` (`FORWARD`
  or `REVERSE`).
- The fan device itself (the one in the room) has Control4's usual fan
  commands.

| Command | Parameter | What it does |
| --- | --- | --- |
| `Set Direction` | `Direction` | `reverse` sets reverse; anything else sets forward |
| `Toggle Direction` | | Reverses the direction |
| `Breeze On` | | Turns on the fan's natural breeze mode |
| `Breeze Off` | | Turns breeze mode off; the fan stays at its current speed |
| `Set Timer` | `Seconds` | Turns the fan off after that many seconds; 0 cancels |

Three keypad connections are in Connections: **Toggle Button Link**, **Fan
Speed Up Link** and **Fan Speed Down Link**. A click on a bound keypad button
acts; the LED of a button bound to **Toggle Button Link** follows the fan's
power.

## Examples

**A fan that turns itself off.** On the bedroom's goodnight event, add this
driver's `Set Timer` with `Seconds` 3600. The fan runs for an hour and stops.

**Reversing with the season.** In your seasonal programming, add `Set
Direction` with `Direction` `reverse` when the season turns and `forward` when
it turns back. Direction is not on the Navigator fan, so programming is where
it lives.

**A keypad button for the fan.** Bind a keypad button to **Toggle Button
Link**. A press toggles the fan and the button's LED shows whether it is on.

## Actions and troubleshooting

| Action | What it does |
| --- | --- |
| *Refresh From Gateway* | Asks the Gateway again which fan this is and for its state |
| *Print Diagnostics To Log* | Gateway found or not, the fan's identity, power, speed and top speed |
| *Forget Device* | Clears what this instance remembers about its fan and asks the Gateway again |

**Gateway Link** tells you where the link stands. `Not bound` means the **Bond
Fan** connection is not bound. `Asked gateway at` a time, `waiting for a
reply`, means the connection is not bound or the Gateway has no device list
yet: run the Gateway's *Sync Devices Now*, then *Refresh From Gateway* here.
The driver asks again by itself every 60 seconds until it is answered.

**Last Control** reads `FAILED` with the Gateway's reason when a command did
not go through.

## Limits

- The state shown is the Bond's own record of what it last transmitted. Most
  fans are one-way RF and report nothing back, so a change the Bond does not
  know about (a wall switch, a remote it has not learned) leaves the state
  wrong until the next command.
- Direction, breeze and the timer are sent whether or not the Bond lists that
  action for this fan. **Last Control** shows whether the Bond accepted it.
- Navigator has no reverse button and no preset speed for this fan. A fan
  with more than six speeds cannot be set above 6 from Navigator.
- Breeze mode is on or off here. Its strength and variability are not
  settable from this driver.
- The driver names itself after the fan only while it still has its default
  name or the name it gave itself. The Gateway's *Auto Rename Bound Drivers*
  renames it regardless.
