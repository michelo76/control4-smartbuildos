# SmartBuildOS System Link

System Link joins two Control4 projects, in two buildings anywhere, so that
each can see chosen values of the other and ask it to do things. Each project
decides what it shares: a variable it sets, or one of its devices. The other
project gets a read-only copy it can program on and, where the owner allows
it, a device in its own tree that drives the real one. Nothing else in either
project is visible to the other, and nothing runs in a project unless that
project's own programming runs it.

This driver is the bridge: one per project, linked to exactly one other
bridge through SmartBuildOS. The System Link device drivers (the actions call
them companions) each stand for one shared device and work only through the
bridge in the same project.

Requires the SmartBuildOS Agent (`smartbuildos.c4z`), paired, on both
projects, and Control4 OS 3.3.2 or later on both controllers. The Agent is
the licensing authority (SKU `SBOS_SYSTEM_LINK`): **License Status** shows
this driver's standing, and the device drivers use the bridge's licence. The
bridge makes outbound connections only; no port is forwarded on either site.

The licence is a System Link pair licence: one per link, covering the two
linked systems, the bridge on both and the device drivers. SmartBuildOS keeps
its rules; the driver shows the result.

- **License Status** reads the Agent's answer, for example `Licensed / Trial`,
  `Licensed / Permanent` or `Agent Linked - Not Licensed (see SmartBuildOS)`.
- A seven-day trial starts the first time a link is approved. SmartBuildOS
  holds it, so reinstalling, updating, renaming, restoring a project or
  replacing a controller does not restart it. A third system cannot activate
  on a pair licence.
- When SmartBuildOS answers that the pair is not licensed, and has turned
  enforcement on, the bridge stops exchanging with the relay: it publishes
  nothing, receives nothing and permits no remote command. Mirrors keep their
  last values and turn `stale`, **Remote System State** reads
  `License Attention` and *License Changed* fires. Status, diagnostics and
  this page keep working, and nothing physical changes. While the answer is
  uncertain (no answer from the Agent yet, SmartBuildOS out of reach) the
  bridge keeps working.

## What it is for

| You want | Use |
| --- | --- |
| One house to know that the other is empty, occupied or in a given mode | A shared item (*Create Shared Item*), set with `Set Local Boolean` or `Set Local Choice`. The other side programs on the item's own `changed (live)` event |
| A number from the other site in your programming: a temperature, a guest count | A shared `INTEGER` or `DECIMAL` item, or a `temperature` export |
| A light, relay, shade or thermostat of the other house in this project's tree | *Export Selected Device* on the owner, *Add Companion For Pending Export* on the other side |
| To see a door, a lock, a garage or what a room is playing, with no control | An export with **Export Control** on `View only` |
| A one-time signal: the doorbell was pressed, the gate opened | `Emit Named Event`, received as *Named Event Received* |
| To ask the other house to do something and learn how it went | `Send Remote Request`; the other side programs on *Request Received* and answers with `Report Request Success` |
| To run a scene the other house defined | A `scene` export and `Run Remote Scene` |
| Remote control allowed only at certain hours | `Set Export Schedule` on the owner |
| All remote control stopped while someone works on site | *Pause Remote Commands*, or *Pause Link* for the whole link |
| To act only on a value that can be trusted | The conditional *Shared Item Is Current*, or the mirror's `.STATE` variable; *Remote System Is Ready* for the link as a whole |
| A chattering sensor kept from flooding the link | A publication filter (*Apply Filter To Selected Item*) |

## Setup

### Link two controllers

The link itself is made in SmartBuildOS System Studio (Connections → System
Link), with Composer open on both projects.

<!-- walkthrough: Link two controllers -->
1. On both projects, install the SmartBuildOS Agent from Composer's Agents
   tab and pair it.
1. Add **SmartBuildOS System Link** to both projects, one per project.
   **Driver Status** reads `Online`. **Link Authorization** reads `Not
   provisioned — approve the link in System Studio`, which is expected at
   this point.
1. In System Studio, start a link: choose the pair licence (or enter its
   activation code) and the first system, and give that system an alias, for
   example `California Home`. Create the invitation code, join from the other
   system with the code and its own alias, review both systems, and approve.
1. Back in Composer, wait a minute or two on each side, or press
   *Re-provision Link*. The bridge asks its Agent for the link and connects.
   **Link Authorization** reads `approved`, **Local System Name** and
   **Linked System Name** show the two aliases, **Sync Status** reads
   `synced` and **Remote System State** reads `Ready — synchronized`.
