# Bond Heater

One instance per heater on a Bond that has an adjustable heat level (Infratech
and similar, behind a Bond Bridge Pro). It puts the heater in Navigator as a
heat-only thermostat whose dial is the heat level from 0 to 100, with an
auto-off timer on the Extras tab. A heater that is only on and off gets the
simpler Bond Switch driver instead; the Gateway chooses.

It needs the Bond Bridge Gateway driver in the same project, connected to the
Bond that controls the heater. This driver does not talk to the Bond itself:
it gets the heater's state from the Gateway and sends its commands through
it.

## Setup

<!-- walkthrough: Add a Bond heater -->
1. Set up the Bond Bridge Gateway first, until its **Connection Status** reads
   `Connected`.
1. Run the Gateway's *Auto Configure Bond Devices* action. It adds this driver
   for each heater with a heat level, binds it and names it after the heater.
   To do it by hand instead, add this driver and, in Connections, bind its
   **Bond Heater** connection to the heater's connection on the Gateway.
1. Check **Bond Device**: it shows the heater's name. **Gateway Link** reads
   `OK - identified as` and the name.
1. Turn the dial in Navigator with the heater in view. **Last Control** shows
   `SetHeat` and `ok` with the time, and **Heat Level** follows.
1. Tell the homeowner what the dial is: a level, not a temperature.

## What works

The Navigator face is a thermostat with two modes, `Off` and `Heat`.

| You do | The driver sends to the Bond |
| --- | --- |
| Turn the dial to a level from 1 to 100 | `SetHeat` with that level |
| Turn the dial to 0 | `TurnOff` |
| Mode `Heat` | `TurnOn`. The Bond restores the last heat level |
| Mode `Off` | `TurnOff` |
| Set the timer on the Extras tab | `SetTimer` with that time in seconds |

- **The dial is the heat level, not degrees.** Its range is 0 to 100 and its
  scale is fixed, so the number means percent of heat.
- **The centre of the dial stays blank on purpose.** These heaters have no
  temperature sensor, and the driver does not invent a reading.
- **The dial keeps the remembered level while the heater is off**, because the
  Bond restores it at the next turn-on.
- **The Extras tab** carries Timer (in minutes), from 0 to 480 in steps of 5.

Feedback comes from the Gateway each time the Bond reports a change.
**Heater** reads `On` or `Off`, **Heat Level** a percentage, and **Timer** the
seconds remaining or `off`.

## Programming

- Events: *Heater On*, *Heater Off*, *Heat Level Changed*. They fire on a
  change; the first state received after the driver starts sets the baseline
  and fires nothing.
- Conditional: `BOND_HEATER_ON`, shown as Heater power state, `On` or `Off`.
- Variables: `HEATER_ON`, `HEAT_LEVEL` (the remembered level, also while
  off), `TIMER_REMAINING` (seconds).

| Command | Parameter | What it does |
| --- | --- | --- |
| `Turn On` | | Turns the heater on; the last heat level is restored |
| `Turn Off` | | Turns the heater off |
| `Set Heat` | `Level` | Sets the heat level, 1 to 100; 0 turns the heater off |
| `Set Timer` | `Seconds` | Turns the heater off after that many seconds; 0 cancels |

Connections:

- **Toggle Button Link**, **Heat Up Link**, **Heat Down Link**: for keypad
  buttons. A click acts. Heat up and heat down move the level by 10; heat
  down at level 10 or below turns the heater off. The LED of a button bound
  to the toggle link follows the heater's power.
- **Relay Control**: treats the heater as a relay. Closing it turns the
  heater on, opening it turns it off, and it reports closed while the heater
  is on.

## Examples

**A patio heater that cannot be left on.** In the programming that starts it,
add `Set Heat` with `Level` 60, then `Set Timer` with `Seconds` 3600. An hour
later the heater turns off. On your away and goodnight events, add `Turn Off`
inside the conditional `BOND_HEATER_ON`.

**Three keypad buttons.** Bind them to **Toggle Button Link**, **Heat Up
Link** and **Heat Down Link**. Each press of up or down moves the heat by 10,
and the toggle button's LED shows whether the heater is on.

## Actions and troubleshooting

| Action | What it does |
| --- | --- |
| *Refresh From Gateway* | Asks the Gateway again which heater this is and for its state |
| *Print Diagnostics To Log* | Gateway found or not, the heater's identity, power, heat level, timer |
| *Forget Device* | Clears what this instance remembers about its heater and asks the Gateway again |

**Gateway Link** tells you where the link stands. `Not bound` means the **Bond
Heater** connection is not bound. `Asked gateway at` a time, `waiting for a
reply`, means the connection is not bound or the Gateway has no device list
yet: run the Gateway's *Sync Devices Now*, then *Refresh From Gateway* here.
The driver asks again by itself every 60 seconds until it is answered.

**Last Control** reads `FAILED` with the Gateway's reason when a command did
not go through.

## Safety and limits

- The Bond transmits the same RF codes as the heater's factory remote. The
  state shown is the Bond's own record of what it sent, not a heat sensor.
  Program outdoor heaters with the same care as the factory remote.
- Heaters with a factory fire-code timer keep it. The Bond holds the timer to
  that cap and restarts it on every state change; the driver shows the timer
  and never overrides the cap.
- No temperature is reported, so nothing in Control4 can regulate these
  heaters to a temperature through this driver. It has no cooling, no
  schedule and no presets.
- A change made with a remote the Bond does not know about is not seen, and
  leaves the state wrong until the next command.
- The driver names itself after the heater only while it still has its
  default name or the name it gave itself. The Gateway's *Auto Rename Bound
  Drivers* renames it regardless.
