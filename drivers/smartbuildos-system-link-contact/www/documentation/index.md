# SmartBuildOS System Link Contact

This driver is a contact in this project that stands in for a real contact in
another Control4 project: a door or window contact, a float switch, any sensor
that is open or closed. The project that has the contact (the owner) shares it
across the link as an export. This driver sits on the receiving side and offers
a **Contact** connection you bind in Connections, the way you would bind a
contact input on a controller, plus its own events and a conditional for
programming.

It only listens. A contact has nothing to command, so nothing is ever sent to
the owner.

## What it needs

- **SmartBuildOS System Link** in this project, linked to the owner's project
  and synchronised. This driver finds it by itself; its properties call it the
  bridge. It talks to nothing else.
- A `contact` export made on the owner's project.
- No licence of its own. It runs under the System Link pair licence held by
  SmartBuildOS System Link, and sensors are part of every pair licence.
- Control4 OS 3.3.2 or later.

## Setup

<!-- walkthrough: Add a linked contact -->
1. On the owner's project, select SmartBuildOS System Link. Set **Export Kind**
   to `contact`, pick the contact in **Export Device**, fill in **Export Name**
   and run *Export Selected Device*. A contact export is always view only.
1. On this project, select SmartBuildOS System Link. **Pending Exports** lists
   the export, for example `Side_Door (contact)`. Pick it in **Pending Export**
   and run *Add Companion For Pending Export*. This driver is added, linked to
   the export and named after it. *Auto Setup* does the same for every pending
   export in one go.
1. Or do it by hand: add this driver and pick the export in **Linked Export**.
   The list holds contact exports only. One driver per export.
1. Check the Properties tab. **Bridge Link** reads `Connected to bridge`
   followed by a device number, **Freshness** reads `current`, and
   **Confirmed State** reads `Open` or `Closed`.
1. Open and close the contact on the owner's side and watch **Confirmed State**
   follow. Check that it reads the right way round.
1. If another driver here should see the contact, bind this driver's **Contact**
   connection to it in Connections. For programming alone, no binding is needed.

If *Add Companion For Pending Export* says the add failed, load this driver's
file onto the controller once with Driver > Add or Update Driver and run the
action again.

## What crosses the link

| Direction | What |
| --- | --- |
| Owner to here | Open or closed |
| Here to the owner | Nothing |
| Not carried | Battery, tamper, signal strength, any other value of the sensor |

The owner reads the contact's `STATE` variable, or `CONTACT_STATE` or `Opened`
if that is what the device has, and publishes each change. It understands open
(`opened`, `open`, `1`, `true`) and closed (`closed`, `0`, `false`). Any other
value is published as `unavailable`.

Each time the owner confirms a state, this driver tells the driver bound to its
**Contact** connection opened or closed. When that driver asks for the state, it
gets the last confirmed one; before any state has arrived it gets no answer
rather than a guess.

## Reading the status

| Property | What it tells you |
| --- | --- |
| **Bridge Link** | Whether SmartBuildOS System Link was found and answered. If the link carries no contact export it says so and names what the link does carry |
| **Remote System State** | The link as a whole, as SmartBuildOS System Link sees it. `Ready` is the good state |
| **Freshness** | `current`: the state is confirmed. `stale`: the link is not synchronised, or the owner has not confirmed the value for 15 minutes. `unknown`: nothing received yet. `unavailable`: the owner's device supplies nothing that reads as open or closed |
| **Confirmed State** | `Open`, `Closed` or `unavailable` |
| **Control** | `view only`, or `view only / suspended` once a state has arrived: a contact export never allows control |
| **Requested State**, **Last Result** | Not used: this driver sends no requests |

## Programming

- Events: *Remote Contact Opened* and *Remote Contact Closed* (the owner's
  contact reported a change), *Remote Value Current* and *Remote Value Stale*
  (**Freshness** became `current` or stopped being `current`). *Control Refused*
  is listed and never fires.
- Conditionals: *Remote Contact Is Open*, *Remote Value Is Current*.
- Actions: *Refresh From Bridge* (ask for the export list and state again),
  *Rename From Export* (name the device after the export even if you renamed
  it), *Print Diagnostics To Log*.
- Variables and commands: none of its own. The state is also a variable of
  SmartBuildOS System Link, named after the owner's alias and the export:
  `<Alias>.Side_Door_Open`.

A driver bound to the **Contact** connection brings its own programming, as it
would with a wired contact.

## Examples

### A door in the other house was left open

On *Remote Contact Opened*, start a ten-minute timer; on
*Remote Contact Closed*, stop it. When the timer expires, check
*Remote Value Is Current* and *Remote Contact Is Open*, then send a
notification.

### Know when the far sensor stops answering

On *Remote Value Stale*, send a notification that the far contact's state is no
longer confirmed: the link is not synchronised, or the owner has not confirmed
the value for 15 minutes, for example because its controller is off.
*Remote Value Current* is the all-clear.

## Limits

- While **Freshness** is not `current`, the bound driver and
  *Remote Contact Is Open* keep the last confirmed state. Nothing here reports
  the sensor as lost except *Remote Value Stale* and the **Freshness** property,
  so use those where it matters.
- *Remote Contact Is Open* is false after a restart until the first `current`
  state arrives, and that first state fires no event.
- The state reaches this project through both controllers, both internet
  connections and SmartBuildOS between them. Do not make it the only path for a
  security or life-safety signal.
- Hardware validation: none recorded. The contact messages follow the
  SmartBuildOS capability matrix; there is no test record for this driver on a
  physical controller.

<!-- #embed-changelog -->
