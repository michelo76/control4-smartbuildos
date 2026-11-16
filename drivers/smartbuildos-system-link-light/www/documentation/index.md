# SmartBuildOS System Link Light

This driver is a light in this project that stands in for a real light in
another Control4 project. The project that has the real dimmer or switch (the
owner) shares it across the link as an export. This driver sits on the receiving
side and presents that export as an ordinary Control4 light: it has a place in a
room, on the Navigators and in programming. It shows only what the owner's light
has reported, and every tap is sent to the owner as a request.

Do not confuse it with SmartBuildOS System Link Export Light. That driver goes
in the owner's project and shares a light. This one goes in the other project
and receives it.

## What it needs

- **SmartBuildOS System Link** in this project, linked to the owner's project
  and synchronised. This driver finds it by itself; its properties call it the
  bridge. It talks to nothing else.
- A `light` export made on the owner's project.
- No licence of its own. It runs under the System Link pair licence held by
  SmartBuildOS System Link, and lights are part of every pair licence.
- Control4 OS 3.3.2 or later.

## Setup

<!-- walkthrough: Add a linked light -->
1. On the owner's project, share the light. Either add SmartBuildOS System Link
   Export Light there and bind the light to it, or select SmartBuildOS System
   Link, set **Export Kind** to `light`, pick the light in **Export Device**,
   fill in **Export Name** and run *Export Selected Device*. Set
   **Export Control** to `Control allowed` if this project is to switch the
   light; `View only` shares its state and nothing more.
1. On this project, select SmartBuildOS System Link. **Pending Exports** lists
   the new export, for example `Porch_Light (light)`. Pick it in
   **Pending Export** and run *Add Companion For Pending Export*. This driver is
   added, linked to the export and named after it: `Porch_Light` becomes "Porch
   Light". *Auto Setup* does the same for every pending export in one go.
1. Or do it by hand: add this driver and pick the export in **Linked Export**.
   The list holds light exports only. One driver per export.
1. Check the Properties tab. **Bridge Link** reads `Connected to bridge`
   followed by a device number, **Freshness** reads `current`, and
   **Confirmed State** shows the light, for example `On 40%`.
1. Move the light to the room where it should appear.
1. On the Actions tab press *Test: Remote On*. **Last Result** goes from `sent`
   to `accepted` to `delivered`, and **Confirmed State** changes once the
   owner's light reports that it is on.

If *Add Companion For Pending Export* says the add failed, load this driver's
file onto the controller once with Driver > Add or Update Driver and run the
action again.

## What crosses the link

| Direction | What |
| --- | --- |
| Owner to here | On or off, and the level from 0 to 100 |
| Here to the owner | On, off, and a level with its ramp time |
| Not carried | Colour, presets and on-mode settings, click and hold rates, button events and LEDs, advanced lighting scenes |

The owner reads the light's `LIGHT_STATE` variable and its level variable
(`Brightness Percent`, `LIGHT_LEVEL` or `Current Light Level`, whichever the
device has), and publishes a change when one of them changes.

A command to this light never changes what it shows. The driver sends a request
and tells the light proxy that a change to the target is under way; the level it
reports as current stays the last one the owner confirmed. On the owner's side,
on and off become the light's own on and off commands, and a level becomes a
ramp to that level. A level of 0 is sent as off. A ramp time is passed on as
given; the owner refuses one longer than 60 seconds. Toggle is decided here: off
if the last confirmed state was on, otherwise on. Each request is sent once and
is never repeated. Preset, on-mode and colour edits made on this light are
accepted and ignored.

## Reading the status

| Property | What it tells you |
| --- | --- |
| **Bridge Link** | Whether SmartBuildOS System Link was found and answered. If the link carries no light export it says so and names what the link does carry |
| **Remote System State** | The link as a whole, as SmartBuildOS System Link sees it. `Ready` is the good state |
| **Freshness** | `current`: every value of the export is confirmed. `stale`: the link is not synchronised, or the owner has not confirmed the value for 15 minutes. `unknown`: nothing received yet. `unavailable`: the owner's device does not supply one of the values. While it is not `current` the driver reports the light as offline |
| **Control** | `control permitted` when the owner exported the light with control allowed and SmartBuildOS System Link here permits commands (not paused, licence in order); otherwise `view only / suspended` |
| **Control Window** | The owner's schedule for this export and whether it is open now, by the owner's clock, for example `Mon–Fri 07:00–22:00 (America/New_York) — closed now`. `none` when there is no schedule. While it is closed a command is refused here without being sent: **Last Result** reads `refused: outside the control window` with the schedule, and *Control Refused* fires |
| **Confirmed State** | What the owner's light last reported: `On 40%`, `Off 0%`, or `unavailable` |
| **Requested State** | The last request sent from here and when, for example `75% at 18:04:10` |
| **Last Result** | `sent`, then `accepted` (queued for the owner), then `delivered` (the owner sent it to the light) or `failed:` with the reason |

## Programming

The light itself is a standard Control4 light (the `light_v2` proxy), so it has
the usual light commands, events and conditionals in programming. On, off,
toggle, set level and ramp to level are all sent to the owner as described
above. The driver adds these of its own:

- Events: *Remote Light On* and *Remote Light Off* (the owner's light reported a
  change), *Remote Value Current* and *Remote Value Stale* (**Freshness** became
  `current` or stopped being `current`), *Control Refused* (a request was
  refused; **Last Result** has the reason).
- Conditional: *Remote Value Is Current*.
- Actions: *Test: Remote On*, *Test: Remote Off*, *Test: Remote 50%*,
  *Refresh From Bridge* (ask for the export list and state again),
  *Rename From Export* (name the device after the export even if you renamed
  it), *Print Diagnostics To Log*.

It has no variables and no commands of its own. The export's values are also
variables of SmartBuildOS System Link, named after the owner's alias and the
export: `<Alias>.Porch_Light_On` and `<Alias>.Porch_Light_Level`.

## Examples

### Tell someone the far light was left on

On *Remote Light On*, start a timer. When it expires, check
*Remote Value Is Current*, check that the light is still on, and send your
notification.

### Switch the far light and know whether it worked

Add the light's ordinary Off command to a Goodnight routine. On
*Control Refused*, notify: the request was turned down, and **Last Result** says
why, for example `failed: export is view-only`. `delivered` means the owner
passed the command to its light; the proof that it went off is
*Remote Light Off*.

## Limits

- The light shows confirmed state only. If the owner's light does not report
  back, nothing changes here, whatever **Last Result** says.
- **Freshness** is `current` only when both values are. A device on the owner's
  side that has no level variable leaves the export `unavailable`, and this
  light stays offline.
- *Remote Light On* and *Remote Light Off* need an earlier state to compare
  with: the first state after a restart fires nothing.
- Hardware validation: none recorded. The messages exchanged with the light
  proxy follow the SmartBuildOS capability matrix and other light drivers; there
  is no test record for this driver on a physical controller.

<!-- #embed-changelog -->
