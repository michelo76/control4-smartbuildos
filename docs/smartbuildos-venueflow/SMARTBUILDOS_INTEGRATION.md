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
| Same repository, build and update conventions | `drivers/smartbuildos-venueflow`, the monorepo's build, guards and manuals; the Agent's `DRIVER_FILENAMES` (its updater) and `SKU_FILENAMES` (`SBOS_VENUEFLOW`) name `smartbuildos-venueflow.c4z` | `make test`, `test_sbos_updater.lua` |

Local operation never needs SmartBuildOS: the operator page, selection,
routing, audio, scenes, the configuration and state updates are all on the
controller (`test_venueflow_license.lua` "cloud outage").

## Not finished: needs the Agent, the web repository, or both

These are outside this repository's driver, or change contracts that other
components own.

### 1. Entitlement issuing (blocks selling, not running)

- Web repository: a catalogue-row migration for `SBOS_VENUEFLOW` exists
  (merged 15 November 2026) and **has not been applied by the owner**. Until
  it is, no licence can be issued for the SKU, and there is no store listing
  or product page. Its price and tier are the owner's decision.
- Agent (`drivers/smartbuildos/driver.lua`): `smartbuildos-venueflow.c4z` is
  in `DRIVER_FILENAMES` and in `SKU_FILENAMES` under `SBOS_VENUEFLOW` (source
  of 18 November 2026). The store's publish workflow
  (`.github/workflows/publish-to-store.yml`) does not name VenueFlow yet, so
  the Agent's updater has nothing to fetch until a package is published to
  the store.

Until the SKU can be issued the Agent answers for VenueFlow as for any SKU
without an entitlement; with enforcement off (the default) the driver works
fully.

### 2. Remote management from smartbuildos.io

**Driver side: built and tested against the simulator and the test shim.
Platform side: merged and deployed on 15 November 2026. The two have never
been run together with a controller: nothing has been managed remotely yet.**

Built in this repository (on `main`; the driver's part was first built as
`20261114.233926`, the status and version reporting below is source of 18
November 2026 and has not been built for a controller):

| Piece | Where | Evidence |
| --- | --- | --- |
| "Remote Management" property (Off, Draft only, Draft and publish) and its status | `driver.xml`, `driver.lua` | `test_venueflow_driver.lua` [10b] |
| Registration with the Agent as module `venueflow`, only while the property is on | `driver.lua`, `src/sbos/moduleclient.lua` | same |
| Commands `snapshot`, `save_draft`, `refresh_status`, and with the higher level `publish`, `rollback` | `Core:remote` in `src/venueflow/core.lua` | `test_venueflow_remote.lua`, `test_venueflow_driver.lua` |
| The configuration as one snapshot document (no PIN material) | `driver.lua` (`SBOS_MODULE_SNAPSHOT`) | same |
| `refresh_status` answers with a one-line summary (at most 200 characters) and sends a module status frame at once: that line, counters (`alerts`, `displays`, `zones`, `scenes`, `venue_open`, `simulation`) and `config_version` | `driver.lua` | `test_venueflow_driver.lua` |
| `config_version`: the published version id the controller runs, or `none`; also sent after every publish and rollback | `driver.lua` | same |
| Event `venueflow.config.published` with `versionId` (the new live version), `how`, and on a rollback `restoredFrom` | `driver.lua` | `test_venueflow_remote.lua`, `test_venueflow_driver.lua` |
| Envelope prefix `venueflow.` | `src/sbos/envelope.lua` | same |
| Agent allowlist entry `MODULE_COMMANDS.venueflow` | `drivers/smartbuildos/driver.lua` | `make test` |

Merged and deployed in the web repository on 15 November 2026 (see its
`docs/venueflow/README.md`): the module contract for module `venueflow`
(operations `snapshot`, `save_draft`, `publish`, `rollback`,
`refresh_status`, closed operation arguments, up to 200 kB for
`save_draft`), a status route that decodes the newest snapshot, a VenueFlow
section in the dealer's System Studio under Drivers & Licenses (Overview,
Sources, Audio, Schedules, Whole configuration, Publish, Driver), and one
catalogue-row migration for `SBOS_VENUEFLOW` (not yet applied; section 1).
No other table. Its tests read this repository to check that the Agent, the
driver and the platform list the same five operations, and run a snapshot
produced by this driver's code through both of the platform's redactors.
None of it has been run end to end with a controller.

On the controller side, the Agent on `main` allows the `venueflow` module,
and the bench controller runs an Agent built from `main` on 18 November
2026. That it accepts a VenueFlow registration has not been watched: the
VenueFlow build on the bench (`20261114.191046`) has no Remote Management.

Still needed before a dealer can use it:

1. A VenueFlow build from current source on the bench controller, and
   Remote Management registration seen with the bench Agent.
2. **A bench run of the whole path** from System Studio
   (HARDWARE_VALIDATION.md, "Not yet run"), including `refresh_status`
   showing the summary and the live version. Unmeasured: whether a
   controller handles a large `save_draft` comfortably (the sample venue is
   about 40 kB; the driver refuses more than 170 kB of JSON), and how long a
   round trip takes on the Agent's check-in cadence.
3. The owner applies the catalogue-row migration (section 1) and decides
   pricing and tier; nothing invents them.
4. An owner decision on whether "Draft and publish" may replace device
   mapping and device commands (today a remote draft can replace the whole
   configuration; SECURITY_REVIEW.md).

Not built on the platform: full editors for scenes' steps, the floor layout,
device mapping and staff profiles (the platform has focused editors for
sources, audio zones and schedules, and the whole configuration as JSON).

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
