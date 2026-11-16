# SmartBuildOS System Link Fan

This driver brings the state of a fan in another Control4 project into this one.
The project that has the real fan (the owner) shares it across the link as an
export. This driver sits on the receiving side and turns that export into two
variables, two events and a conditional, so programming here can react to the
far fan running or stopping.

It is a programming device, not a fan on the Navigators: it has no proxy. In
this release it reports; it does not give programming a way to drive the fan.

## What it needs

- **SmartBuildOS System Link** in this project, linked to the owner's project
  and synchronised. This driver finds it by itself; its properties call it the
  bridge. It talks to nothing else.
- A `fan` export made on the owner's project.
- No licence of its own. It runs under the System Link pair licence held by
  SmartBuildOS System Link. Fan status works on every pair licence. Fan control
  needs the `FAN` feature on the pair licence.
- Control4 OS 3.3.2 or later.

## Setup

<!-- walkthrough: Add a linked fan -->
1. On the owner's project, select SmartBuildOS System Link. Set **Export Kind**
   to `fan`, pick the fan in **Export Device**, fill in **Export Name**, leave
   **Export Control** on `View only`, and run *Export Selected Device*.
1. On this project, select SmartBuildOS System Link. **Pending Exports** lists
   the export, for example `Porch_Fan (fan)`. Pick it in **Pending Export** and
   run *Add Companion For Pending Export*. This driver is added, linked to the
   export and named after it. *Auto Setup* does the same for every pending
   export in one go.
1. Or do it by hand: add this driver and pick the export in **Linked Export**.
   The list holds fan exports only. One driver per export.
1. Check the Properties tab. **Bridge Link** reads `Connected to bridge`
   followed by a device number, **Freshness** reads `current`, and
   **Confirmed State** reads `Speed 5` or `Off`.
1. Change the fan's speed on the owner's side and watch **Confirmed State**
   follow.

If *Add Companion For Pending Export* says the add failed, load this driver's
file onto the controller once with Driver > Add or Update Driver and run the
action again.

## What crosses the link

| Direction | What |
| --- | --- |
| Owner to here | The fan's speed, a whole number from 0 to 10. 0 is off |
| Here to the owner | Only the three Test actions: on, off, speed 5 |
| Not carried | Direction, a fan light, timers, any other setting |

The owner reads the fan's `FAN_SPEED` variable, or `CURRENT_SPEED` if that is
the one the device has, and publishes each change.

The Test actions are there to prove the path from Composer. Each sends one
request, which the owner turns into the fan's on, off or set-speed command. The
owner refuses it unless the export was made with `Control allowed`, which the
owner can only choose when the pair licence carries `FAN`, and the licence is
checked again at every request.

## Reading the status

| Property | What it tells you |
| --- | --- |
| **Bridge Link** | Whether SmartBuildOS System Link was found and answered. If the link carries no fan export it says so and names what the link does carry |
| **Remote System State** | The link as a whole, as SmartBuildOS System Link sees it. `Ready` is the good state |
| **Freshness** | `current`: the speed is confirmed. `stale`: the link is not synchronised, or the owner has not confirmed the value for 15 minutes. `unknown`: nothing received yet. `unavailable`: the owner's device does not supply a speed |
| **Control** | `control permitted` when the export allows control and SmartBuildOS System Link here permits commands; otherwise `view only / suspended` |
| **Control Window** | The owner's schedule for this export and whether it is open now. `none` when there is no schedule |
| **Confirmed State** | `Speed 5`, `Off` or `unavailable` |
| **Requested State** | The last Test request and when |
| **Last Result** | `sent`, `accepted`, then `delivered` or `failed:` with the owner's reason, for example `failed: export is view-only` or `failed: feature FAN is not licensed` |

## Programming

- Variables: `Speed` (number, 0 to 10) and `On` (Boolean, true while the speed
  is above 0). Both are read-only.
- Events: *Remote Fan On* (the speed went from 0 to above 0), *Remote Fan Off*
  (it went back to 0), *Remote Value Current* and *Remote Value Stale*
  (**Freshness** became `current` or stopped being `current`), *Control Refused*
  (a Test request was refused; **Last Result** has the reason).
- Conditionals: *Remote Fan Is On*, *Remote Value Is Current*.
- Actions: *Test: Remote On*, *Test: Remote Off*, *Test: Remote Speed 5*,
  *Refresh From Bridge* (ask for the export list and state again),
  *Rename From Export* (name the device after the export even if you renamed
  it), *Print Diagnostics To Log*.
- Commands: none.

## Examples

### The far fan has been running too long

On *Remote Fan On*, start a two-hour timer; on *Remote Fan Off*, stop it. When
the timer expires, check *Remote Value Is Current* and *Remote Fan Is On*, then
send a notification.

### Act on the speed

Program on the `Speed` variable changing: if `Speed` is greater than 7, do
something here, such as closing a shade against the draught. Put the check
inside *Remote Value Is Current*, because `Speed` reads 0 when no value is
available.

## Limits

- Programming cannot command the fan. The Test actions on the Actions tab are
  the only way this driver sends anything.
- `Speed` and `On` read 0 when the owner's device supplies no value. They keep
  their last value while **Freshness** is `stale`. Use *Remote Value Is Current*
  to tell a real 0 from a missing one.
- *Remote Fan Is On* answers from the last confirmed speed seen since this
  driver started. After a restart it is false until the first `current` state
  arrives, and that first state fires no event.
- A request is sent once and never repeated. `delivered` means the owner passed
  the command to the fan, not that the fan turned.
- Hardware validation: none yet. The variable names the owner reads are the ones
  Mode Composer's adapters read in the field. Control stays behind the `FAN`
  licence feature until there is a hardware test record
  (`docs/system-link/HARDWARE-VALIDATION.md` in the SmartBuildOS repository).
