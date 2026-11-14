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
| Navigator tile | the tile token `k` the driver put in the web view URL (or the Navigator bridge). Acts as the profile of the **station** whose address the request comes from, else as `defaultProfileId`; in both cases only when that profile has no PIN. Otherwise the page must sign in. |
| Anyone else | may only call the public commands. |

A page never states its own profile. Scopes: **public**, **operator** (needs
a profile identity and a published configuration), **installer**.

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
| `SCENE_ACTIVATE` | `sceneId`, `confirm`?, `areaId`? | `data.execution`. A scene marked `confirm` answers `VF_CONFIRM_REQUIRED` with `data.preview` until `confirm: true` |
| `ALL_OFF_PREVIEW` | | `results`, `data: { displays, zones, activeScene }` |
| `ALL_OFF` | `confirm` | needs `confirm: true` |
| `VENUE_STATUS` | `status` open or closed | |
| `QUERY_STATUS` | `displayIds`? | re-reads Control4; clears a stale failure |
| `ALERT_DISMISS` | `alertId` | only alerts marked `dismissable` |
| `IMAGE_GET` | `key` | `data: { key, dataUrl }`. An installer session may read any stored picture, also before anything is published |
| `OPERATION_GET` | `operationId` | `data.operation` |

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
  "operations": [ Operation ],          // the most recent 8 that touch something this profile can see
  "alerts": [ Alert ],                  // only for profiles with viewAlerts
  "counts": { "displays": { "total", "on", "off", "unknown", "attention", "offline" }, "zones": { "total", "on", "muted" } } }
```

`Cell` is `{ value, status, at, errorCode?, requested? }` (see DATA_MODEL.md).

```jsonc
// Operation
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

## Installer commands

All need an Installer Studio session.

| Command | Payload | Reply `data` |
| --- | --- | --- |
| `STUDIO_BOOTSTRAP` | | `{ driver, info, controller: { timeZone, localTime }, draft, published, history, license, schema, venueStatus }` |
| `DRAFT_GET` | | `{ draft }` |
| `DRAFT_SAVE` | `config`, `baseRevision`? | `{ revision, issues, summary }`; `VF_STALE_DRAFT` when `baseRevision` is behind |
| `DRAFT_VALIDATE` | | `{ issues, summary, revision }` |
| `DRAFT_DISCARD` | `confirm` | `{ draft }` (reset to the published version, or none) |
| `TEMPLATE_APPLY` | `venueType`, `name`?, `sample`?, `confirm`? | `{ draft }`; needs `confirm` when a draft exists; `sample` only in Simulation mode |
| `PROFILE_PIN_SET` | `profileId`, `pin`? (empty removes), `baseRevision`? | `{ revision, hasPin }` |
| `IMAGE_PUT` | `dataUrl` (PNG, JPEG or WebP, up to 600 kB encoded) | `{ key }` |
| `PUBLISH` | `acknowledged`: issue ids, `note`? | `{ versionId, published, history }`; `VF_VALIDATION_FAILED` with `data.blocking` |
| `VERSIONS` | | `{ published, history }` |
| `ROLLBACK` | `versionId`, `confirm` | `{ versionId, published, history }` |
| `BACKUP_EXPORT` | | `{ backup }` |
| `BACKUP_RESTORE` | `backup`, `which`? published or draft, `confirm`? | `{ draft }`; restores into the draft only |
| `DISCOVER` | | `{ devices: [ { id, name, room, roomId, driverFile, category, basis, capabilities, online? } ], counts, rooms }` |
| `TEST_DEVICE` | `test` (power_on, power_off, source, route, status), `displayId`?, `zoneId`?, `sourceId`?, `confirm`? | `status` is immediate: `{ roomId, room, readable, online }`. Others need `confirm: true` and answer `{ testId, status }` |
| `TEST_RESULT` | `testId` | `{ id, test, name, status, matched?, room?, before?, changes? }`; status waiting, confirmed, not_confirmed, unreadable, sent_no_feedback. `before` is the room as read just before the test; `changes: false` means the room was already in the requested state, so "confirmed" does not prove the command did anything |
| `PROGRAM_VALIDATE` | `program`, `condition`?, `trigger`? | `{ issues, summary }` (against the draft) |
| `PROGRAM_DRY_RUN` | `program`, `condition`?, `name`? | `{ execution }` (against the published configuration; nothing is sent) |
| `PROGRAM_EXECUTE` | `program`, `condition`?, `name`?, `confirm`, `refKind`? (scene or rule), `refId`? | `{ execution }` (live). With `refKind` and `refId` the run is recorded as that scene's or rule's last run; it does not make the scene active or fire rules that wait for it |
| `EXECUTION_CANCEL` | `executionId` | |
| `EXECUTIONS` | | `{ executions, lastRun, lastSuccess, upcoming, operations, variables, controller }`; `lastRun` and `lastSuccess` are keyed `scene:<id>` and `rule:<id>` |
| `DIAG_GET` | `limit`?, `level`?, `category`?, `sinceSeq`? | `{ entries: [ { seq, at, level, category, code, message, data } ], counts, size, max, sessions, queue, simFaults? }` (`simFaults`: the simulator's current faults, Simulation mode only) |
| `DIAG_CLEAR` | | |
| `LICENSE_GET`, `LICENSE_REFRESH` | | `{ license }` |
| `SESSIONS_REVOKE` | | `{ revoked }` (ends every staff session) |
| `SIM_FAULT` | `targetId` (Control4 room or device id), `fault`? (offline, silent, wrong, slow; empty clears) | Simulation mode only |
| `SIM_EXTERNAL` | `roomId`, `changes` (power, volume, muted, videoDevice, audioDevice) | Simulation mode only: a change made behind VenueFlow's back |

`draft` is `{ config, revision, savedAt, basedOn, matchesPublished, issues,
summary }` (`matchesPublished`: the draft is exactly what is published). An
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
| `OPTIONS *` | CORS preflight | none |

There is no other route: no configuration or control endpoint exists outside
the protocol.
