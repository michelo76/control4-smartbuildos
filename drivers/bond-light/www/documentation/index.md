# Bond Light

One instance per light on a Bond: the light kit of a ceiling fan, the light of
a fireplace, or a Bond light or dimmer on its own. It makes the light a normal
Control4 light in Navigator. Where the Bond can set a brightness for that
light it dims; where it cannot, the light behaves as a switch.

It needs the Bond Bridge Gateway driver in the same project, connected to the
Bond that controls the light. This driver does not talk to the Bond itself: it
gets the light's state from the Gateway and sends its commands through it. A
full-color light gets the Bond Color Light driver instead; the Gateway chooses.

## Setup

<!-- walkthrough: Add a Bond light -->
1. Set up the Bond Bridge Gateway first, until its **Connection Status** reads
   `Connected`.
1. Run the Gateway's *Auto Configure Bond Devices* action. It adds this driver
   for each light, binds it and names it. The light of a fan named Master Fan
   is named Master Fan Light. To do it by hand instead, add this driver and,
   in Connections, bind its **Bond Light** connection to the light's
   connection on the Gateway.
1. Check **Bond Device**: it shows the light's name. **Gateway Link** reads
   `OK - identified as` and the name.
1. Read **Brightness**. A percentage means the light dims. `not dimmable`
   means the Bond has no brightness control for it.
1. Switch the light in Navigator. **Last Control** shows the action sent and
   `ok` with the time.

## What works

| You do | The driver sends to the Bond |
| --- | --- |
| On | `TurnLightOn` |
| Off, or level 0 | `TurnLightOff` |
| Toggle | `ToggleLight` |
| A level from 1 to 100, on a light that dims | `SetBrightness` with that level |
| A level from 1 to 100, on a light that does not dim | `TurnLightOn` |

A light dims when the Bond lists `SetBrightness` among its actions. One that
does not is reported as 100 while on and 0 while off, so the Navigator slider
snaps to the ends and works as a switch. A ramp to a level is sent as that
level; the driver adds no fade of its own.

Feedback comes from the Gateway each time the Bond reports a change. **Light**
reads `On` or `Off`, and **Brightness** the level.

## Programming

- Events: *Light On*, *Light Off*. They fire on a change; the first state
  received after the driver starts sets the baseline and fires nothing.
- Conditional: `BOND_LIGHT_ON`, shown as Light state, `On` or `Off`.
- Variables: `LIGHT_ON`, `LIGHT_BRIGHTNESS` (0 while off).
- The light device itself (the one in the room) has Control4's usual light
  commands.

| Command | What it does |
| --- | --- |
| `Start Dimmer` | Starts the Bond's hold-to-dim cycle for this light |
| `Stop Dimmer` | Stops a dim cycle in progress |

Three keypad connections are in Connections: **Toggle Button Link**, **Light
On Link** and **Light Off Link**. A click on a bound keypad button acts. The
LEDs of buttons bound to the toggle and on links are lit while the light is
on; the LED on the off link is lit while it is off.

## Examples

**A keypad button for a fan's light.** Bind the button to **Toggle Button
Link**. A press toggles the light and the LED follows it, also when the light
is switched from Navigator.

**Press and hold to dim.** For a light the Bond dims by cycling, program the
keypad button's press event with `Start Dimmer` and its release event with
`Stop Dimmer`. The dim cycle runs while the button is held.

## Actions and troubleshooting

| Action | What it does |
| --- | --- |
| *Refresh From Gateway* | Asks the Gateway again which light this is and for its state |
| *Print Diagnostics To Log* | Gateway found or not, the light's identity, on or off, brightness, dimmable or not |
| *Forget Device* | Clears what this instance remembers about its light and asks the Gateway again |

**Gateway Link** tells you where the link stands. `Not bound` means the **Bond
Light** connection is not bound. `Asked gateway at` a time, `waiting for a
reply`, means the connection is not bound or the Gateway has no device list
yet: run the Gateway's *Sync Devices Now*, then *Refresh From Gateway* here.
The driver asks again by itself every 60 seconds until it is answered.

**Last Control** reads `FAILED` with the Gateway's reason when a command did
not go through.

## Limits

- The state shown is the Bond's own record of what it last transmitted. Most
  of these lights are one-way RF and report nothing back, so a change the Bond
  does not know about leaves the state wrong until the next command.
- An on/off-only light is never shown at a level in between: the RF remote it
  copies has no such thing.
- `Start Dimmer` and `Stop Dimmer` are sent whether or not the Bond lists the
  action for this light. **Last Control** shows whether the Bond accepted it.
- The keypad links act on a click. Holding a bound button does not ramp the
  light.
- A fan with separate up and down lights is one light here.
- The driver names itself after the light only while it still has its default
  name or the name it gave itself. The Gateway's *Auto Rename Bound Drivers*
  renames it regardless.
