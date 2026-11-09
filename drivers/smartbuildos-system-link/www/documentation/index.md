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

- Control4 OS 3.3.2 or later and the free SmartBuildOS Agent build
  `20261109.044817` or later on both projects. The earlier Agent does not
  provision System Link. Pair both Agents to sites in the same dealer company.
- Outbound HTTPS from both controllers. No inbound ports are required.
- Professional and higher includes System Link. Eligible systems below
  Professional can start one seven-day pair trial. The beta does not open
  checkout for new standalone purchases.

## Set up a link

1. Update and pair the SmartBuildOS Agent on both projects. In Composer Pro, add
   one SmartBuildOS System Link bridge per project.
1. Open **System Studio → Connections → System Link**. Start a link using
   **Included with your plan**, **Start a free 7-day trial**, or an existing
   pair license. Pick the first system and give it a unique alias.
1. Create a link invitation. Join using the second system and a different alias.
   Check both controller identities and approve the pair. A trial starts on
   approval; reinstalling or replacing a controller does not restart it.
1. In Composer, use **Refresh Link** or **Re-provision Link** if needed. Wait
   for both bridges to show an approved link and **Initial Sync Complete**.
1. Create a read-only test item on one bridge. Change it and check the remote
   mirror, then use **Run Link Test**. Enable authorized control only after both
   sites have been commissioned.

If the trial ends, the bridge stops sharing changes and accepting remote
control. Mirrors retain their last values and show stale. Status and diagnostics
remain available. The Agent provisions a credential for the approved pair; never
copy the Agent token into a bridge.

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

## Publication filters

Per owned item, optional: debounce/stability seconds, numeric change threshold,
minimum publication interval, maximum silence (refresh). Filters apply to state
only; events are never filtered. The source value and the published value are
kept apart; filter delay is reported separately from transport latency in the
state message. Defaults publish immediately.

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

## Composer configuration recipes

All configuration is performed on the bridge in Composer. System Studio remains
monitoring, pairing and licensing only.

Choose **Programming Template** and **Template Side**, then **Print Template**
to review the steps for both projects. **Apply Template** creates that side's
ordinary shared items with unknown initial values. The seven recipes are
Away/Home, guesthouse occupancy, remote light, remote thermostat, arrival
request/result, read-only sensors and gate request with feedback. Existing names
refuse the entire batch. Recipes never create physical exports, enable control
permissions, add companions or inject Composer programming. Complete the printed
owner/peer steps explicitly. Thermostat/shade gates still apply.

## Configuration export and reviewed import

1. Run **Export Configuration**. Save the single JSON document printed in
   Composer's Lua output. It uses the platform's version-1 format and carries
   item definitions, groups and companion requirements. It excludes current
   values, credentials, controller assignments, equipment IDs and control
   permissions. Friendly names and descriptions are included; review these
   before sharing the document. Limit: 128 items and 65,536 bytes per document.
1. On the destination bridge, paste that document into **Configuration JSON**.
   Set **Import Local Role** to the source document role (`a` or `b`) that
   should become this project. This mapping is independent of the live link's
   own A/B role. Import the other role separately on its own bridge.
1. Run **Preview Configuration Import**. Review **Configuration Result** and Lua
   output. Preview makes no changes. Invalid items and duplicate local names
   refuse the entire batch. Equipment-export fields are skipped: recreate them
   through **Export Device**, map the real equipment, choose permissions, and
   add the companion explicitly.
1. Run **Apply Configuration Import** to confirm the exact preview. Changing the
   JSON, role, endpoint generation or registry invalidates the preview. Each
   imported item receives a new ID and unknown initial value. Existing items and
   the remote project's definitions are untouched. A preview is single-use and
   is lost on driver reload. Successful import clears the input.
1. Rebind the intended Composer programming, configure actual feedback and
   repeat commissioning. Imported definitions never execute equipment actions.

## Namespace rename with effect preview

Choose **Namespace Endpoint** (Local or Remote) and **New Namespace**, then run
**Preview Namespace Rename**. The Lua output lists old/new native variable
names, including request slots for a local namespace. Run **Apply Namespace
Rename** only after reviewing that list.

This is a local naming override on the current bridge; repeat on the other
bridge if matching display prefixes are wanted there. Relay namespace, endpoint
and item IDs, ownership, revisions, companion mappings and event IDs do not
change. The override survives reboot and re-provisioning of the same endpoint.

There is no verified native variable-rename API in this implementation. New
names receive new native variable IDs. Old names remain hidden tombstones in
their original registration slots and stop receiving updates. **Rebind any
Composer programming that references the affected native variables.** New names
keep current item values; new request/event context variables begin empty unless
an existing request context can be restored. Identical peer prefixes and any
previously used target native names are refused. Preview is required, single-use
and invalidated by definition or variable-list changes.

## Whole-link suspension

**Pause Link** uses **Pause Minutes** (1–43,200). The Programming tab also
exposes **Pause Link** with a MINUTES parameter and **Resume Link**. This
suspends this bridge's entire relay data path, including explicit Refresh Link
requests and responses already in flight. The pause and its deadline persist
across restart. **Link Suspension** shows the deadline; Remote System State is
Paused. The peer eventually sees stale/offline presence because no heartbeat is
sent. The contentless doorbell listener may remain connected, but cannot
transfer or apply relay payloads while paused.

Local automation and owned values continue to work. Only schema and current
state remain queued; pending commands/events are discarded and outstanding
requests become outcome unknown. A previously dispatched action might already
have executed: suspension is not cancellation of physical equipment.

Manual resume or expiry requests a fresh snapshot and reconciliation. State
restores without live-update events unless **Evaluate State After Initial Sync**
is explicitly enabled. Pre-resume commands, requests and one-time events are
skipped across every relay page, including after restart; they are never
replayed. Commands created after the resume snapshot can run normally. A
whole-link resume does not clear the separate remote-command suspension. These
are controller-local controls; they do not change Studio settings or silently
resume a server-side administrative suspension.

These configuration workflows have unit/simulation and local package checks.
Composer rendering, native variable tombstones/rebinding, persistence across a
real Director restart and physical companion behavior still require bench
validation on both controllers.
