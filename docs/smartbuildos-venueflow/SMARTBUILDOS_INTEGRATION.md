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

### 2. Remote management from smartbuildos.io

**Driver side: built and tested against the simulator. Platform side: not
built. Nothing can be managed remotely today.**

Built in this repository (build 20261114.230413):

| Piece | Where | Evidence |
| --- | --- | --- |
| "Remote Management" property (Off, Draft only, Draft and publish) and its status | `driver.xml`, `driver.lua` | `test_venueflow_driver.lua` [10b] |
| Registration with the Agent as module `venueflow`, only while the property is on | `driver.lua`, `src/sbos/moduleclient.lua` | same |
| Commands `snapshot`, `save_draft`, `refresh_status`, and with the higher level `publish`, `rollback` | `Core:remote` in `src/venueflow/core.lua` | `test_venueflow_remote.lua` |
| The configuration as one snapshot document (no PIN material) | `driver.lua` (`SBOS_MODULE_SNAPSHOT`) | same |
| Event `venueflow.config.published` | `driver.lua` | `test_venueflow_remote.lua` |
| Envelope prefix `venueflow.` | `src/sbos/envelope.lua` | same |
| Agent allowlist entry `MODULE_COMMANDS.venueflow` | `drivers/smartbuildos/driver.lua` | `make test` |

Not built, and needed before a dealer can use it:

1. **Web repository**
   - `MODULE_PREFIXES` and `MODULE_OPERATIONS` entries for `venueflow` (the
     server refuses a prefix or an operation it does not know).
   - Storage for a venue's snapshot document, keyed by installation.
   - A VenueFlow section in the dealer's Studio: read the snapshot, edit the
     configuration (the local Studio's editors are the reference), send
     `save_draft`, show the driver's validation, send `publish` with the
     revision that was reviewed, show history and `rollback`.
   - Authorization: only the dealer that owns the installation; an audit
     record of who sent what.
2. **Agent on the controller**: a build of the Agent from this branch (it
   carries the allowlist entry). The bench Agent does not have it.
3. **A bench run** of the whole path (HARDWARE_VALIDATION.md).

Open questions for that work:

- The size of a command's `args` the platform can deliver in one response.
  A configuration is tens of kilobytes; pictures are not in it (they stay on
  the controller under their key).
- Whether the remote editor should be the local Studio's code reused, or a
  new editor in the web repository's stack.

Deliberately absent: any remote command that routes video, changes volume,
runs a scene or sets a PIN. Remote control of a venue is a different risk
and should be decided on its own.

### 3. Fleet features

Multi-venue overview, health monitoring, centralized diagnostics and alerts
would need more events (`venueflow.health`, `venueflow.operation.failed`,
`venueflow.alert.*`, `venueflow.scene.finished`). None is built.

### 4. Remote access to the local Studio

The Studio pages are served on the venue LAN only. Reaching them from
elsewhere means the dealer's own remote access. An Agent-relayed tunnel is
not designed.

## Rules any integration must keep

1. No permanent secret in a page, in the `.c4z`, or in a backup.
2. Authenticated, scoped APIs: the Agent's installation credential, never a
   tenant named by the client.
3. The venue keeps working with the cloud unreachable.
4. A cloud command may fill the draft. It may publish only where the dealer
   has set Remote Management to "Draft and publish" on that controller, and
   then only the revision that was reviewed.
