# SmartBuildOS System Link Shade

This driver is a shade in this project that stands in for a real shade in
another Control4 project. The project that has the shade (the owner) shares it
across the link as an export. This driver sits on the receiving side and
presents that export as an ordinary Control4 shade: it has a place in a room, on
the Navigators and in programming. It shows the position the owner's shade has
reported, and every open, close, stop or level is sent to the owner as a
request.

## What it needs

- **SmartBuildOS System Link** in this project, linked to the owner's project
  and synchronised. This driver finds it by itself; its properties call it the
  bridge. It talks to nothing else.
- A `shade` export made on the owner's project.
- No licence of its own. It runs under the System Link pair licence held by
  SmartBuildOS System Link, and that licence must carry the `SHADE` feature:
  without it the owner cannot export a shade at all, view only included.
- Control4 OS 3.3.2 or later.

## Setup

<!-- walkthrough: Add a linked shade -->
1. On the owner's project, select SmartBuildOS System Link. Set **Export Kind**
   to `shade`, pick the shade in **Export Device**, fill in **Export Name**, set
   **Export Control** to `Control allowed` if this project is to move it, and
   run *Export Selected Device*. If the licence lacks `SHADE`, **Last Error**
   there says so.
1. On this project, select SmartBuildOS System Link. **Pending Exports** lists
   the export, for example `Bed_Shade (shade)`. Pick it in **Pending Export**
   and run *Add Companion For Pending Export*. This driver is added, linked to
   the export and named after it: `Bed_Shade` becomes "Bed Shade". *Auto Setup*
   does the same for every pending export in one go.
1. Or do it by hand: add this driver and pick the export in **Linked Export**.
   The list holds shade exports only. One driver per export.
1. Check the Properties tab. **Bridge Link** reads `Connected to bridge`
   followed by a device number, **Freshness** reads `current`, and
   **Confirmed State** shows the position, for example `50% open`.
1. Move the shade to the room where it should appear.
1. On the Actions tab press *Test: Remote 50%*. **Last Result** goes from `sent`
   to `accepted` to `delivered`. **Confirmed State** reads `(moving)` while the
   owner's shade travels and settles when it stops.

If *Add Companion For Pending Export* says the add failed, load this driver's
file onto the controller once with Driver > Add or Update Driver and run the
action again.

## What crosses the link

| Direction | What |
| --- | --- |
| Owner to here | The level from 0 to 100, and whether the shade is moving |
| Here to the owner | Open, close, stop, and a level from 0 to 100 |
| Not carried | Tilt, the target the shade is travelling to, travel speed, presets, battery |

The owner reads the shade's level variable (`LEVEL`, `Level` or `POSITION`) and
its moving variable (`MOVING` or `IS_MOVING`), and publishes each change. The
level is passed through as the owner's shade reports it. Here 0 is closed and
100 is open.

A command to this shade never changes what it shows. It becomes one request to
the owner, who sends the matching open, close, stop or level command to the real
shade. The shade here is told moving, and then stopped at a level, only when the
owner's shade reports it. Toggle is decided here: close if the last confirmed
level is above 50, otherwise open. Each request is sent once and never repeated,
which matters for stop.

## Reading the status

| Property | What it tells you |
| --- | --- |
| **Bridge Link** | Whether SmartBuildOS System Link was found and answered. If the link carries no shade export it says so and names what the link does carry |
| **Remote System State** | The link as a whole, as SmartBuildOS System Link sees it. `Ready` is the good state |
| **Freshness** | `current`: both values are confirmed. `stale`: the link is not synchronised, or the owner has not confirmed a value for 15 minutes. `unknown`: nothing received yet. `unavailable`: the owner's shade does not supply the level or the moving state |
| **Control** | `control permitted` when the owner exported the shade with control allowed and SmartBuildOS System Link here permits commands (not paused, licence in order); otherwise `view only / suspended` |
| **Control Window** | The owner's schedule for this export and whether it is open now. `none` when there is no schedule |
| **Confirmed State** | The owner's last report: `50% open`, `40% open (moving)`, or `unavailable` |
| **Requested State** | The last request sent from here and when, for example `50% at 18:04:10` |
| **Last Result** | `sent`, then `accepted` (queued for the owner), then `delivered` (the owner sent it to the shade) or `failed:` with the reason, for example `failed: feature SHADE is not licensed` |

While **Control Window** is closed, a command is refused here without being
sent: **Last Result** reads `refused: outside the control window` with the
schedule, and *Control Refused* fires. The owner's clock decides, not this
controller's.

## Programming

The shade itself is a standard Control4 shade (the `blind` proxy), so it has the
usual shade commands, events and conditionals in programming. Open, close, stop,
toggle and set level are all sent to the owner as described above.

The driver adds these of its own:

- Events: *Remote Value Current* and *Remote Value Stale* (**Freshness** became
  `current` or stopped being `current`), *Control Refused* (a request was
  refused; **Last Result** has the reason).
- Conditional: *Remote Value Is Current*.
- Actions: *Test: Remote Open*, *Test: Remote Close*, *Test: Remote Stop*,
  *Test: Remote 50%*, *Refresh From Bridge* (ask for the export list and state
  again), *Rename From Export* (name the device after the export even if you
  renamed it), *Print Diagnostics To Log*.

It has no variables and no commands of its own. The export's values are also
variables of SmartBuildOS System Link, named after the owner's alias and the
export: `<Alias>.Bed_Shade_Level` and `<Alias>.Bed_Shade_Moving`.

## Examples

### Close the far shades when this house goes to Away

Add this shade's ordinary Close command to the Away routine. On
*Control Refused*, send a notification: the request was turned down, and
**Last Result** says why, for example `failed: commands are suspended`.

### Do nothing when the link is down

Put the command inside *Remote Value Is Current*. When the value is not current
the position shown here may be old, and a toggle would be decided on that old
position.

## Limits

- The shade shows confirmed position only. If the owner's shade does not report
  back, nothing changes here, whatever **Last Result** says.
- **Freshness** is `current` only when both values are. A shade on the owner's
  side that has no moving variable leaves the export `unavailable`, and this
  shade is never told a position.
- While **Freshness** is not `current` the shade here keeps the last position it
  was told; this driver does not report the shade as lost.
- The shade is not told where it is going, only that it is moving and where it
  is now.
- Hardware validation: none recorded. The messages exchanged with the shade
  proxy are taken from other shade drivers, which is why shades stay behind the
  `SHADE` licence feature; there is no test record for this driver on a physical
  controller.

<!-- #embed-changelog -->