1. Press *Run Link Test* on either side and read the Lua tab. A working link
   prints `Link test: round trip` with the time. Anything else names the
   first thing that is wrong; see [Reading the status](#reading-the-status).

**The alias gives the prefix.** Every variable the bridge creates starts with
its owner's prefix, so `California_Home.Away` and `New_York_Home.Away` never
collide, and both projects call an item by the same name. The prefix arrives
with the link and is fixed when the link is approved. The driver's rule for
an alias: letters, digits and underscores, starting with a letter, 24
characters at most, so `California Home` becomes `California_Home`. To change
it later, see [Renaming and deleting](#renaming-and-deleting).

### Share a variable

<!-- walkthrough: Share a variable with the other project -->
1. On the bridge of the project that owns the value, fill in **New Item
   Name** (for example `Away`) and **New Item Type**. Optional: **New Item
   Description**, **New Item Group**, **New Item Initial Value**, and for a
   `CHOICE` the comma-separated **New Item Allowed Values**. Leave **New Item
   Export** on `Yes`.
1. On the Actions tab press *Create Shared Item*. The item appears in
   **Selected Item** as `California_Home.Away`, and the bridge now has a
   variable of that name. A refusal is written to **Last Error**.
1. On the other project, at its bridge's next exchange with the relay, the
   bridge has the read-only variable `California_Home.Away`, the variable
   `California_Home.Away.STATE` and the event *California_Home.Away changed
   (live)*. *Print Shared Items* lists every item with its type, owner and
   state.
1. Set it on the owning side with `Set Local Boolean`, or with Composer's own
   set-to-value on the variable. Program on the other side with the item's
   event. [Worked examples](#worked-examples) shows both.

| **New Item Type** | Composer variable | Notes |
| --- | --- | --- |
| `BOOLEAN` | BOOL | Reads `1` or `0`. Accepts true, false, 1, 0, on, off, yes, no |
| `INTEGER` | NUMBER | A value with a fraction is refused |
| `DECIMAL` | FLOAT | Shown with two decimals unless the item carries a precision (0 to 6) |
| `STRING` | STRING | 256 characters at most by default |
| `CHOICE` | STRING | Only one of its allowed values is accepted; up to 64 values |

An item name is letters, digits and underscores, starts with a letter and has
48 characters at most. An item made by hand has no minimum, maximum,
precision or freshness rule; those come with a template, a configuration
import or a device export. **New Item Export** on `No` creates the variable
on this project only and shares nothing.

### Export a device from one system

<!-- walkthrough: Export a device -->
1. On the owner's bridge, in the **Device Exports** block of the Properties
   tab, choose **Export Kind**: what the other project will see the device
   as. The table under [Device exports](#device-exports) lists the kinds.
1. Pick the device in **Export Device**. Entries read `Name (Room) · id`, and
   by default only devices that carry the variables the kind reads are
   listed. If yours is missing, press *Refresh Export Device List*, or set
   **Export Device Filter** to `All devices` to see every device, the unfit
   ones flagged `(no light variables)`.
1. Check **Export Name**. It is filled from the device name when empty:
   letters, digits and underscores, starting with a letter, 40 characters at
   most.
1. Leave **Export Control** on `View only` for a first test. For control,
   choose `Control allowed` and, to allow only some operations, list them in
   **Export Operations** (for example `on,off`).
1. Press *Export Selected Device*. The Lua tab prints `Exported … as … — view
   only`, the export appears in **Selected Export**, and its fields are new
   shared items such as `California_Home.Porch_Light_On` and
   `California_Home.Porch_Light_Level`. A refusal stays in **Last Error**
   with the reason. *Print Exports* shows which variable of the device each
   field reads.

**Pick the device itself, not its protocol driver.** In most projects a
light and its physical driver share a name, and only the light carries
`LIGHT_STATE`. Exporting the wrong one is refused, and the message lists the
variables the kind looks for and the ones the device has.

**Lights, through Connections.** Add a **SmartBuildOS System Link Export
Light** driver on the owner, bind the real light to its Light connection in
Composer's Connections view and name the export in its properties. It
registers with the bridge using the bound device, so there is nothing to
choose between a light and its physical driver. Unbinding or deleting it
removes the export. Other kinds use the **Device Exports** block.

### Add the matching device driver on the other system

<!-- walkthrough: Add the device driver for an export -->
1. Load the System Link device drivers onto the receiving controller once,
   with Driver > Add or Update Driver. The bridge adds a device by its driver
   file and says which file is missing if it is not there.
1. On the receiving bridge, read **Pending Exports**. It lists what the other
   project shares that has no device here yet, for example `Porch_Light
   (light)`.
1. Pick one in **Pending Export** and press *Add Companion For Pending
   Export*. Or press *Auto Setup* to add a device for every pending export,
   one after the other; **Auto Setup** then reports how many were added, were
   already present or failed.
1. The new device is in the project, linked to the export and named after it
   (`Porch_Light` shows as "Porch Light"). Move it to the room you want.
1. Open the new device's properties: **Linked Export** names the export and
   **Freshness** reads `current` once the first values have arrived.

A device driver can also be added by hand: add it to the project and choose
the export in its **Linked Export** list, which shows exports of its own kind
only. Scenes and buttons have no device driver; they are run from the bridge
([Scenes and buttons](#scenes-and-buttons)).

## How it works

### Owner and mirror

Every shared item has one owner: the project that created it. The owner's
bridge holds a variable that programming can write. The other bridge holds a
mirror: a read-only variable with the same name and the owner's latest value.

- Only the owner writes. `Set Local Boolean` and the other set commands on a
  mirror are refused with `read-only mirror` in **Last Error**, mirror
  variables are created read-only, and the relay checks ownership again on
  its side.
- A mirror is never sent back. A value travels from its owner only.
- Setting an owned item to the value it already has publishes nothing.

### The variables the bridge creates

| Variable | On | Holds |
| --- | --- | --- |
| `<OwnPrefix>.<Name>` | the owner | The item's value. Writable |
| `<OtherPrefix>.<Name>` | the other project | The mirror. Read-only; empty while the state is `unknown` or `unavailable` |
| `<OtherPrefix>.<Name>.STATE` | the other project | `current`, `stale`, `unknown` or `unavailable` |
| `<OwnPrefix>.Request_1_Id`, `_Routine`, `_Status`, `_Direction`, `_Payload`, `_Result` | both | Request slot 1; one set per slot |
| `<OwnPrefix>.Last_Event_Name`, `_Payload`, `_Origin`, `_Age_Seconds` | both | The last named event received |

`false`, `0` and an empty text are real, current values. `unknown` means the
value was never seen; `unavailable` means the owner cannot read it (an
exported device without that variable, or an item the owner deleted). Neither
carries a value, which is why the mirror is empty and `.STATE` says which.

Before the bridge has a link it creates the request and event variables under
the prefix `Link.`. Once linked it creates them again under the system's own
prefix; program against those.

### What travels between systems

| What | You send it with | The other side gets |
| --- | --- | --- |
| A value | A change of an owned item: a `Set Local` command, Composer's set-to-value on the variable, or an exported device changing | The mirror updates, then the item's `changed (live)` event and *Remote Variable Changed Live* fire |
| A named event | `Emit Named Event` | The `Last_Event_` variables are written, then *Named Event Received* fires |
| A request | `Send Remote Request` | A request slot is filled, then *Request Received* fires. The answer comes back with `Report Request Success` or `Report Request Failure` |
| A device command | A device driver: a tap in Navigator or programming on it | The owner's bridge checks it and sends the command to the real device |
| A scene run | `Run Remote Scene` | A request whose routine is `scene:` and the scene's name; the scene's `requested` event fires |
| A button press | `Press Remote Button` | A named event `button:` and the button's name; the button's `pressed` event fires |

A local change is sent within a second. The relay rings a contentless
"doorbell" socket when something is waiting for a bridge, and the bridge then
fetches it. While the doorbell is not joined, or has not rung in the last ten
minutes, the bridge polls every 20 seconds instead. A heartbeat goes out
every 30 seconds.

### Initial state versus live change

On every start, and after every loss of the relay, the bridge restores the
last values it knew, marks every mirror `stale`, signs in, reconciles
definitions and revisions, applies the other side's current snapshot, then
fires *Initial Sync Complete*. Nothing before that moment is a live change:
*Remote Variable Changed Live* and the per-item events fire only afterwards.
Named events and requests are never replayed.

Control4's own "when variable changes" behaviour on a restored value is not
documented by Control4. Until it has been measured on a controller, guard
programming on a mirror variable with *Link Is Synchronized*, or use the live
events. To evaluate the other side's state after each sync, set **Evaluate
State After Initial Sync** to `Yes`: every mirror's own event and *Remote
Variable Changed Live* then fire once right after *Initial Sync Complete*.

### Freshness

A mirror is `current` while something confirms it. It turns `stale` when
nothing has confirmed it for 15 minutes (or for the item's own freshness
rule), and at once when this bridge is not synchronized. The last value stays
in the variable.

Two things confirm a mirror: a value from its owner, and the snapshot taken
at every connection, at every start and by *Refresh Link*. The exchange
between changes confirms nothing. In the driver's tests, where the relay
passes a value on only when it changes, a mirror whose owner has been silent
for 15 minutes reads `stale` on a healthy link, **Remote System State** reads
`Stale` and *Remote State Stale* fires. A device driver is told `stale` when
any field of its export is in that state.

To keep a slow value confirmed, select the item (or the export's field) on
the owner and apply a **Filter Maximum Silence Seconds** below 900, for
example 600. The owner then sends the value again every ten minutes, which
confirms the mirror without firing a live event. The re-sending starts with
the item's first change after the filter is applied, and again after each
driver start.

**Remote System State** sums it up, with the reason after a dash. The first
line that applies wins:

| Reads | When |
| --- | --- |
| `License Attention` | SmartBuildOS has refused the licence and enforcement is on |
| `Paused` | The whole link is paused, or the link was revoked |
| `Offline` | The relay cannot be reached, or the other bridge's heartbeat is missing |
| `Synchronizing` | Connected, snapshot not applied yet |
| `Stale` | The other bridge's heartbeat is late, or at least one mirror is not confirmed; the reason gives the count |
| `Ready` | Synchronized, the other bridge is heartbeating, every mirror confirmed |

*Remote State Current* fires when it becomes `Ready` and *Remote State Stale*
when it leaves `Ready`. A heartbeat proves the other bridge is running, not
that the devices behind it work.

### When the link is down

| | While the link is down | When it returns |
| --- | --- | --- |
| Mirrors on this side | Keep their last value; `.STATE` reads `stale`; *Link Disconnected* fires; **Remote System State** reads `Offline` | The snapshot puts every mirror right and *Initial Sync Complete* fires. What this bridge missed fires no live event |
| Values this side owns | Changes are kept, the latest value per item, up to 500 waiting messages, across a restart | Sent. The other side, if it stayed connected, sees them as live changes |
| `Emit Named Event` | Refused at once and not queued: **Last Error** reads `peer unavailable; event not queued (time-sensitive)` | Nothing is sent later |
| `Send Remote Request` | Takes a slot and waits | Sent if still waiting. With no confirmed result by its deadline, *Request Expired* fires |
| Commands from a device driver | Refused at once: the device's **Last Result** reads `failed: peer unavailable` | Nothing is sent later |

The other bridge counts as `online` while its last heartbeat is at most 60
seconds old, `stale` up to 150 seconds, then `offline`; *Peer Online*, *Peer
Stale* and *Peer Offline* fire on each change. A normal reboot, a Director
restart or a driver update keeps definitions, values, revisions, waiting
messages and request slots. If a project is restored from an older backup,
the relay's newer value wins and **Last Error** reports `stale_backup`.

**Replacing a controller.** Re-pair the Agent as usual and confirm the new
controller in System Studio. The bridge then republishes its values under a
new generation, the other side drops anything from the old one, and requests
in flight end as `unknown`. If the system is given a different place on a
link, the bridge starts empty: its items and values are cleared.

### Device exports

An export shares one device as a handful of shared items, one per field,
named `<Export>_<Field>`. The owner's bridge watches the device's variables
and publishes each change. A field whose variable the device does not have
reads `unavailable`.

| **Export Kind** | Fields | Operations with `Control allowed` | Licence feature needed |
| --- | --- | --- | --- |
| `light` | `On`, `Level` | `on`, `off`, `set_level` | none |
| `relay` | `Closed` | `open`, `close`, `toggle`, `trigger` | none |
| `contact` | `Open` | view only | none |
| `temperature` | `Fahrenheit`, `Celsius` | view only | none |
| `thermostat` | `Temperature`, `Heat_Setpoint`, `Cool_Setpoint`, `HVAC_Mode`, `HVAC_State`, `Fan_Mode`, `Scale` | `set_heat`, `set_cool`, `set_mode`, `set_fan` | `THERMOSTAT`, to export at all |
| `shade` | `Level`, `Moving` | `open`, `close`, `stop`, `set_level` | `SHADE`, to export at all |
| `media` | `Powered`, `Source`, `Volume`, `Media` | view only | none |
| `lock` | `Locked` | `lock`, `unlock` | `LOCK`, for control |
| `gate` | `Open` | `trigger`, `open`, `close` | `GATE`, for control |
| `fan` | `Speed` (0 to 10) | `on`, `off`, `set_speed` | `FAN`, for control |
| `scene` | `Last_Run`, `Last_Result` | run by request | none |
| `button` | `Last_Pressed` | press | `BUTTON`, to export at all |

- **Media** shares a room, not a device: pick the room itself. `Source` is
  the name of the room's selected device. There is no control of a remote
  room.
- **Feature-gated kinds.** Thermostat, shade, lock, gate, fan and button
  actuate things this driver has no bench record for, so each is behind its
  own feature on the pair licence, off by default. A lock, gate or fan still
  exports with `View only` on any pair licence. The feature is checked again
  on every command.
- **A command is checked by the owner** before it touches the device: the
  export exists and is `Control allowed`, the operation is one it permits,
  the feature is licensed, commands are not paused, and the schedule is open.
  A refusal goes back with its reason. **Last Remote Command** on the owner
  shows the last one received.
- **Feedback only.** A command never writes an export's fields. The device's
  own variables do, when it reacts. `delivered` means the owner's bridge sent
  the command to the device, not that the device moved.
- **Unlock** also needs *Allow Unlock For Selected Export* on the owner,
  which is refused while `LOCK` is unlicensed. *Disallow Unlock For Selected
  Export* takes it back.
- **Control window.** `Set Export Schedule` permits control only on the days
  and between the hours you give, by the owner's own clock. The owner
  publishes a `Window` field, re-evaluated once a minute, and the device
  driver on the other side shows the window and refuses locally while it is
  closed. The owner enforces it as well. If the owner's clock reads a year
  before 2020, scheduled control is refused. `Clear Export Schedule` removes
  the window.

### Scenes and buttons

A scene export is a name with no device. On the owner: **Export Kind**
`scene`, an **Export Name**, *Export Selected Device*. The other bridge lists
it in **Remote Scene**; *Run Remote Scene*, or the command of the same name,
sends a request with a 120-second deadline. On the owner *Request Received*
fires, then the event named `Scene <Name> requested`. The owner's programming
performs the scene and reports with `Report Request Success` or
`Report Request Failure` on the slot whose `_Routine` reads `scene:` and the
name (slot 1 when nothing else is in flight). The result lands in
`<Name>_Last_Run` and `<Name>_Last_Result`, which the other side mirrors:
`completed` or `failed`, then the result text if one was given. There, the
event named `Scene <Name> completed` or `Scene <Name> failed` fires when the
report arrives; with no report by the deadline, *Request Expired* fires
instead. Nothing runs unless the owner's programming runs it.

A button export is a name too, and needs the `BUTTON` feature. The other
bridge lists it in **Remote Button**; *Press Remote Button*, or the command
of the same name, fires the event named `Button <Name> pressed` on the owner
and stamps `<Name>_Last_Pressed`. A press while `BUTTON` is not licensed is
ignored and **Last Error** says so.

### Publication filters

A filter thins what an owned item publishes. Select the item in **Selected
Item**, set the four **Filter** properties and press *Apply Filter To
Selected Item*.

| Property | Effect |
| --- | --- |
| **Filter Debounce Seconds** | The value is sent once it has stopped changing for this long |
| **Filter Change Threshold** | Numeric items only: a change smaller than this, measured from the last value sent, is not sent |
| **Filter Minimum Interval Seconds** | At most one publication in this time |
| **Filter Maximum Silence Seconds** | The last value is sent again after this long without a publication |

Filters apply to values only, never to events or requests, and restart with
the driver. Applying replaces the item's whole filter; applying with all four
at 0 changes nothing, so a filter cannot be removed this way in this build.

Apart from filters, a loop guard stops an item that publishes more than 30
times in 10 seconds: it is suspended for 60 seconds, *Loop Suspended* fires,
and changes made during that minute are not sent.

### Pausing

- *Pause Remote Commands* (or the command, with `MINUTES`) is local. For
  **Pause Minutes**, device commands coming in are refused and requests and
  device commands going out are refused. Values keep flowing, and requests,
  scene requests and button presses coming in still reach your programming.
  *Commands Paused* fires, and *Commands Resumed* when it ends or on *Resume
  Remote Commands*.
- *Pause Link* asks the relay to pause the whole link, until *Resume Link* or
  for **Link Pause Minutes** when that is above 0. Both bridges stop
  publishing and refuse remote commands; mirrors keep their last values and
  turn stale. Both sides see it on their next exchange and fire *Link Paused*
  and *Link Resumed*.

### Renaming and deleting

- **Rename an item.** Select it, type the new name in **New Item Name**,
  press *Rename Selected Item*. The bridge creates a variable under the new
  name and hides the old one, which is no longer updated. Programming written
  against the old name keeps pointing at the hidden variable: re-point it. On
  the other project a mirror appears under the new name, *Schema Attention*
  fires, and the old mirror stops updating. In this build the renamed mirror
  gets no `.STATE` variable; use *Shared Item Is Current* with the new name.
- **Delete an item.** *Delete Selected Item* stops sharing it. Its variable
  is kept, hidden, so a later item can never take its place in existing
  programming. On the other side the mirror's `.STATE` reads `unavailable`
  and *Schema Attention* fires. A mirror cannot be deleted from the mirror's
  side.
- **Rename or remove an export.** *Rename Selected Export* renames the
  selected export to **Export Name**, field by field, by the same rule; the
  device driver on the other project must then be linked to the new name.
  *Remove Selected Export* stops sharing it. Both print their effect in the
  Lua tab first.
- **Rename the prefix.** Type it in **New Namespace**. *Preview Namespace
  Rename* prints every variable the change would touch; *Rename Namespace*
  asks the relay, and both bridges apply it on their next exchange. Every
  variable under the prefix becomes a new variable with the current value,
  the old ones are hidden, and *Schema Attention* fires on both sides.
- A type cannot be changed. Delete the item and create a new one.

## Worked examples

### Away and Home between two houses

<!-- walkthrough: Tell New York that California is empty -->
1. On California's bridge choose `away-home — Away / Home coordination` in
   **Template** and press *Apply Template*. It creates
   `California_Home.Away` (a `BOOLEAN`) and `California_Home.System_Mode` (a
   `CHOICE` of `Home`, `Away`, `Vacation`) and prints the programming for
   both sides in the Lua tab.
1. In California's programming, where the house goes away, add `Set Local
   Boolean` with `ITEM` `Away` and `VALUE` `True`. Where someone arrives, the
   same with `False`.
1. In New York's programming, select the bridge's event
   *California_Home.Away changed (live)*. Add two conditions: the variable
   `California_Home.Away` is true, and *Shared Item Is Current* with
   `California_Home.Away` typed in. Inside them, run the "other house
   unattended" scene.
1. Test it. On New York's bridge pick `California_Home.Away` in **Selected
   Item**: **Selected Item Value** shows the value, its revision and the time
   it arrived.

The template gives `Away` a 5-second debounce: the value leaves once it has
held for 5 seconds, and a value that flips and flips back inside that time is
never sent. The steps the template prints guard with *Remote System Is
Ready* instead; that conditional is false whenever any mirror is `stale`,
which on a quiet link is common (see [Freshness](#freshness)).

### A request with a result

New York asks California to get the house ready and waits for the answer.

- New York: `Send Remote Request` with `ROUTINE` `Prepare_Home`, `PAYLOAD`
  `guests=3`, `DEADLINE` `120`. `New_York_Home.Request_1_Status` reads
  `accepted`, then `delivered` once California's bridge has it.
- California: *Request Received* fires. Under the condition that
  `California_Home.Request_1_Routine` is `Prepare_Home`, run the welcome
  programming, then `Report Request Success` with `SLOT` `1` and `RESULT`
  `lights on`.
- New York: *Request Completed* fires, `New_York_Home.Request_1_Result` reads
  `lights on`, and the conditional *Request Slot Status* with `1 completed`
  is true.

"Request received" is not "welcome finished": completion means what
California's programming says it means. If no result is confirmed within the
deadline, *Request Expired* fires; that means the result was not confirmed,
not that the work stopped. A result that arrives after the deadline is
recorded and fires nothing.

A request takes the lowest free slot on each side, and requests going out and
coming in share the slots. With more than one in flight, read
`Request_2_Routine` and so on to find the one you are handling.

### A gate pulse, on weekdays only, with real feedback

- California: export the relay that drives the gate as `Gate_Relay`, **Export
  Kind** `relay`, **Export Control** `Control allowed`, **Export Operations**
  `trigger`. Run `Set Export Schedule` once from programming with `NAME`
  `Gate_Relay`, `DAYS` `2,3,4,5,6` (1 is Sunday), `FROM` `07:00`, `TO`
  `22:00`.
- California: create a `BOOLEAN` item `Gate_Open` and set it from the gate's
  own position sensor.
- New York: add the Relay device driver for `Gate_Relay`. A pulse sent to
  its relay connection travels as `trigger`. Its **Control Window** reads
  `Mon–Fri 07:00–22:00` with the owner's time zone, and `closed now` outside
  those hours, when a pulse is refused on the spot.
- New York: announce "gate open" on *California_Home.Gate_Open changed
  (live)*, never on the pulse being accepted.

The `gate-request` template creates `Gate_Open` with a two-minute freshness
rule and prints these steps.

## The device drivers

Each device driver finds the bridge in its own project by itself; there is
nothing to bind between them. It asks the bridge for the exports of its kind,
shows the one chosen in its **Linked Export**, and is told of every change.
It shows only state the owner confirmed; a request is shown apart until the
device's feedback arrives.

| Driver | For | Appears in the project as |
| --- | --- | --- |
| SmartBuildOS System Link Light | a `light` export | A Control4 light |
| SmartBuildOS System Link Shade | a `shade` export | A Control4 blind |
| SmartBuildOS System Link Thermostat | a `thermostat` export | A Control4 thermostat |
| SmartBuildOS System Link Relay | a `relay` export | A relay connection to bind |
| SmartBuildOS System Link Contact | a `contact` export | A contact sensor connection to bind |
| SmartBuildOS System Link Temperature | a `temperature` export | A temperature connection to bind |
| SmartBuildOS System Link Media Room | a `media` export | Variables, events and conditionals; read-only |
| SmartBuildOS System Link Lock | a `lock` export | Variables, events and conditionals |
| SmartBuildOS System Link Gate | a `gate` export | Variables, events and conditionals |
| SmartBuildOS System Link Fan | a `fan` export | Variables, events and conditionals |
| SmartBuildOS System Link Export Light | the owner's side | A Light connection the real light is bound to; it creates the export |

Each has its own manual.

## Templates and configuration export

**Template** lists seven recipes: `away-home`, `guesthouse-occupancy`,
`remote-light`, `remote-thermostat`, `arrival-request`, `readonly-sensors`
and `gate-request`. *Print Template* prints what the recipe creates and the
programming to write on each side, with this bridge's prefix filled in.
*Apply Template* creates the recipe's shared items on this bridge, leaves
names that already exist as they are, and prints the same steps. A template
never writes Composer programming and never creates an export or a device:
those stay deliberate actions, named in the printed steps.

*Print Configuration Export* prints one line of JSON describing the link as
this bridge knows it: aliases and prefixes, groups, every item definition of
both sides and the device drivers the other side needs. It carries no
credential, invitation, licence or customer field, and refuses to print if it
finds one. Paste it into **Configuration Import** on a bridge. *Preview
Configuration Import* prints a verdict per item and writes nothing. *Apply
Configuration Import* creates the items that belong to this bridge's side,
with new ids, and leaves existing names alone. Exports and device drivers are
never imported.

## Programming reference

**Events**

- Link: *Link Connected*, *Link Disconnected*, *Peer Online*, *Peer Offline*,
  *Peer Stale*, *Initial Sync Complete*, *Remote State Current*, *Remote
  State Stale*, *Link Paused*, *Link Resumed*, *License Changed*.
- Values: *Remote Variable Changed Live*, and one event per mirror named
  `<Prefix>.<Name> changed (live)`. *Schema Attention* fires when the other
  side renamed, removed or changed a definition, and after a prefix change.
  *Loop Suspended* fires when the loop guard stops an item.
- Events and requests: *Named Event Received*, *Request Received*, *Request
  Completed*, *Request Expired*, *Commands Paused*, *Commands Resumed*.
  *Request Failed* fires when the other side reports a failure or has no
  free slot, or when the relay refuses the request. *Request Outcome
  Unknown* is declared, but this build never fires it.
- Per export: `Scene <Name> requested` on the owner, `Scene <Name> completed`
  and `Scene <Name> failed` on the other side, `Button <Name> pressed` on the
  owner.

**Conditionals**

- *Remote System Is Ready*: **Remote System State** is `Ready`.
- *Link Is Synchronized*: the initial sync is complete and the relay is still
  reachable.
- *Remote Commands Are Permitted*: there is a link, nothing is paused and the
  licence is in order.
- *Shared Item Is Current*: type the item name, with or without its prefix.
- *Request Slot Status*: type the slot and the status, as in `1 completed`.
  Statuses are `accepted`, `delivered`, `running`, `completed`, `failed`,
  `expired` and `unknown`.

**Commands**

| Command | Parameters | Does |
| --- | --- | --- |
| `Set Local Boolean` | `ITEM`, `VALUE` (`True` or `False`) | Sets an owned item. `ITEM` is the name, with or without the prefix |
| `Set Local Integer`, `Set Local Decimal`, `Set Local String`, `Set Local Choice` | `ITEM`, `VALUE` | The same, for the other types. A value the item does not accept is refused in **Last Error** |
| `Emit Named Event` | `EVENT`, `PAYLOAD`, `TTL` (1 to 600 seconds, default 30) | Sends a one-time event. Names starting with `__sl_` are reserved |
| `Send Remote Request` | `ROUTINE`, `PAYLOAD`, `DEADLINE` (5 to 3600 seconds, default 120) | Asks the other project to run a routine and waits for its result |
| `Report Request Progress` | `SLOT` (1 to 32) | Marks the request in that slot `running` |
| `Report Request Success`, `Report Request Failure` | `SLOT`, `RESULT` | Ends the request with a result text. Only the side that received it can report |
| `Pause Remote Commands` | `MINUTES` (1 to 43200, default 60) | Pauses remote commands locally |
| `Resume Remote Commands` | none | Ends the local pause |
| `Run Remote Scene` | `SCENE` | Asks the other project to run its exported scene |
| `Press Remote Button` | `BUTTON` | Presses the other project's exported button |
| `Set Export Schedule` | `NAME`, `DAYS`, `FROM`, `TO` | Sets the control window of an export. `DAYS` is a comma list, 1 for Sunday to 7 for Saturday; times are `HH:MM`, controller local; `FROM` later than `TO` runs overnight |
| `Clear Export Schedule` | `NAME` | Allows control at any time again |
| `Export Device` | `DEVICE`, `NAME`, `KIND`, `CONTROL`, `OPS` | The scripted form of *Export Selected Device*, for the kinds `light` to `media` |
| `Remove Export` | `NAME` | Stops sharing an export |

**Variables** are created as items and exports are made; see
[The variables the bridge creates](#the-variables-the-bridge-creates).

## Properties and Actions

| Property | What it is for |
| --- | --- |
| **Selected Item**, **Selected Item Details**, **Selected Item Value** | Pick an item; read whether it is owned or a mirror, its type and group, and its value, revision and time. For a mirror's freshness read its `.STATE` variable |
| **Request Slots** | How many requests can be in flight (default 4). The count is fixed the first time the bridge stores its state, at the latest when it gets its link; in this build a later change is not applied, even after a restart |
| **Evaluate State After Initial Sync** | `Yes` fires every mirror's event once after each sync |
| **Pause Minutes**, **Link Pause Minutes** | Length of a local pause; length of a link pause, 0 for until resumed |
| **Log Level**, **Log Mode** | Logging to the Lua tab and the log |
| **Link Credential Backup** | Written by the driver so the link survives a driver update. Not editable |

| Action | What it does |
| --- | --- |
| *Print Shared Items*, *Print Exports* | Lists in the Lua tab |
| *Add Companion For Selected Item* | Adds the device driver for the export that the mirrored field in **Selected Item** belongs to |
| *Refresh Link* | Asks the relay for a fresh snapshot and repaints the lists |
| *Run Link Test* | Stops at the first failure (not provisioned, relay disconnected, other bridge not online) or sends a ping that the other bridge answers by itself, and prints the round trip |
| *Generate Diagnostics* | Prints a summary with no values in it and sends a short status event to SmartBuildOS |
| *Re-provision Link* | Asks the Agent for the link again |
| *Forget Link* | Deletes the stored link credential and stops exchanging. Items and last values are kept; *Re-provision Link* resumes |
| *Refresh License* | Asks the Agent for the licence again |

The **New Item**, **Device Exports**, **Pending Export**, **Remote Scene**,
**Remote Button**, **Template** and **New Namespace** properties, and the
other actions, are described where they are used above.

## Reading the status

| Property | Reads | Meaning, and what to do |
| --- | --- | --- |
| **Link Authorization** | `Not provisioned — approve the link in System Studio` | No link yet. Finish it in Studio; the bridge asks again every minute |
| | `No SmartBuildOS Agent found — add the free Connector first` | Install and pair the Agent |
| | `The SmartBuildOS Agent did not answer the link request …` | Update the Agent to a build with System Link support |
| | `Agent:` and a reason | The Agent could not get the link, and says why. Asked again every minute |
| | `approved` | The link is live |
| | `Forgotten …` | *Forget Link* was used; press *Re-provision Link* |
| **Relay Connection** | `disconnected` | The relay cannot be reached. **Last Error** has `relay:` and the cause; check the site's internet |
| | `connected · doorbell` or `connected · polling every 20 s` | Working. Polling adds up to 20 seconds to what arrives |
| **Peer Status** | `online`, `stale`, `offline` | The other bridge's heartbeat. If `offline` while this side is connected, look at the other site |
| **Sync Status** | `synced` | Live. `stale_marked` means it is waiting for the relay; other values are the steps in between |
| **Remote System State** | `Ready`, or another state and its reason | See the table under [Freshness](#freshness) |
| **Command Suspension** | `Active`, `Local until …`, `Paused by link` | Whether remote commands are permitted |
| **Doorbell**, **Poll Interval** | `not joined`, `joined · never rang — polling` or `joined · silent since` and a time; `20 s` | The bridge relies on the poll. `doorbell-driven` means the doorbell is working and the poll is only a backstop |
| **Last Relay Refusal** | An item or message, a reason and a time | The last thing the relay refused |
| **Measured Latency**, **Relay Latency** | `p95` and a time | How long the relay took to accept a publication, over the last 50. Not the full path to the other site |
| **Pending Updates**, **Pending Requests**, **Pending** | Counts | Messages waiting to be sent and requests in flight. A count that keeps growing means the relay is not being reached |
| **Last Error** | Text | The last refusal: a bad name, a write to a mirror, a missing device, a relay rejection. A dealer's refusal stays until the next action |

Also: **Local Variables Created** and **Remote Variables Monitored** count
the items of each side, **Last Sync** and **Last Heartbeat** give the times,
**Schema Revision** counts definition changes, **Driver Version** and
**Installed Version** show the driver's version, and **License State**,
**License Source**, **Subscription Tier** and **SmartBuildOS Company** come
from the Agent. The **Link Health** group is repainted every second.

## Security and privacy

- **Credentials.** The bridge never holds the Agent's own credentials. The
  Agent hands it a credential that is good for this link only. It is stored
  encrypted on the controller, copied into the hidden **Link Credential
  Backup** property, asked for again on every start and whenever the relay
  refuses it, and deleted by *Forget Link*.
- **Transport.** Outbound HTTPS to the SmartBuildOS relay; a relay address
  that is not HTTPS is refused. The doorbell is a secure WebSocket that
  carries no content: a ring only makes the bridge fetch.
- **What crosses.** Only items created with **New Item Export** on `Yes` and
  the fields of exports: their names, descriptions, groups and values, and
  for an export its kind, permitted operations and schedule. Nothing else in
  a project is visible to the other. A media export sends the name of the
  room's selected device and its media text. The id of an exported device
  never leaves its controller.
- **What SmartBuildOS also receives.** With the heartbeat: the count of
  waiting messages, the latency, the doorbell state, the last refusal, and
  for each device driver this bridge added, the export name and the device's
  id. On sign-in: the driver version and the controller's time zone. A named
  event carries the sender's time zone.
- **What a remote message can do.** Update a mirror; write the request and
  event variables and fire their events; send one of the listed operations to
  an exported device whose owner chose `Control allowed`. There is no remote
  Lua, shell or Composer command. A message from an older controller
  generation, a duplicate, an expired event, request or command, and
  anything in an answer larger than 32 KB are dropped.
- **Control is opt-in, per export**, by the owner: `View only` by default, a
  list of permitted operations, an explicit unlock permission, a schedule,
  and the pause actions.
- **Diagnostics.** *Generate Diagnostics* prints the link's ids and item
  names, types, revisions and states, never values. The event it sends
  carries the state, the counts and the latency.
- The link can be revoked in System Studio from either system. The bridge
  then reads `Paused — link revoked`, and requests in flight end as
  `unknown`.

## What is not claimed

- **No bench record.** This repository holds no bench record for System Link.
  What this page describes is what the driver's test suite checks, against a
  simulated relay and a simulated controller. The link setup in System
  Studio, the licence rules and the relay's own limits are SmartBuildOS's and
  are not part of this driver.
- **No delivery time is promised.** It depends on both sites' internet.
  Events are not queued and nothing is replayed.
- **One link per bridge**, with one other system. No mesh. Links between two
  organizations are not supported in this release.
- **A remote room cannot be controlled**, and the Media Room, Lock, Gate and
  Fan device drivers have no proxy in this release: they are variables,
  events and conditionals only.
- **Freshness on a quiet link.** Nothing confirms an unchanged value between
  snapshots, so a healthy link can read `Stale`; see [Freshness](#freshness).
- Limits of this build named above: **Request Slots** cannot be changed after
  the first link, a filter cannot be removed, a renamed mirror has no
  `.STATE` variable, and *Request Outcome Unknown* never fires.

<!-- #embed-changelog -->
