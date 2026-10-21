# SmartBuildOS System Link

Links two Control4 projects anywhere in the world through SmartBuildOS. Each
project creates and owns its shared variables; the other project sees them as
read-only mirrors. Named events, request/result routines and authorized native
companions cross the link. Automation stays in Composer: System Link transports
state, explicit events and authorized control requests. It is not a cloud
automation engine.

This page distinguishes **documented behaviour** (what the driver does, as
tested in its simulated suite), **tested compatibility** (verified on a physical
controller — see "Hardware validation") and **planned** capabilities
(feature-gated, off by default).

## Requirements

- The **free SmartBuildOS Connector** (`smartbuildos.c4z`, shown in Composer as
  SmartBuildOS Agent) activated on **both** projects. System Link never holds
  the Connector's credentials; the Agent provisions a narrow endpoint credential
  for the link.
- One **System Link Pair license** per link. It covers exactly two systems,
  their current primary controllers, the bridge on both and the companion
  drivers. No full SmartBuildOS subscription is required.
- Control4 OS 3.3.2 or later on both controllers. Outbound HTTPS only; no
  inbound port forwarding.

## Pair licensing and trial

- A pair license is bought once in the SmartBuildOS Driver Store (or issued by
  SmartBuildOS with an activation code) and attached to one link during guided
  setup. A third system cannot activate on it: the platform refuses it, and the
  database refuses it independently.
- **Seven-day trial.** The trial starts the first time a link is approved and is
  server-authoritative. Reinstalling, reconnecting, updating, renaming,
  restoring a project or replacing a controller never restarts it.
- When a trial ends the bridge stops publishing and stops accepting remote
  commands; mirrors keep their last values and show `stale`. Status,
  diagnostics, documentation and update checks keep working. Nothing physical
  changes.
- **License Status** on the driver reads the Agent's answer for the pair
  (`Licensed / Trial`, `Licensed / Permanent`, `Agent Linked - Not Licensed`).

## Guided link setup

Done in **System Studio → Connections → System Link** with Composer alongside:

