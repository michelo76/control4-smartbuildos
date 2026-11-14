# VenueFlow and SmartBuildOS

VenueFlow is a SmartBuildOS Driver Store product. A dealer who buys only the
driver gets everything in this repository's driver: both pages, every
interface, the Studio, local configuration. A dealer on the full platform is
meant to get multi-venue features on top. This document says exactly what is
built, and what is not.

## Built and tested

| Integration | How | Evidence |
| --- | --- | --- |
| Licensing through the SmartBuildOS Agent | `sbos.license` with SKU `SBOS_VENUEFLOW`; `EC.SBOS_ENTITLEMENT`; the standard properties License Status, License Source, Subscription Tier, SmartBuildOS Company; the driver action Register With Agent Now | `test_driver_license_guard.lua`, `test_venueflow_driver.lua` [1] and [8], `test_venueflow_license.lua` |
| The existing licensing model, unchanged | No second licensing system, no account credential in the driver, no call to a licensing API. The Agent is the only authority; the controller binding and the ten-day grace policy are the Agent's (`AUTHORIZED_GRACE` is a fully working status here) | same |
| Fail open | No Agent, unreachable cloud, unauthenticated Agent, grace, unknown status: nothing is restricted | `test_venueflow_license.lua` "when the licensing SDK enforces" |
| Activity in the project's common history | Markers to the Flight Recorder (`RECORD_EVENT`, channel `venueflow`) when one is in the project: driver start, publish, rollback, scene and rule runs, venue open and close, All Off, control mode, notifications | `test_venueflow_driver.lua` [1] |
| Alerts and notifications into Control4 programming | Events Scene Activated, Notification, Alert Raised, Configuration Published, Venue Opened, Venue Closed, Licence Restricted, Licence Restored; variables VENUE_STATUS, ACTIVE_SCENE, NOTIFICATION_TEXT, ALERT_COUNT. A dealer wires them to the Notification Router or any agent in Composer | `test_venueflow_driver.lua` [7] |
| Same repository, build and update conventions | `drivers/smartbuildos-venueflow`, `DRIVER_FILENAMES`, the monorepo's build, guards and manuals | `make test` |

Local operation never needs SmartBuildOS: the operator page, selection,
routing, audio, scenes, the configuration and state updates are all on the
controller (`test_venueflow_license.lua` "cloud outage").

## Not built: needs the Agent, the web repository, or both

These are outside this repository's driver, or change contracts that other
components own. Nothing here was touched in production.

### 1. Entitlement issuing (blocks selling, not running)

- Web repository: a SKU catalogue row for `SBOS_VENUEFLOW` (name, price,
  whether it is included in a subscription tier), and the Driver Store
  listing.
- Agent (`drivers/smartbuildos/driver.lua`): add `smartbuildos-venueflow.c4z`
  to the Agent's `DRIVER_FILENAMES` so the Agent's updater carries it.

Until the SKU exists the Agent answers for an unknown SKU as it does today;
with enforcement off (the default) the driver works fully.

### 2. Agent module contract (remote features)

Proposal, following the Flight Recorder's contract
(`src/sbos/moduleclient.lua`, `src/sbos/envelope.lua`). Not implemented.

- `module_id = "venueflow"`, registered through `sbos.moduleclient`.
- `M.PREFIXES` in `src/sbos/envelope.lua` gains
  `venueflow = { "venueflow." }`, and the web repository's `MODULE_PREFIXES`
  the same (the server refuses a prefix it does not know for a module).

Controller to cloud, envelope v1 events:

| `event_type` | When | `payload` |
| --- | --- | --- |
| `venueflow.config.published` | each publish and rollback | `{ versionId, note, by, counts: { displays, sources, zones, scenes, rules, profiles } }` |
| `venueflow.config.snapshot` | each publish, split to fit the 4 kB payload limit | `{ versionId, part, parts, chunk }` (the backup document in order) |
| `venueflow.scene.finished` | each scene or rule run | `{ id, name, origin, status, steps: n, failed: [ "path label" ] }` |
| `venueflow.operation.failed` | an operation with a failed or unknown target | `{ label, origin, targets: [ { id, name, field, errorCode } ] }` |
| `venueflow.alert.raised` / `.cleared` | alert changes | `{ id, level, title }` |
| `venueflow.health` | hourly and on change | `{ mode, displays: { total, on, attention, offline }, zones, licence, version }` |

Cloud to controller, restricted commands (the Agent's `MODULE_COMMANDS`):

| Command | Effect |
| --- | --- |
| `venueflow.restore_draft` | puts a stored configuration into the DRAFT (never publishes) |
| `venueflow.snapshot` | asks for a fresh `config.snapshot` |

That is enough for the enhanced features the brief lists:

| Feature | Built on |
| --- | --- |
| Multi-venue overview | `venueflow.health` per installation |
| Remote configuration backup, version history | `venueflow.config.snapshot`, `.published` |
| Driver health monitoring, centralized diagnostics, alerts, activity logs | `.health`, `.operation.failed`, `.alert.*`, `.scene.finished` |
| Licence management, fleet updates | the Agent's existing entitlement and updater paths |

Deliberately absent: any cloud command that routes video, changes volume or
runs a scene. Remote control of a venue is a different risk and should be
decided on its own.

### 3. System Studio and Property Studio pages

Pages in the web repository that read the events above. None exist. Property
Studio could deep-link to a venue's local Studio address for a dealer who is
on site or on a VPN.

### 4. Remote access to Installer Studio

The Studio is served on the venue LAN only. Reaching it from elsewhere today
means the dealer's own remote access. An Agent-relayed Studio would need an
authenticated tunnel in the Agent; not designed here.

## Rules any integration must keep

1. No permanent secret in a page, in the `.c4z`, or in a backup.
2. Authenticated, scoped APIs: the Agent's installation credential, never a
   tenant named by the client.
3. The venue keeps working with the cloud unreachable.
4. A cloud command may fill the draft; publishing stays a deliberate act.
