# VenueFlow command protocol

Version **1** (`src/venueflow/protocol.lua`, handlers in `core.lua`).

This is VenueFlow's own message format, not a Control4 API. One request, one
reply. It travels:

1. as the JSON body of `POST http://<controller>:47861/api[?k=<tile token>]`
   (the LAN relay: the primary transport; a request body may be up to 4 MB),
   or
2. as one JSON string inside the documented WebView call
   `C4.sendCommand("VF_COMMAND", '{"ENVELOPE":"<request json>"}', true, true)`,
   with the reply delivered through `onDataToUi` (the fallback; unverified on
   hardware).

## Envelope

```jsonc
// request
{ "requestId": "r-123",            // required, up to 64 of [A-Za-z0-9-_.:]
  "command": "ROUTE_VIDEO",
  "payload": { "sourceId": "sports-1", "displayIds": [ "tv-01", "tv-02" ] },
  "ts": 1794225600,                // optional
  "session": "<token>",            // optional: from PROFILE_LOGIN or STUDIO_LOGIN
  "since": 41 }                    // optional: the state version the page holds

// reply
{ "requestId": "r-123", "command": "ROUTE_VIDEO",
  "ok": true,
  "status": "partial",             // ok | accepted | partial | planned | failed
  "errorCode": null, "message": null,
  "detail": null,                  // installer sessions only
  "results": [ ... ], "summary": { "requested": 2, "accepted": 1, "rejected": 1 },
  "operationId": "op7",
  "data": { ... },
  "stateVersion": 43,
  "state": { ... },                // the state document, when `since` was sent and is behind
  "ts": 1794225600 }
```

Unknown commands, unknown payload fields, wrong types, oversize strings and
lists over 256 entries (4000 for `PUBLISH.acknowledged`) are refused (`VF_UNKNOWN_COMMAND`, `VF_INVALID_PAYLOAD`,
`VF_TOO_LARGE`). `accepted` means "sent, confirmation awaited"; it never means
the devices changed.

## Identity

