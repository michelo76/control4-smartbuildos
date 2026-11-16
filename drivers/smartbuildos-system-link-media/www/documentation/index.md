# SmartBuildOS System Link Media Room

This driver tells this project what a room in another Control4 project is
playing. The project that has the room (the owner) shares the room's playing
state across the link as an export. This driver sits on the receiving side and
turns it into four variables, three events and a conditional: whether the room
is on, the name of its source, its volume and its media text.

It is read-only. A room in another project can be watched, not driven: there is
no command to turn it on, change its source or set its volume, and the driver
has no proxy, so it does not appear on the Navigators.

## What it needs

- **SmartBuildOS System Link** in this project, linked to the owner's project
  and synchronised. This driver finds it by itself; its properties call it the
  bridge. It talks to nothing else.
- A `media` export made on the owner's project, with the room itself as the
  device.
- No licence of its own. It runs under the System Link pair licence held by
  SmartBuildOS System Link, and media exports are part of every pair licence.
- Control4 OS 3.3.2 or later.

## Setup

<!-- walkthrough: Add a linked room -->
1. On the owner's project, select SmartBuildOS System Link. Set **Export Kind**
   to `media`, pick the room in **Export Device** (the room, not a device in
   it), fill in **Export Name** and run *Export Selected Device*. A media export
   is always view only, whatever **Export Control** says.
1. On this project, select SmartBuildOS System Link. **Pending Exports** lists
   the export, for example `Kitchen_Room (media)`. Pick it in **Pending Export**
   and run *Add Companion For Pending Export*. This driver is added, linked to
   the export and named after it. *Auto Setup* does the same for every pending
   export in one go.
1. Or do it by hand: add this driver and pick the export in **Linked Export**.
   The list holds media exports only. One driver per export.
1. Check the Properties tab. **Bridge Link** reads `Connected to bridge`
   followed by a device number, and **Confirmed State** reads something like
   `On · Kitchen TV · volume 32`, or `Off`.
1. Start something playing in the owner's room and watch **Confirmed State** and
   **Freshness** follow. Read the next section if **Freshness** does not reach
   `current`.

If *Add Companion For Pending Export* says the add failed, load this driver's
file onto the controller once with Driver > Add or Update Driver and run the
action again.

## What crosses the link

| Value | Variable here | What the owner reads from its room |
| --- | --- | --- |
| On or off | `Powered` | `POWER_STATE` |
| Source | `Source` | `CURRENT_SELECTED_DEVICE`, sent as that device's name |
| Volume, 0 to 100 | `Volume` | `CURRENT_VOLUME` or `VOLUME_LEVEL` |
| Media text | `Media` | `CURRENT MEDIA INFO`, `CURRENT_MEDIA` or `MEDIA WALL INFO` |

Nothing travels the other way. Mute, transport state, the queue and cover art
are not carried. The media text is passed on as the room reports it, with runs
of spaces collapsed, cut at 256 characters.

A value the owner's room does not supply is published as unavailable, never made
up. That includes a room with no source selected and a room with no media text:
an empty value counts as unavailable. Which of these variables a room answers
depends on the OS version.

**Freshness** is `current` only when all four values are. If one is unavailable,
**Freshness** reads `unavailable`, even though the other three are correct and
their variables are up to date. This matters for the events: see Programming.

## Reading the status

| Property | What it tells you |
| --- | --- |
| **Bridge Link** | Whether SmartBuildOS System Link was found and answered. If the link carries no media export it says so and names what the link does carry |
| **Remote System State** | The link as a whole, as SmartBuildOS System Link sees it. `Ready` is the good state |
| **Freshness** | `current`: all four values are confirmed. `stale`: the link is not synchronised, or the owner has not confirmed a value for 15 minutes. `unknown`: nothing received yet. `unavailable`: the room does not supply at least one of the four |
| **Confirmed State** | `On`, then the source, the volume and the media text where the room supplies them; `Off`; `Power unknown` first when only the power state is missing; `unavailable` when nothing is supplied |
| **Control** | `view only`, or `view only / suspended` once a state has arrived: a media export never allows control |
| **Requested State**, **Last Result** | Not used: this driver sends no requests |

## Programming

- Variables: `Powered` (Boolean), `Source` (text), `Volume` (number), `Media`
  (text). All read-only. They are updated on every message from the owner,
  whatever **Freshness** says. A value that is unavailable reads 0 or empty.
- Events: *Remote Room On*, *Remote Room Off*, *Remote Media Changed*,
  *Remote Value Current* and *Remote Value Stale* (**Freshness** became
  `current` or stopped being `current`). *Control Refused* is listed and never
  fires.
- Conditionals: *Remote Room Is On*, *Remote Value Is Current*.
- Actions: *Refresh From Bridge* (ask for the export list and state again),
  *Rename From Export* (name the device after the export even if you renamed
  it), *Print Diagnostics To Log*.
- Commands: none.

*Remote Room On*, *Remote Room Off* and *Remote Media Changed* fire only while
**Freshness** is `current`, and *Remote Room Is On* is only updated then. If the
owner's room turns off and drops its source at the same moment, the export goes
`unavailable`, *Remote Room Off* does not fire, and *Remote Room Is On* keeps
saying on. The `Powered` variable does follow. For on and off, program on
`Powered` changing.

## Examples

### Quiet this house while the other one is watching a film

Program on the `Powered` variable changing. When it becomes true, lower the
volume of the announcements here; when it becomes false, restore it.

### Say what is playing over there

On a keypad button here, send a notification or an on-screen message built from
the `Source` and `Media` variables, with `Volume` if you want it. Check
`Powered` first: when the room is off, `Source` and `Media` may be empty.

## Limits

- Watch only. No control of the far room exists in this release.
- The room events depend on all four values being available, as described above.
  In a room that never supplies one of them they never fire.
- `Source` is the name the source device has in the owner's project. If the
  owner cannot resolve the name, the device's number is sent as text.
- After a restart *Remote Room Is On* is false until the first `current` state
  arrives, and that first state fires no event.
- Hardware validation: none yet. Whether a room answers a request for its
  variables on a given OS is exactly what the bench must confirm; the
  SmartBuildOS Agent reports the same question.
