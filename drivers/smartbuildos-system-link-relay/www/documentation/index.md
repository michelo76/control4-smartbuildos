# SmartBuildOS System Link Relay

This driver is a relay connection in this project that stands in for a real
relay in another Control4 project. The project that has the relay (the owner)
shares it across the link as an export. This driver sits on the receiving side
and offers a **Relay** connection you bind in Connections, the way you would
bind a relay port on a controller. The driver you bind to it opens, closes,
toggles or pulses the far relay, and sees its state.

It has no proxy and no room presence of its own. It is the relay; what uses it
is the driver you bind.

## What it needs

- **SmartBuildOS System Link** in this project, linked to the owner's project
  and synchronised. This driver finds it by itself; its properties call it the
  bridge. It talks to nothing else.
- A `relay` export made on the owner's project.
- No licence of its own. It runs under the System Link pair licence held by
  SmartBuildOS System Link, and relays are part of every pair licence.
- Control4 OS 3.3.2 or later.

## Setup

<!-- walkthrough: Add a linked relay -->
1. On the owner's project, select SmartBuildOS System Link. Set **Export Kind**
   to `relay`, pick the relay in **Export Device**, fill in **Export Name**, set
   **Export Control** to `Control allowed` if this project is to operate it, and
   run *Export Selected Device*. To allow only some operations, list them in
   **Export Operations** first: `open`, `close`, `toggle`, `trigger`.
1. On this project, select SmartBuildOS System Link. **Pending Exports** lists
   the export, for example `Pump_Relay (relay)`. Pick it in **Pending Export**
   and run *Add Companion For Pending Export*. This driver is added, linked to
   the export and named after it. *Auto Setup* does the same for every pending
   export in one go.
1. Or do it by hand: add this driver and pick the export in **Linked Export**.
   The list holds relay exports only. One driver per export.
1. Check the Properties tab. **Bridge Link** reads `Connected to bridge`
   followed by a device number, **Freshness** reads `current`, and
   **Confirmed State** reads `Open` or `Closed`.
1. On the Actions tab press *Test: Remote Close*. **Last Result** goes from
   `sent` to `accepted` to `delivered`, and **Confirmed State** changes once the
   owner's relay reports closed. Press *Test: Remote Open* to put it back.
1. In Connections, bind this driver's **Relay** connection to the driver that
   should use the relay.

If *Add Companion For Pending Export* says the add failed, load this driver's
file onto the controller once with Driver > Add or Update Driver and run the
action again.

## What crosses the link

| Direction | What |
| --- | --- |
| Owner to here | Closed or open |
| Here to the owner | Open, close, toggle, and trigger (a pulse) |
| Not carried | The pulse length and any other setting of the owner's relay |

The owner reads the relay's `STATE` variable, or `RELAY_STATE` or `Closed` if
that is what the device has, and publishes each change.

A command from the bound driver never changes the state this relay reports. It
becomes one request to the owner, who sends the same command to the real relay.
The bound driver is told closed or open only when the owner's relay reports it.
A trigger is a single request: the owner's relay ends the pulse itself, and no
second message is sent to release it. Each request is sent once and never
repeated, which matters for toggle and trigger.

## Reading the status

| Property | What it tells you |
| --- | --- |
| **Bridge Link** | Whether SmartBuildOS System Link was found and answered. If the link carries no relay export it says so and names what the link does carry |
| **Remote System State** | The link as a whole, as SmartBuildOS System Link sees it. `Ready` is the good state |
| **Freshness** | `current`: the state is confirmed. `stale`: the link is not synchronised, or the owner has not confirmed the value for 15 minutes. `unknown`: nothing received yet. `unavailable`: the owner's device supplies nothing that reads as closed or open |
| **Control** | `control permitted` when the owner exported the relay with control allowed and SmartBuildOS System Link here permits commands (not paused, licence in order); otherwise `view only / suspended` |
| **Control Window** | The owner's schedule for this export and whether it is open now. `none` when there is no schedule |
| **Confirmed State** | `Closed`, `Open` or `unavailable` |
| **Requested State** | The last request sent from here and when, for example `Pulse at 18:04:10` |
| **Last Result** | `sent`, then `accepted` (queued for the owner), then `delivered` (the owner sent it to the relay) or `failed:` with the reason |

While **Control Window** is closed, a command is refused here without being
sent: **Last Result** reads `refused: outside the control window` with the
schedule, and *Control Refused* fires. The owner's clock decides, not this
controller's.

## Programming

To operate the far relay from programming, program the driver you bound to the
**Relay** connection. This driver has no commands and no variables of its own.
It adds:

- Events: *Remote Relay Closed* and *Remote Relay Opened* (the owner's relay
  reported a change), *Remote Value Current* and *Remote Value Stale*
  (**Freshness** became `current` or stopped being `current`), *Control Refused*
  (a request was refused; **Last Result** has the reason).
- Conditionals: *Remote Relay Is Closed*, *Remote Value Is Current*.
- Actions: *Test: Remote Open*, *Test: Remote Close*, *Refresh From Bridge* (ask
  for the export list and state again), *Rename From Export* (name the device
  after the export even if you renamed it), *Print Diagnostics To Log*.

The relay's state is also a variable of SmartBuildOS System Link, named after
the owner's alias and the export: `<Alias>.Pump_Relay_Closed`.

## Examples

### Run a pump in the other house

The owner exports the pump relay with `Control allowed`. Here, bind the
**Relay** connection to a relay-driven device driver and use that driver's own
on and off in programming. On *Control Refused*, send a notification with the
reason, and treat *Remote Relay Closed* as the proof that the pump is running.

### A pulse and nothing else

The owner sets **Export Operations** to `trigger` before exporting. A pulse from
here is delivered. An open or close is turned down, **Last Result** reads
`failed: operation open is not permitted on this export`, and *Control Refused*
fires.

## Limits

- The state is confirmed state only. Until the first report arrives after a
  restart, a state query from the bound driver gets no answer,
  *Remote Relay Is Closed* is false, and the first report fires no event.
- `delivered` means the owner passed the command to its relay. Whether the
  contact moved is what *Remote Relay Closed* and *Remote Relay Opened* tell
  you.
- While **Freshness** is not `current` the bound driver keeps the last state it
  was told; this driver does not report the relay as lost.
- Hardware validation: none recorded. The relay messages follow the SmartBuildOS
  capability matrix; there is no test record for this driver on a physical
  controller.

<!-- #embed-changelog -->
