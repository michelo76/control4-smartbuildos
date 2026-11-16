# Bond Color Light

One instance per full-color light on a Bond, such as Firefly bulbs and strips:
any Bond device that accepts a color. It makes the light a Control4 color
light in Navigator, with the level slider, the color wheel and the white
color-temperature picker.

It needs the Bond Bridge Gateway driver in the same project, connected to the
Bond that controls the light, and Control4 OS 3.3.0 or later (the driver uses
that release's color conversions). This driver does not talk to the Bond
itself: it gets the light's state from the Gateway and sends its commands
through it.

## Setup

<!-- walkthrough: Add a Bond color light -->
1. Set up the Bond Bridge Gateway first, until its **Connection Status** reads
   `Connected`.
1. Run the Gateway's *Auto Configure Bond Devices* action. For a device that
   accepts a color the Gateway picks this driver, not the plain Bond Light,
   then binds and names it. To do it by hand instead, add this driver and, in
   Connections, bind its **Bond Color Light** connection to the light's
   connection on the Gateway.
1. Check **Bond Device**: it shows the light's name. **Gateway Link** reads
   `OK - identified as` and the name.
1. Pick a color in Navigator. **Last Control** shows `SetHSV` and `ok` with
   the time, and **Color** follows, for example `hue 30, saturation 90%`.

## What works

| You do | The driver sends to the Bond |
| --- | --- |
| On | `TurnLightOn` |
| Off, or level 0 | `TurnLightOff` |
| Toggle | `ToggleLight` |
| A level from 1 to 100 | `SetBrightness` with that level |
| Pick a color on the wheel | `SetHSV` with hue and saturation only |
| Pick a white on the color-temperature picker | `SetColorTemp`, or white through `SetHSV` when the light has no color temperature |

How color maps:

- The color wheel sends hue and saturation. Brightness stays on the slider,
  so picking a color never changes the level.
- A color temperature is rounded to the nearest 100 K and kept inside the
  light's own range, which the Bond reports. A light whose range starts at
  2200 K, asked for 1500 K, is set to 2200 K. When the Bond reports no range,
  2000 K to 7000 K is used.
- A light for which the Bond does not list `SetColorTemp` is set to white
  instead (saturation 0).
- When the light is white and its color temperature is known, the driver
  reports color-temperature mode, so the Navigator picker opens on the right
  tab.

Feedback comes from the Gateway each time the Bond reports a change. **Light**
reads `On` or `Off`, **Brightness** the level, **Color** the hue and
saturation, and **Color Temperature** the Kelvin value when the Bond reports
one.

## Programming

- Events: *Light On*, *Light Off*, *Color Changed* (hue, saturation or color
  temperature moved). They fire on a change; the first state received after
  the driver starts sets the baseline and fires nothing.
- Conditional: `BOND_COLOR_LIGHT_ON`, shown as Light state, `On` or `Off`.
- Variables: `LIGHT_ON`, `LIGHT_BRIGHTNESS` (0 while off), `HUE`,
  `SATURATION`, `COLOR_TEMP`.
- The light device itself (the one in the room) has Control4's usual light
  commands.

| Command | Parameters | What it does |
| --- | --- | --- |
| `Set Color` | `Hue` 0 to 359, `Saturation` 0 to 100 | Sets the color. Leave one empty to change only the other. Brightness is not touched |
| `Set Color Temperature` | `Kelvin` | Sets a white, with the rounding and range described above |
| `Start Dimmer` | | Starts the Bond's hold-to-dim cycle for this light |
| `Stop Dimmer` | | Stops a dim cycle in progress |

Three keypad connections are in Connections: **Toggle Button Link**, **Light
On Link** and **Light Off Link**. A click on a bound keypad button acts. The
LEDs of buttons bound to the toggle and on links are lit while the light is
on; the LED on the off link is lit while it is off.

## Examples

**Warm white in the evening.** On your evening event, add `Set Color
Temperature` with `Kelvin` 2700, then set the level with the light's own
command. The two are separate on purpose: the color command leaves the level
alone.

**A red porch light as an alert.** On the alarm event, add `Set Color` with
`Hue` 0 and `Saturation` 100. To go back to white afterwards, use `Set Color
Temperature`, or `Set Color` with `Saturation` 0.

## Actions and troubleshooting

| Action | What it does |
| --- | --- |
| *Refresh From Gateway* | Asks the Gateway again which light this is and for its state |
| *Print Diagnostics To Log* | Gateway found or not, the light's identity, state, and whether color temperature is native or done through white |
| *Forget Device* | Clears what this instance remembers about its light and asks the Gateway again |

**Gateway Link** tells you where the link stands. `Not bound` means the **Bond
Color Light** connection is not bound. `Asked gateway at` a time, `waiting for
a reply`, means the connection is not bound or the Gateway has no device list
yet: run the Gateway's *Sync Devices Now*, then *Refresh From Gateway* here.
The driver asks again by itself every 60 seconds until it is answered.

**Last Control** reads `FAILED` with the Gateway's reason when a command did
not go through.

## Limits

- The state shown is what the Bond reports for the light. Where the light
  cannot report back, that is the Bond's own record of what it last sent.
- `COLOR_TEMP` and **Color Temperature** change only when the Bond reports a
  color temperature. On a light set to white through saturation 0 they keep
  their last value.
- `Start Dimmer` and `Stop Dimmer` are sent whether or not the Bond lists the
  action for this light. **Last Control** shows whether the Bond accepted it.
- The keypad links act on a click. Holding a bound button does not ramp the
  light.
- The driver names itself after the light only while it still has its default
  name or the name it gave itself. The Gateway's *Auto Rename Bound Drivers*
  renames it regardless.