1. Activate the Connector on both projects (pairing code, as today).
1. Add **SmartBuildOS System Link** to both projects (one instance each).
1. In Studio, start a link: pick the pair license (or enter the activation code)
   and the first system, and give it an **alias** (for example "California
   Home"). The alias becomes the Composer variable prefix (`California_Home.`)
   on both sides and is frozen at approval.
1. Create an **invitation**: a `LINK-XXXX-XXXX` code, valid ten minutes, single
   use, five attempts.
1. **Join** from the other system with the code and its own alias.
1. **Review** both installation identities (system, paired controller, Connector
   version).
1. **Approve.** Both endpoints activate; each bridge asks its Agent for a
   credential, connects to the relay and completes the initial sync.
1. Create shared items with the Composer actions on the owning bridge, then export devices. Studio shows them read-only.
1. Run **commissioning** (Studio) and keep the report.

Cancelling, expiry, rejection and retries are supported at every step; the
link's state is stored server-side so a closed browser resumes where it was. One
link holds exactly two endpoints; a system can be on one link at a time.

## Shared variables

Create one with the Composer **Create Shared Item** action after filling the
"New Item" properties. Studio shows items and their committed values but does
not create or edit them: all configuration is done in Composer on the bridge.

| Type    | Composer variable type | Notes                                 |
| ------- | ---------------------- | ------------------------------------- |
| BOOLEAN | BOOL                   | `1` / `0`                             |
| INTEGER | NUMBER                 | optional min/max                      |
| DECIMAL | FLOAT                  | optional min/max/precision (0–6)      |
| STRING  | STRING                 | max length 256 by default, up to 4096 |
| CHOICE  | STRING                 | validated against the allowed values  |

Export kinds: light, relay, contact, temperature, thermostat and shade present a
device natively through a companion; **media** shares a ROOM's playing state
(powered, source name, volume, media info) read-only through the Media Room
companion — pick the room itself as the device. No control verb exists for a
remote room in this release.

Optional schema per item: description, group, units, allowed values,
minimum/maximum, precision, string length, export on/off, freshness policy
(`max_age_s`), publication filter.

Naming: `<OwnerAlias>.<Name>` on both systems. `California_Home.Away` and
`New_York_Home.Away` never collide. Every mirror also has a `<name>.STATE`
STRING variable: `current`, `stale`, `unknown` or `unavailable`. `false`, `0`
and `""` are real current values; `unknown` (never observed) and `unavailable`
(the owner cannot read it) carry no value.

**Ownership.** Only the owning project writes an item, and that is enforced five
times over: in the driver's commands, in the native read-only flag, at the relay
(per item, in the database), in the backend service and in Studio. A mirror is
never republished as a change of its own. Unsharing (Export = No or Delete)
keeps the owner's local variable.

**Stable identities.** An item's id, registration order and Composer variable id
never change. Deleting an item hides its variable instead of freeing its id, so
later items can never inherit programming. Renaming creates the new name and
hides the old one; the Rename action prints the effect to Lua Output first.
Types cannot be changed in place.

## Composer programming

Actions (Actions tab): Create Shared Item, Rename Selected Item, Delete Selected
Item, Apply Filter To Selected Item, Print Shared Items, Refresh Link, Run Link
Test, Pause/Resume Remote Commands, Generate Diagnostics, Re-provision Link,
Forget Link, Refresh License.

Commands (Programming tab, with parameters): Set Local Boolean / Integer /
Decimal / String / Choice (`ITEM` is the item name, with or without the alias
prefix), Emit Named Event (`EVENT`, `PAYLOAD`, `TTL`), Send Remote Request
(`ROUTINE`, `PAYLOAD`, `DEADLINE`), Report Request Progress / Success / Failure
(`SLOT`, `RESULT`), Pause Remote Commands (`MINUTES`), Resume Remote Commands.

Events: Link Connected / Disconnected, Peer Online / Offline / Stale, Initial
Sync Complete, Remote Variable Changed Live, Remote State Current / Stale, Named
Event Received, Request Received, Request Completed / Failed / Expired / Outcome
Unknown, Schema Attention, License Changed, Commands Paused / Resumed, Loop
Suspended, Link Paused / Resumed. Each mirrored item also gets its own
`<name> changed (live)` event.

Conditionals: Remote System Is Ready, Link Is Synchronized, Remote Commands Are
Permitted, Shared Item Is Current (type the item name), Request Slot Status
(type `1 completed`, `2 failed`, …).

### Initial state versus live change

On every start the driver restores last-known values, marks mirrors stale,
authenticates, reconciles definitions and revisions, applies the current
snapshot, then fires **Initial Sync Complete**. Nothing before that moment is a
live change: **Remote Variable Changed Live** and the per-item events fire only
afterwards. Events and requests are never replayed on restoration.

Control4's native "When variable changes" trigger behaviour on a restored value
is **not documented by Control4**; until measured on a controller, guard native
variable triggers with the **Link Is Synchronized** conditional, or use the live
events. Dealers who want to evaluate current remote state after a sync can set
**Evaluate State After Initial Sync = Yes**, which fires the live events once
right after Initial Sync Complete.

### Example: Away/Home coordination

California: create `Away` (BOOLEAN). Programming: when the house goes away →
`Set Local Boolean ITEM=Away VALUE=True`.

New York: when `California_Home.Away changed (live)` fires and
`California_Home.Away` is `1` and Remote System Is Ready → run the "guest house
unattended" scene.

### Example: request with result

New York:
`Send Remote Request ROUTINE=Prepare_Home PAYLOAD=guests=3 DEADLINE=120`. Then,
when **Request Completed** fires and Request Slot Status is `1 completed`,
announce it.

California: when **Request Received** fires and
`California_Home.Request_1_Routine` is `Prepare_Home` → run the welcome
programming, then `Report Request Success SLOT=1 RESULT=lights on`. "Message
received" is not "welcome sequence finished": completion means what your
programming says it means. A timeout means the result was not confirmed, not
that the work stopped; a late result is recorded in the slot but never fires a
follow-up.

## Templates (Properties tab)

**Template** lists seven setup recipes (Away/Home coordination, guesthouse
occupancy, remote light, remote thermostat, arrival request with result,
read-only sensors, gate request with feedback). **Print Template** prints what
the recipe creates and the Composer programming to write on each side, with
`<Owner>` replaced by this bridge's prefix. **Apply Template** creates the
recipe's shared items on this bridge (names already present are left as they
are) and prints the same steps. A template never writes Composer programming and
never creates an export or a companion: those stay deliberate actions, named in
the printed steps. Recipes that involve control say so.

## Configuration export and import (Properties tab)

