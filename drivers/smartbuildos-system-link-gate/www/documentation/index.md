# SmartBuildOS System Link Gate

This driver tells this project whether a gate or garage door in another Control4
project is open. The project that has the door (the owner) shares it across the
link as an export. This driver sits on the receiving side and turns that export
into one variable, two events and a conditional, so programming here can react
when the far gate opens or closes.

It is a programming device, not a door on the Navigators: it has no proxy. In
this release it reports; it does not give programming a way to move the gate.

## What it needs

- **SmartBuildOS System Link** in this project, linked to the owner's project
  and synchronised. This driver finds it by itself; its properties call it the
  bridge. It talks to nothing else.
- A `gate` export made on the owner's project.
- No licence of its own. It runs under the System Link pair licence held by
  SmartBuildOS System Link. Gate status works on every pair licence. Gate
  control needs the `GATE` feature on the pair licence.
- Control4 OS 3.3.2 or later.

## Setup

<!-- walkthrough: Add a linked gate -->
1. On the owner's project, select SmartBuildOS System Link. Set **Export Kind**
   to `gate`, pick the device in **Export Device** (see the next section for
   which one), fill in **Export Name**, leave **Export Control** on `View only`,
   and run *Export Selected Device*.
1. On this project, select SmartBuildOS System Link. **Pending Exports** lists
   the export, for example `Garage (gate)`. Pick it in **Pending Export** and
   run *Add Companion For Pending Export*. This driver is added, linked to the
   export and named after it. *Auto Setup* does the same for every pending
   export in one go.
1. Or do it by hand: add this driver and pick the export in **Linked Export**.
   The list holds gate exports only. One driver per export.
1. Check the Properties tab. **Bridge Link** reads `Connected to bridge`
   followed by a device number, **Freshness** reads `current`, and
   **Confirmed State** reads `Open` or `Closed`.
1. Open and close the gate on the owner's side and watch **Confirmed State**
   follow. Check that it reads the right way round.

If *Add Companion For Pending Export* says the add failed, load this driver's
file onto the controller once with Driver > Add or Update Driver and run the
action again.

## What crosses the link

| Direction | What |
| --- | --- |
| Owner to here | Open or closed |
| Here to the owner | Only the three Test actions: trigger, open, close |
| Not carried | Opening, closing, stopped or obstructed states, and how far the gate has travelled |

An export is one device on the owner's side, and both the state and the Test
commands use that device. The owner reads its `GARAGE_DOOR_STATE` variable if it
has one, otherwise `STATE` or `RELAY_STATE`. So the choice of device matters: a
garage door driver gives the door's own state; a bare relay gives the relay's
state, which is not the position of the door. The owner understands open
(`open`, `opened`, `1`, `true`) and closed (`closed`, `close`, `0`, `false`).
Any other value the device reports is published as `unavailable` until the next
open or closed.

The Test actions each send one request. The owner turns it into a trigger
(pulse), open or close command to the exported device, and refuses it unless the
export was made with `Control allowed`, which the owner can only choose when the
pair licence carries `GATE`. The licence is checked again at every request. The
owner accepting a command says nothing about the door: wait for
*Remote Gate Opened* or *Remote Gate Closed*.

## Reading the status

| Property | What it tells you |
| --- | --- |
| **Bridge Link** | Whether SmartBuildOS System Link was found and answered. If the link carries no gate export it says so and names what the link does carry |
| **Remote System State** | The link as a whole, as SmartBuildOS System Link sees it. `Ready` is the good state |
| **Freshness** | `current`: the state is confirmed. `stale`: the link is not synchronised, or the owner has not confirmed the value for 15 minutes. `unknown`: nothing received yet. `unavailable`: the owner's device supplies nothing that reads as open or closed |
| **Control** | `control permitted` when the export allows control and SmartBuildOS System Link here permits commands; otherwise `view only / suspended` |
| **Control Window** | The owner's schedule for this export and whether it is open now. `none` when there is no schedule |
| **Confirmed State** | `Open`, `Closed` or `unavailable` |
| **Requested State** | The last Test request and when |
| **Last Result** | `sent`, `accepted`, then `delivered` or `failed:` with the owner's reason, for example `failed: export is view-only` or `failed: feature GATE is not licensed` |

## Programming

- Variable: `Open` (Boolean, read-only).
- Events: *Remote Gate Opened*, *Remote Gate Closed*, *Remote Value Current* and
  *Remote Value Stale* (**Freshness** became `current` or stopped being
  `current`), *Control Refused* (a Test request was refused; **Last Result** has
  the reason).
- Conditionals: *Remote Gate Is Open*, *Remote Value Is Current*.
- Actions: *Test: Remote Trigger*, *Test: Remote Open*, *Test: Remote Close*,
  *Refresh From Bridge* (ask for the export list and state again),
  *Rename From Export* (name the device after the export even if you renamed
  it), *Print Diagnostics To Log*.
- Commands: none.

## Examples

### The far gate has been open for ten minutes

On *Remote Gate Opened*, start a ten-minute timer; on *Remote Gate Closed*, stop
it. When the timer expires, check *Remote Value Is Current* and
*Remote Gate Is Open*, then send a notification.

### Goodnight check across two houses

In the Goodnight routine here, test *Remote Value Is Current*. If it is current
and *Remote Gate Is Open* is true, announce that the far gate is open. If it is
not current, say that the far gate's state is not known rather than treating it
as closed.

## Limits

- Programming cannot command the gate. The Test actions on the Actions tab are
  the only way this driver sends anything.
- `Open` reads 0, the same as closed, when the owner's device supplies no value.
  It keeps its last value while **Freshness** is `stale`. Always pair it with
  *Remote Value Is Current*.
- *Remote Gate Is Open* answers from the last confirmed state seen since this
  driver started. After a restart it is false until the first `current` state
  arrives, and that first state fires no event.
- A request is sent once and never repeated. A trigger is one pulse request; the
  owner's device ends the pulse.
- Hardware validation: none yet. The variable names the owner reads are the ones
  Mode Composer's adapters read in the field. Control stays behind the `GATE`
  licence feature until there is a hardware test record
  (`docs/system-link/HARDWARE-VALIDATION.md` in the SmartBuildOS repository).