| Who | How the driver knows |
| --- | --- |
| Installer | `session` from `STUDIO_LOGIN` (Installer Passcode property). Full access to every command. |
| Staff profile | `session` from `PROFILE_LOGIN` (the profile's PIN). |
| Client (Venue Studio) | the same PIN session, when the profile's `permissions.studio` is true in the published configuration. Opens the **studio** commands, narrowed as described under "Studio commands". A tile's default profile and a station never qualify. |
| Navigator tile | the tile token `k` the driver put in the web view URL (or the Navigator bridge). Acts as the profile of the **station** whose address the request comes from, else as `defaultProfileId`; in both cases only when that profile has no PIN. Otherwise the page must sign in. |
| Anyone else | may only call the public commands. |

A page never states its own profile. Scopes: **public**, **operator** (needs
a profile identity and a published configuration), **studio** (an installer
session or a client session), **installer** (an installer session only).

## Public commands

| Command | Payload | Reply `data` |
| --- | --- | --- |
| `PING` | | `{ service, protocol, simulation }` |
| `HELLO` | | see below |
| `PROFILE_LOGIN` | `profileId`, `pin` | `{ session, profile, config, state }`; on failure `{ retryIn }` |
| `STUDIO_LOGIN` | `passcode` | `{ session }`; on failure `{ retryIn }` |
| `LOGOUT` | | |

`HELLO` reply data:

```jsonc
{ "driver": { "version": "...", "simulation": true, "protocol": 1 },
  "published": true, "venueName": "Riverside Sports Bar",
  "studioEnabled": true, "installer": false,
  "license": { "restricted": false, "label": "Licensed / Subscribed" },
  "profiles": [ { "id": "manager", "name": "Manager", "role": "manager" } ],   // profiles that have a PIN (for the sign-in pad)
  "needsSignIn": true,                 // when no identity: show the sign-in pad
  // with an identity:
  "profile": { "id", "name", "role", "interfaces": [], "defaultInterface", "can": { "routeVideo": true, ... } },
  "signedIn": false,                   // true for a PIN or installer session, false for the tile default
  "station": { "id": "host-stand", "name": "Host station" },   // when the screen is a station
  "config": OperatorConfig, "state": StateDocument }
```

`OperatorConfig` is the published configuration **as that profile may see
it** (`src/venueflow/access.lua`, `Access:view`): `venue`, `floors`, `areas`,
`sources` (`mapped` instead of Control4 ids), `displays` (`canRoute`,
`canPower`, `hasFeedback`, `sources`, `audioZoneId`, `layout`), `audioZones`,
`groups`, `lighting` (preset names only), `shades`, `rooms`, `scenes`
(`id`, `name`, `icon`, `description`, `confirm`), `labels`, `sceneButtons`. No
Control4 id, route command, program or PIN data is in it.

## Operator commands

| Command | Payload | Notes |
| --- | --- | --- |
| `GET_STATE` | | `data.state`, or `data.unchanged` when `since` is current |
| `ROUTE_VIDEO` | `sourceId`, `displayIds`, `audioZoneId`? | per-display `results`; with `audioZoneId`, `data.audio` holds the audio route's own outcome |
| `DISPLAY_POWER` | `displayIds`, `power` on or off | per-display `results` |
| `AUDIO_SOURCE` | `zoneId`, `sourceId` | |
| `AUDIO_VOLUME` | `zoneId`, `level` | `data: { level, clamped }` |
| `AUDIO_MUTE` | `zoneId`, `muted` | |
| `AUDIO_POWER` | `zoneId`, `power` = off | |
| `AUDIO_PRESET` | `zoneId`, `presetId` | |
| `LIGHTING_PRESET` | `lightingId`, `presetId` | outcome "commanded" |
| `SHADE` | `shadeId`, `action` open or close | outcome "commanded" |
| `SCENE_PREVIEW` | `sceneId` | `data.execution` (a dry run: nothing is sent) |
| `SCENE_ACTIVATE` | `sceneId`, `confirm`?, `areaId`? | `data.execution`. A scene marked `confirm` answers `VF_CONFIRM_REQUIRED` with `data.preview` until `confirm: true`. An `areaId` outside the profile's access is refused with `VF_FORBIDDEN` (it is not ignored) |
| `ALL_OFF_PREVIEW` | | `results`, `data: { displays, zones, activeScene }` |
| `ALL_OFF` | `confirm` | needs `confirm: true` |
| `VENUE_STATUS` | `status` open or closed | `data: { venueStatus, rulesNotRun? }`. The status is set under any licence; `rulesNotRun` counts the rules waiting for the change that did not run (a restricted licence, or a rule that failed to start). The page does not show it yet |
| `QUERY_STATUS` | `displayIds`? | re-reads Control4; clears a stale failure |
| `ALERT_DISMISS` | `alertId` | needs `viewAlerts`. Only an alert this profile is shown, marked `dismissable` (a stored alert); any other id, a detected alert included, answers `VF_NOT_FOUND`. `ALERT_COUNT` is updated at once |
| `IMAGE_GET` | `key` | `data: { key, dataUrl }`. An installer session may read any stored picture, also before anything is published |
| `OPERATION_GET` | `operationId` | `data.operation`. A profile gets only the targets it may see, with `summary` counted over those, and no `origin`; when it sees only part of the operation, `label` is rebuilt from what it sees ("Sports 2 to 3 displays"; otherwise a neutral label such as "Video change"). An operation it can see nothing of is `VF_NOT_FOUND`, as if it did not exist. An installer session gets the whole operation: every target, with detail, and `origin` |

### State document

```jsonc
{ "version": 43, "time": 1794225600,
  "venueStatus": "open", "simulation": true,
  "configVersion": "v3",              // the published version: when it changes, a page sends HELLO again
  "license": { "restricted": false, "label": "..." },
  "displays": { "tv-01": { "power": Cell, "source": Cell, "online": true } },   // online: true | false | absent (no link state)
  "zones":    { "zone-bar": { "power": Cell, "source": Cell, "volume": Cell, "mute": Cell } },
  "lighting": { "house-lights": { "preset": Cell } },
  "shades":   { "shades-a": { "position": Cell } },
  "activeScene": { "id": "game-day", "name": "Game Day", "at": 1794225000 },
  "running": [ { "id": "x4", "refId": "game-day", "name": "Game Day", "kind": "scene", "status": "settling", "startedAt": 1794225000 } ],
  "operations": [ Operation ],          // the most recent 8 that touch something this profile can see; filtered as for OPERATION_GET, never with `origin`
  "alerts": [ Alert ],                  // only for profiles with viewAlerts; see "Which alerts a profile is shown" 
  "counts": { "displays": { "total", "on", "off", "unknown", "attention", "offline" }, "zones": { "total", "on", "muted" } } }
```

`Cell` is `{ value, status, at, errorCode?, requested? }` (see DATA_MODEL.md).

**Which alerts a profile is shown.** Detected alerts (a display or zone
change not confirmed, a display offline) are listed for the displays and
zones the profile may see; the licence alert for every profile. A stored
alert is listed, and may be dismissed, only when the profile may see every
display, audio zone and scene it concerns: an interrupted scene or rule
names the devices both runs change and the scenes involved, a missed
schedule the devices its rule changes. A notification concerns nothing in
particular and is listed for every profile with `viewAlerts`. An alert about
a display, zone or scene since removed from the configuration is listed only
for a profile whose scope is all displays (zones, scenes). Not filtered: a
rule's own name in an alert's title. Lighting and shades are not part of
what an alert records. The installer sees every alert, and the Alerts
property, `ALERT_COUNT` and *VenueFlow has alerts* count every alert of the
venue.

```jsonc
// Operation (`origin` only in an installer's OPERATION_GET)
{ "id": "op7", "kind": "route_video", "label": "Sports 1 to 6 displays", "origin": "profile:manager",
  "startedAt": 1794225600, "finishedAt": 1794225603, "done": true,
  "summary": { "total": 6, "confirmed": 4, "commanded": 0, "failed": 2, "unknown": 0, "superseded": 0, "pending": 0, "good": 4, "bad": 2 },
  "targets": [ { "kind": "display", "id": "tv-01", "name": "TV 01", "field": "source", "status": "confirmed" },
               { "kind": "display", "id": "tv-09", "name": "TV 09", "field": "source", "status": "failed",
                 "errorCode": "VF_NOT_CONFIRMED", "message": "The device did not confirm the change." } ] }

// Alert
{ "id": "cell:tv-09:source", "level": "warning", "title": "TV 09: source change not confirmed",
  "detail": "The device did not confirm the change.", "entity": { "kind": "display", "id": "tv-09" },
  "action": { "type": "query", "displayIds": [ "tv-09" ] },      // or { "type": "unmute", "zoneId": "zone-patio" }
  "dismissable": false }

// Execution (scene or rule run; also the dry-run plan)
{ "id": "x4", "kind": "scene", "refId": "game-day", "name": "Game Day", "dryRun": false, "origin": "profile:manager",
  "startedAt": 1794225000, "finishedAt": 1794225004,
  "status": "ok",                      // running | settling | ok | partial | failed | skipped | cancelled
  "conditionMet": true,
  "steps": [ { "path": "1", "type": "route_video", "label": "Route Sports 1 to 6 displays",
               "status": "ok",          // ok | sent | planned | partial | failed | skipped | incomplete | waiting | cancelled
               "errorCode": null, "message": null, "operationId": "op7", "results": [ ... ] } ] }
```

## Source control commands

Scope **operator**. The profile needs the `sourceControl` permission and
access to the source; the source needs a Control4 device and the key's group
in its `controls`.

| Command | Payload | Reply `data` |
| --- | --- | --- |
| `SOURCE_KEY` | `sourceId`, `key` | `{ sent: 1, feedback: false }` |
| `SOURCE_TUNE` | `sourceId`, and `favoriteId` or `channel` ("206", "5-1") | `{ sent: n, feedback: false }` |

`key` is one of a closed list (`src/venueflow/sourcecontrol.lua`), never a
Control4 command name: `CH_UP`, `CH_DOWN`, `RECALL` (group channel);
`NUM_0` to `NUM_9`, `DASH`, `ENTER` (keypad); `UP`, `DOWN`, `LEFT`, `RIGHT`,
`SELECT`, `GUIDE`, `INFO`, `MENU`, `CANCEL`, `PAGE_UP`, `PAGE_DOWN`
(navigation); `PLAY`, `PAUSE`, `STOP`, `SCAN_FWD`, `SCAN_REV`, `SKIP_FWD`,
`SKIP_REV` (transport). Errors: `VF_INVALID_PAYLOAD` (unknown key, bad
channel), `VF_UNSUPPORTED` (the source lacks that group, or too many keys
are waiting), `VF_DEVICE_UNMAPPED`, `VF_FORBIDDEN`, `VF_NOT_FOUND`.

`ok` means the keys were queued to be sent. There is no confirmation: a box
reports nothing back. A source in the operator configuration carries
`controls: { groups, favorites }` when the profile may use them.

## Studio commands

`STUDIO_BOOTSTRAP`, `DRAFT_GET`, `DRAFT_SAVE`, `DRAFT_VALIDATE`,
`DRAFT_DISCARD`, `PROFILE_PIN_SET`, `PUBLISH`, `VERSIONS`, `ROLLBACK`,
`PROGRAM_VALIDATE`, `PROGRAM_DRY_RUN` and `EXECUTIONS` have scope **studio**:
an installer session or a client session. Every other command in the table
below is installer only, and answers `VF_FORBIDDEN` to a client.

For a client session the driver narrows them (`src/venueflow/clientscope.lua`):

| Command | For a client |
| --- | --- |
| `STUDIO_BOOTSTRAP` | `role: "client"`, `who`, and `client: { mayChange, sourceFields, liveWarnings, installerPending, canPublish }`. `installerPending` is absent, or a phrase saying why the draft is the installer's ("changes saved by the installer", "changes saved remotely by the dealer", or the installer-owned part that differs). No controller `info`, the short licence summary |
| `DRAFT_SAVE` | Allowed when the configuration differs from what is published only in: `scenes`; `rules` whose trigger is a schedule; `profiles` (except who holds `permissions.studio`, and except the default profile and every station's profile, which are installer-owned as whole records); a source's `name`, `channel` and `favorites`; an audio zone's `presets`. Otherwise `VF_FORBIDDEN` with `data.installerOnly` naming the part |
| `PROFILE_PIN_SET` | Refused for the default profile and any station's profile (setting and clearing), with `data.installerOnly` "the profile a screen or station opens with" |
| `PUBLISH`, `DRAFT_DISCARD` | Refused with `VF_FORBIDDEN`, "the installer has unfinished changes in the draft", and `data.installerPending: true` while the draft holds a save by the installer or by Remote Management since the last publish or discard, or differs from what is published in an installer-owned part. On publish, warnings that are live already are acknowledged for the client |
| `ROLLBACK` | Allowed only to a version that differs from the live one in client-owned parts |

`HELLO` adds `studio` (this session may open the Studio), `studioReachable`
and, on each listed profile, `studio`. `PROFILE_LOGIN` adds `studio`.

## Remote commands

Not page commands. They arrive through the SmartBuildOS Agent's module
contract (`SBOS_MODULE_COMMAND`, authenticated by the Agent's token) and run
through `Core:remote(command, args, level)`. The "Remote Management" property
sets the level; Off refuses everything.

| Command | Level | Args | Result |
| --- | --- | --- | --- |
| `snapshot` | draft | none | one document (`SBOS_MODULE_SNAPSHOT`), see below. No PIN material |
| `save_draft` | draft | `config` (object) or `configParts` (JSON text in parts), and `baseRevision` (required when a draft exists) | `revision`; `VF_STALE_DRAFT` when the draft moved |
| `refresh_status` | draft | none | a one-line summary in the result's detail (at most 200 characters: configuration, mode, venue status, active scene, alert count, draft, and the last error when there is one; no names of people, PINs, addresses or tokens). The driver also sends a module status frame at once with the same line, counters `alerts`, `displays`, `zones`, `scenes`, `venue_open`, `simulation`, and `config_version` |
| `publish` | publish | `baseRevision` (must equal the draft's), `acknowledged`, `note` | `versionId`, recorded as `remote` |
| `rollback` | publish | `versionId` | `versionId` |

The snapshot document is
`{ kind: "venueflow.config", format: 2, encoding: "base64-groups", bytes, parts: [text, ...] }`.
Join `parts`, drop the commas, base64-decode (no padding is sent) and parse
the result as JSON to get
`{ kind, schema, driver, venueStatus, draft: { config, revision, savedAt, basedOn, matchesPublished, issues, summary }, published: { versionId, publishedAt, note, by, sameAsDraft?, config? }, history }`.
`published.config` is left out when `sameAsDraft` is true.

It travels as base64 in comma-separated groups of 64 characters because two
redactors stand between the driver and the platform's storage: the Agent's
(keys named like a credential, such as an issue's `code`; anything nested
more than six levels deep; long token-like strings) and the platform's
(credential-shaped text inside any string). A configuration sent as an
object, or as JSON text, would come back damaged, and would then be written
back into the venue. Groups of base64 match none of their rules. Each part is
at most 3900 characters. A configuration over 170 kB of JSON is refused
(`VF_TOO_LARGE`): encoded, it must fit the Agent's 256 kB.

A finished operation is reported to the Agent as `Completed` or `Failed`
(the Agent's closed list of states).

Event to the platform: `venueflow.config.published`
`{ versionId, how, restoredFrom? }`: `versionId` is the new live version,
`how` is "configuration published" or "configuration rolled back", and a
rollback adds `restoredFrom`, the version whose content it restored.

The module's `config_version`, in every status frame, is the published
version id the controller runs, or `none` when nothing runs (nothing
published, or a sample venue held back in Live mode). A status frame is sent
after every publish and rollback.

## Installer commands

All need an Installer Studio session, except the studio commands above.

| Command | Payload | Reply `data` |
| --- | --- | --- |
| `STUDIO_BOOTSTRAP` | | `{ driver, info, controller: { timeZone, localTime }, draft, published, history, license, schema, venueStatus }` |
| `DRAFT_GET` | | `{ draft }` |
| `DRAFT_SAVE` | `config`, `baseRevision`? | `{ revision, issues, summary }`; `VF_STALE_DRAFT` when `baseRevision` is behind |
| `DRAFT_VALIDATE` | | `{ issues, summary, revision }` |
| `DRAFT_DISCARD` | `confirm`, `baseRevision`? | `{ draft }` (reset to the published version, or none). With `baseRevision`, a draft that has moved on answers `VF_STALE_DRAFT` |
| `TEMPLATE_APPLY` | `venueType`, `name`?, `sample`?, `confirm`? | `{ draft }`; needs `confirm` when a draft exists; `sample` only in Simulation mode |
| `PROFILE_PIN_SET` | `profileId`, `pin`? (empty removes), `baseRevision`? | `{ revision, hasPin }` |
| `IMAGE_PUT` | `dataUrl` (PNG, JPEG or WebP, up to 600 kB encoded) | `{ key }` |
| `PUBLISH` | `acknowledged`: issue ids, `note`?, `baseRevision`? | `{ versionId, published, history }`; `VF_VALIDATION_FAILED` with `data.blocking`. With `baseRevision`, a draft that has moved on answers `VF_STALE_DRAFT` |
| `VERSIONS` | | `{ published, history }` |
| `ROLLBACK` | `versionId`, `confirm` | `{ versionId, published, history }` |
| `BACKUP_EXPORT` | | `{ backup }`; the backup carries `revision`, the draft revision counter, so a restore never gives out a revision already used |
| `BACKUP_RESTORE` | `backup`, `which`? published or draft, `confirm`? | `{ draft }`; restores into the draft only |
| `DISCOVER` | | `{ devices: [ { id, name, room, roomId, driverFile, category, basis, capabilities, online? } ], counts, rooms }` |
| `TEST_DEVICE` | `test` (power_on, power_off, source, route, status), `displayId`?, `zoneId`?, `sourceId`?, `confirm`? | `status` is immediate: `{ roomId, room, readable, online }`. Others need `confirm: true` and answer `{ testId, status }` |
| `TEST_RESULT` | `testId` | `{ id, test, name, status, matched?, room?, before?, changes? }`; status waiting, confirmed, not_confirmed, unreadable, sent_no_feedback. `before` is the room as read just before the test; `changes: false` means the room was already in the requested state, so "confirmed" does not prove the command did anything |
| `PROGRAM_VALIDATE` | `program`, `condition`?, `trigger`? | `{ issues, summary }` (against the draft) |
| `PROGRAM_DRY_RUN` | `program`, `condition`?, `name`? | `{ execution }` (against the published configuration; nothing is sent) |
| `PROGRAM_EXECUTE` | `program`, `condition`?, `name`?, `confirm`, `refKind`? (scene or rule), `refId`? | `{ execution }` (live). With `refKind` and `refId` the run is recorded as that scene's or rule's last run; it does not make the scene active or fire rules that wait for it |
| `EXECUTION_CANCEL` | `executionId` | Stops the remaining steps and the commands the run had queued and not yet sent; their targets end `superseded` with `VF_CANCELLED`. A command already sent is not recalled |
| `EXECUTIONS` | | `{ executions, lastRun, lastSuccess, upcoming, operations, variables, controller }`; `lastRun` and `lastSuccess` are keyed `scene:<id>` and `rule:<id>` |
| `DIAG_GET` | `limit`?, `level`?, `category`?, `sinceSeq`? | `{ entries: [ { seq, at, level, category, code, message, data } ], counts, size, max, sessions, queue, simFaults? }` (`simFaults`: the simulator's current faults, Simulation mode only) |
| `DIAG_CLEAR` | | |
| `LICENSE_GET`, `LICENSE_REFRESH` | | `{ license }` |
| `SESSIONS_REVOKE` | | `{ revoked }` (ends every staff session) |
| `SIM_FAULT` | `targetId` (Control4 room or device id), `fault`? (offline, silent, wrong, slow; empty clears) | Simulation mode only |
| `SIM_EXTERNAL` | `roomId`, `changes` (power, volume, muted, videoDevice, audioDevice) | Simulation mode only: a change made behind VenueFlow's back |

`draft` is `{ config, revision, savedAt, basedOn, matchesPublished, issues,
summary }` (`matchesPublished`: the draft is exactly what is published).
Revisions never repeat for the life of the stored venue: a discard, a
publish or a restore does not restart them. An
issue is `{ id, severity, code, path, message, entity?, related? }`; `related`
names a second entity the issue is also about. In it
every profile carries `hasPin` instead of its salt and hash; what the Studio
sends back gets them re-attached by the driver.

`schema` (in `STUDIO_BOOTSTRAP`) lists the vocabulary the Studio builds its
editors from: `venueTypes`, `interfaces`, `sourceKinds`, `displayKinds`,
`routeStrategies`, `powerStrategies`, `roles`, `variableTypes`,
`permissionFlags`, `limits`, `requestBytes`, `imageBytes`, `roomButtonsMax`,
`stepTypes`, `conditionOps`, `triggerTypes`, `comparators`,
`maxWaitSeconds`, `sceneTemplates`, `profileTemplates`, `errorCodes`,
`diagCategories`.

## Error codes

`src/venueflow/errors.lua`. Each has an operator sentence (in `message`) and an
HTTP status used only for transport-level failures.

| Code | Operator sentence |
| --- | --- |
| `VF_BAD_REQUEST` | That request could not be read. |
| `VF_UNKNOWN_COMMAND` | This screen asked for something the system does not know. |
| `VF_INVALID_PAYLOAD` | That request was incomplete. |
| `VF_TOO_LARGE` | That is too large to save. |
| `VF_UNAUTHENTICATED` | Please sign in. |
| `VF_FORBIDDEN` | Your profile is not allowed to do that. |
| `VF_LOCKED` | Too many wrong attempts. Wait a minute and try again. |
| `VF_BAD_PIN` | That PIN is not right. |
| `VF_BAD_PASSCODE` | That passcode is not right. (A wrong Installer Passcode at `STUDIO_LOGIN`.) |
| `VF_STUDIO_DISABLED` | Installer Studio is off until an Installer Passcode is set. |
| `VF_CONFIRM_REQUIRED` | Please confirm this action. |
| `VF_LICENSE_RESTRICTED` | This feature needs a SmartBuildOS licence. |
| `VF_NO_PUBLISHED_CONFIG` | This venue has not been set up yet. |
| `VF_VALIDATION_FAILED` | The configuration has problems to fix first. |
| `VF_STALE_DRAFT` | Someone else changed the draft. Reload and try again. |
| `VF_NOT_FOUND` | That item no longer exists. |
| `VF_STORAGE_FAILED` | The change could not be saved. |
| `VF_DEVICE_UNMAPPED` | This device is not connected to Control4 yet. |
| `VF_UNSUPPORTED` | This device cannot do that. |
| `VF_SOURCE_UNAVAILABLE` | That source is not available. |
| `VF_SOURCE_NOT_ALLOWED` | That source cannot be shown here. |
| `VF_ROUTE_UNSUPPORTED` | That source cannot reach this display. |
| `VF_NO_SOURCE_FOR_POWER_ON` | Choose a source to turn this display on. |
| `VF_DEVICE_OFFLINE` | This device is not responding. |
| `VF_DISPATCH_FAILED` | The command could not be sent. |
| `VF_NOT_CONFIRMED` | The device did not confirm the change. |
| `VF_SUPERSEDED` | A newer request replaced this one. |
| `VF_CANCELLED` | This was stopped before it finished. |
| `VF_RECURSION_LIMIT` | This scene runs itself in a loop. |
| `VF_CONDITION_FALSE` | The scene's condition is not met right now. |
| `VF_SIMULATION_ONLY` | That is only available in Simulation mode. |
| `VF_INTERNAL` | Something went wrong inside the driver. |

`VF_NETWORK` is produced by the page itself when no reply arrives.

## Relay routes

| Route | Purpose | Identity |
| --- | --- | --- |
| `GET /ping` | reachability probe | none |
| `GET /app` | the operator page | none (the page holds no secret) |
| `GET /studio` | the Installer Studio page | none (the page holds no secret) |
| `POST /api[?k=<tile>]` | one protocol request | inside the request |
| `POST /image` | a floor-plan picture: the body is its data URL and nothing else; the reply is small JSON | an installer session, in the `X-VF-Session` header |
| `OPTIONS *` | CORS preflight | none |

There is no other route: no configuration or control endpoint exists outside
the protocol.
