# Bond Shade

One instance per motorized shade, awning or screen on a Bond. It makes the
shade a normal Control4 shade in Navigator: open, close and stop, plus a
position slider when the Bond can send that shade to a position. A shade the
Bond can only open and close keeps the buttons and has no slider.

It needs the Bond Bridge Gateway driver in the same project, connected to the
Bond that controls the shade. This driver does not talk to the Bond itself: it
gets the shade's state from the Gateway and sends its commands through it.

## Setup

<!-- walkthrough: Add a Bond shade -->
1. Set up the Bond Bridge Gateway first, until its **Connection Status** reads
   `Connected`.
1. Run the Gateway's *Auto Configure Bond Devices* action. It adds this driver
   for each shade, binds it and names it after the shade. To do it by hand
   instead, add this driver and, in Connections, bind its **Bond Shade**
   connection to the shade's connection on the Gateway.
1. Check **Bond Device**: it shows the shade's name. **Gateway Link** reads
   `OK - identified as` and the name.
1. Open and close the shade from Navigator and watch it move. **Last Control**
   shows the action sent and `ok` with the time; **Position** follows.
1. Check the direction. Open and closed mean what they mean for this shade in
   the Bond Home app, awnings and top-down shades included. The Bond decides
   which way that is; the driver adds nothing on top.

## What works

| You do | The driver sends to the Bond |
| --- | --- |
| Open, or the slider to 100 | `Open` |
| Close, or the slider to 0 | `Close` |
| Stop | `Hold` |
| Toggle | `ToggleOpen` |
| The slider to a level in between | `SetPosition` |

**Levels.** Control4 counts 0 as closed and 100 as open. The Bond counts the
other way, so the driver converts: Control4 level 25 is sent as Bond position
75.

**Shades without positions.** The slider is offered only when the Bond lists
`SetPosition` for the shade; otherwise the driver tells Navigator the shade
has no level. If programming still asks such a shade for a level in between,
the driver sends `Preset` when the Bond lists it, and otherwise goes to the
nearer end (50 or more opens). The stop button is offered only when the Bond
lists `Hold`.

**Movement in Navigator.** When you open, close or set a level from Navigator
or a bound keypad, Navigator shows the shade travelling instead of jumping.
The time comes from the travel time the Bond holds for that shade, scaled by
the distance; when the Bond has none, 20 seconds for a full run is assumed, so
half a run animates for 10 seconds. When the position is unknown, no movement
is shown.

Feedback comes from the Gateway each time the Bond reports a change.
**Position** reads for example `75% open`, or `unknown (after Preset/Hold)`.

## Programming

- Events: *Opened*, *Closed*. They fire when the Bond's open or closed state
  changes; the first state received after the driver starts sets the baseline
  and fires nothing.
- Conditional: `BOND_SHADE_OPEN`, shown as Shade open state, `Open` or
  `Closed`.
- Variables: `SHADE_OPEN`, `SHADE_LEVEL` (percent open, -1 while the position
  is unknown).
- The shade device itself (the one in the room) has Control4's usual shade
  commands.

| Command | What it does |
| --- | --- |
| `Open` | Opens the shade |
| `Close` | Closes the shade |
| `Stop` | Stops the shade's motion (the Bond's `Hold`) |
| `Go To Preset` | Moves the shade to its preset (My or Favorite) position |

Four keypad connections are in Connections: **Toggle Button Link**, **Shade Up
Link**, **Shade Down Link** and **Shade Stop Link**. A click on a bound keypad
button acts.

## Examples

**Shades to their favorite position at sunset.** On your sunset event, add
this driver's `Go To Preset`. The preset is the shade's own My or Favorite
position. Afterwards **Position** reads unknown; see Limits.

**A keypad for one shade.** Bind three keypad buttons to **Shade Up Link**,
**Shade Stop Link** and **Shade Down Link**. Each press opens, stops or closes
the shade.

## Actions and troubleshooting

| Action | What it does |
| --- | --- |
| *Refresh From Gateway* | Asks the Gateway again which shade this is and for its state |
| *Print Diagnostics To Log* | Gateway found or not, the shade's identity, open or closed, level, positions supported or not |
| *Forget Device* | Clears what this instance remembers about its shade and asks the Gateway again |

**Gateway Link** tells you where the link stands. `Not bound` means the **Bond
Shade** connection is not bound. `Asked gateway at` a time, `waiting for a
reply`, means the connection is not bound or the Gateway has no device list
yet: run the Gateway's *Sync Devices Now*, then *Refresh From Gateway* here.
The driver asks again by itself every 60 seconds until it is answered.

**Last Control** reads `FAILED` with the Gateway's reason when a command did
not go through.

## Limits

- After `Go To Preset`, or a `Stop` in mid-travel, the Bond reports the
  position as unknown until the next full open or close. One-way RF gives it
  no way to know where the shade stopped. **Position** says so and
  `SHADE_LEVEL` reads -1; the driver does not guess.
- The position shown is the Bond's own tracking, not a reading from the motor.
  A move made with a remote the Bond does not know about is not seen.
- The movement shown in Navigator is a timed animation, not the motor's real
  progress.
- `Stop` and `Go To Preset` are sent whether or not the Bond lists the action
  for this shade. **Last Control** shows whether the Bond accepted it.
- No controls for tilt or for the separate rails of a top-down bottom-up
  shade.
- The driver names itself after the shade only while it still has its default
  name or the name it gave itself. The Gateway's *Auto Rename Bound Drivers*
  renames it regardless.