**Print Configuration Export** prints one JSON line describing the link's
configuration as this bridge knows it: aliases and namespaces, groups, every
item definition (its own and the peer's mirrors, by owner role) and the
companion kinds the other side needs. It carries no credential, invitation,
licence, controller assignment or customer field, and refuses to print if any
such field is present. Paste it into **Configuration Import** on a bridge and
run **Preview Configuration Import** (prints what would be created, per item
verdict, nothing written) or **Apply Configuration Import** (creates the items
whose owner role is this bridge's, with new ids; names already present are left
as they are). Exports and companions are never imported; the preview says so.

## Device exports (Properties tab)

A device is shared with the linked project from the **Device Exports** block on
the bridge's Properties tab, not from a programming command: pick **Export
Kind**, pick the device in **Export Device** (listed as `Name (Room) · id`; by
default only devices that carry the variables the kind reads, so a light's
physical driver, which usually shares the name, is left out — **Export Device
Filter = All devices** shows it flagged), fill in **Export Name** (prefilled
from the device name when empty; letters, digits and underscores), **Export
Control** and optional **Export Operations**, then run **Export Selected
Device**. A refusal stays in **Last Error** and is printed to the Lua tab with
the reason. **Refresh Export Device List** rebuilds the list after a device is
added. The `Export Device` programming command still exists for scripted setups.

Existing exports are listed in **Selected Export**. **Rename Selected Export**
renames the selected one to **Export Name** (every field variable keeps its id;
the old names become hidden tombstones; the companion on the linked project must
be re-linked to the new name) and **Remove Selected Export** stops sharing it
(its variables stay hidden and are never reused). Both print their effect to the
Lua tab first.

On the receiving project, **Pending Exports** lists what the linked project
shares that has no companion device here yet (`MBR_Baseboard (light)`). Pick it
in **Pending Export** and run **Add Companion For Pending Export**: the bridge
adds the matching companion driver and links it to the export in one step. The
list follows the link, so a new export shows up within a sync.

## Publication filters

Per owned item, optional: debounce/stability seconds, numeric change threshold,
minimum publication interval, maximum silence (refresh). Filters apply to state
only; events are never filtered. The source value and the published value are
kept apart; filter delay is reported separately from transport latency in the
state message. Defaults publish immediately.

## Locks, gates, fans and buttons (feature-gated)

These kinds actuate things that no controller has validated yet, so their
CONTROL is behind its own licence feature (`LOCK`, `GATE`, `FAN`, `BUTTON`),
off by default (decision SL-07). Status needs nothing: a lock, gate or fan
exported with **Export Control = View only** shares `Locked`, `Open` or
`Speed` on any pair licence, and the Lock, Gate and Fan companions show it
with events and conditionals. With the feature on the pair, **Control
allowed** opens the ops (lock/unlock; trigger/open/close on the relay that
drives the door; on/off/set_speed 0–10), checked again on every command.
**Unlock** additionally needs **Allow Unlock For Selected Export** on the
owner, refused while LOCK is unlicensed, and is never retried. A **button** is
pure control: the owner exports a name, the other side's **Press Remote
Button** (action or programming command) fires **Button <Name> pressed** on
the owner and stamps `<Name>_Last_Pressed`; a press while BUTTON is not
licensed is ignored and says so. The source variable names are the ones Mode
Composer's adapters read in the field.

## Scenes across the link

A **scene** export is a name, no device. On the owner: Export Kind = scene,
Export Name, Export Control = Control allowed → Export Selected Device. The
other side lists it in **Remote Scene**; **Run Remote Scene** (action, or the
programming command of the same name with `SCENE`) sends a request with the
routine `scene:<Name>`. On the owner, **Scene <Name> requested** fires: the
dealer's programming performs the scene, then **Report Request Success /
Failure** on the slot, and the result lands in `<Name>_Last_Run` /
`<Name>_Last_Result`, mirrored on the other side. There, **Scene <Name>
completed / failed** fires when the report arrives (a timeout means the outcome
was not confirmed, as with any request). Nothing runs unless the owner's
programming runs it.

## Control windows on companions

When an export has a schedule (Set Export Schedule), the owner publishes a
`<Name>_Window` BOOLEAN field that it evaluates once a minute with its own
clock, the only clock that can. The companion on the other side shows the
schedule in **Control Window** ("Mon–Fri 07:00–22:00 (America/New_York) — closed
now") and, while it is closed, refuses a command locally with the window named
in **Last Result** (and fires Control Refused) instead of a round trip that
comes back "outside the permitted schedule". The owner still enforces the
schedule itself.

## Freshness and Remote System State

Each mirror tracks last source update and last confirmation. A value that has
not changed for hours stays `current` while the owner keeps confirming it (every
snapshot and reconnection confirms); it becomes `stale` only when no
confirmation arrives within its policy (default 15 minutes).

**Remote System State** (property and conditional) is one of License Attention ›
Paused › Offline › Synchronizing › Stale › Ready, in that precedence, with a
reason. The separate properties Relay Connection, Peer Status, Sync Status and
License State show the underlying states. A peer heartbeat proves the peer
driver is present, not that its devices work.

## Transport, latency and limits

Outbound HTTPS to SmartBuildOS with a per-endpoint credential; a contentless
Realtime "doorbell" socket makes delivery immediate; a 20-second poll covers a
dead socket; heartbeats every 30 s. Messages are bounded (32 KB frame, 4 KB
payload, 200 items per state message); the relay rate-limits and rejects
unauthorized, malformed, oversized, expired and obsolete-generation messages. No
remote Lua, shell or Composer command execution exists.

Engineering target: 95 % of ordinary updates applied at the receiving driver
within 3 seconds of acceptance by the publishing driver. **Measured Latency**
shows p95 of local-accept → relay-commit; the Commissioning recorder measures
the full path. This is a target under healthy networks, not an internet SLA.
Practical limits: a few hundred items and a few messages per second per link
before the loop guard (30 publications per item per 10 s) and relay budgets (600
messages per minute per link) engage.

## Offline behaviour and persistence

Definitions, last values, revisions, pending updates, link membership, request
slots and the deduplication ring are persisted on the controller and mirrored on
the relay. A normal reboot, Director restart or driver update does not reset
values. Persistence is written by Director about twice a second; an abrupt power
loss can lose up to about one second of state, which the relay snapshot restores
on reconnection. An old project backup never overwrites newer committed state:
the relay's revision wins and the driver reports `stale_backup` in Last Error.

## Controller replacement and updates

Replace a controller with the normal Connector re-pair, then confirm the new
controller in Studio (Change Primary Controller). The endpoint's generation
increments; the old credential dies; the peer drops anything from the old
generation. Moving an endpoint to a different property is a reassignment, not a
replacement: it revokes the endpoint and needs a new invitation.

Updates use the existing Agent update path. Studio shows installed and available
versions on both endpoints and refuses an update that would leave the two
bridges on incompatible protocol versions.

## Namespace rename and pausing the link

The namespace (the Composer prefix, frozen at approval) is owned by the relay.
**New Namespace** + **Preview Namespace Rename** prints every variable the
change would touch on this bridge (items, the mirrors' `.STATE` twins, request
slots and `Last_Event_*`); **Rename Namespace** asks the relay on the next sync,
and both bridges apply the change when they see it: the old names become hidden
tombstones (ids never change, programming keeps pointing at them), the new names
get new ids with the current values, and **Schema Attention** fires on both
sides. A relay that refuses the name says why in Last Error; an older relay that
cannot answer is reported too.

**Pause Link** asks the relay to pause the whole link (both bridges stop
publishing and refuse remote commands; mirrors keep their last values and go
stale) until **Resume Link**, or for **Link Pause Minutes** when set above 0.
Both bridges see the change on their next sync and fire **Link Paused** / **Link
Resumed**. Pause/Resume Remote Commands remain the lighter, local option.

## Link Health (Properties tab)

A read-only group with the transport facts: **Doorbell** (whether the relay's
instant-notification channel is joined and when it last rang; "never rang" means
the bridge relies on the poll), **Poll Interval** (20 s, or doorbell-driven with
the poll as a backstop), **Last Relay Refusal** (the last message the relay
refused, with reason and time), **Relay Latency** (p95 from local accept to
relay commit) and **Pending** (updates and requests waiting). All of it is
repainted every second from the bridge's own state.

**Run Link Test** (Actions) reports the first failure it hits — not provisioned,
relay disconnected, peer offline — or sends a ping through the relay to the
other bridge, which answers from inside its driver (no programming on either
side), and prints the round trip, whether the doorbell drove it, and the licence
state. Event names starting with `__sl_` are reserved for this and cannot be
emitted from programming.

## Diagnostics and privacy

Generate Diagnostics prints a redacted summary (no variable payloads) and sends
a redacted event to SmartBuildOS. Only selected items cross the link; nothing
else from either project is visible to the other. Either endpoint can revoke the
link in Studio.

## Known limits

- One peer per bridge pair (no mesh).
- Cross-organization links are not supported in this release.
- Request Slots change takes effect after the next Director restart.
- Companion drivers: see the Companions section of the SmartBuildOS
  documentation for what is feature-gated.

## Hardware validation

None yet. Everything above is verified in the driver's simulated test suite and
against the platform's own test suite; nothing here has been exercised on a
physical controller. See `docs/system-link/HARDWARE-VALIDATION.md` in the
SmartBuildOS repository for the test record.

<!-- #embed-changelog -->
