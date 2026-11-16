# VenueFlow data model

Schema version **1** (`src/venueflow/schema.lua`). One configuration is one
JSON document. Every entity has a stable `id` (lower-case slug, up to 48
characters, `^[a-z0-9][a-z0-9_-]*$`). A rename changes `name`, never `id`.

Validation (`Schema.validate`) returns issues, each
`{ id, severity, code, path, message, entity? }`:

- `error`: must be fixed before publishing.
- `warning`: must be fixed **or acknowledged** before publishing.

The issue `id` is `CODE:path` and is what the Studio sends back in
`PUBLISH.acknowledged`.

Collections arrive in a browser as arrays. An **empty** collection may arrive
as `[]` whether it is a list or a map (the controller's JSON encoder cannot
tell an empty Lua table's kind). Pages read every collection through
`VF.asList` / `VF.asMap`.

## Configuration

```jsonc
{
  "schema": 1,
  "venue": {
    "name": "Riverside Sports Bar",
    "type": "sports_bar",            // sports_bar | restaurant | corporate_office | conference_center | hotel | fitness_center | retail | custom
    "timezone": "",                   // a note only; schedules run on the controller's own time zone
    "defaultInterface": "command",    // floorplan | command | room | manager
    "subsystems": { "video": true, "audio": true, "lighting": false, "shades": false }
  },
  "floors":     [ Floor ],
  "areas":      [ Area ],
  "sources":    [ Source ],
  "displays":   [ Display ],
  "audioZones": [ AudioZone ],
  "groups":     [ DisplayGroup ],
  "lighting":   [ LightingControl ],
  "shades":     [ Shade ],
  "rooms":      [ RoomPanel ],
  "scenes":     [ Scene ],
  "rules":      [ Rule ],
  "variables":  [ Variable ],
  "profiles":   [ StaffProfile ],
  "defaultProfileId": "bartender",   // optional: the profile a Navigator tile opens with, without a PIN
  "stations":   [ Station ],         // optional: fixed screens that open as their own profile
  "layout": { "labels": [ Label ], "sceneButtons": [ SceneButton ] }
}
```

Limits (`Schema.LIMITS`): 12 floors, 64 areas, 64 sources, 200 displays, 48
audio zones, 64 groups, 48 lighting controls, 48 shades, 48 room panels, 64
scenes, 96 rules, 48 variables, 24 profiles, 48 stations, 200 labels, 64 scene
buttons,
names up to 80 characters.

### Floor

```jsonc
{ "id": "main-floor", "name": "Main Floor",
  "width": 1200, "height": 800,      // canvas units, 100..20000
  "grid": 20,                         // snap grid in canvas units
  "image": { "key": "img_ab12...", "width": 1600, "height": 1000 } }  // optional floor plan; stored by IMAGE_PUT
```

### Area

```jsonc
{ "id": "bar", "name": "Bar", "floorId": "main-floor", "color": "#2dd4bf",
  "layout": { "x": 40, "y": 40, "w": 420, "h": 440 } }   // optional rectangle on the floor
```

### Source

```jsonc
{ "id": "sports-1", "name": "Sports 1",
  "kind": "satellite",               // cable | satellite | streaming | signage | laptop | conference | music | camera | other
  "c4DeviceId": 3001,                // the Control4 device id of the source (the id a room selects)
  "video": true, "audio": true, "enabled": true }
```

### Display

```jsonc
{ "id": "tv-01", "name": "TV 01",
  "kind": "tv",                      // tv | projector | videowall
  "floorId": "main-floor", "areaId": "bar",
  "c4RoomId": 1101,                  // the Control4 ROOM that is this display's AV destination
  "c4DeviceId": 2101,                // the display device itself (link state, device power)
  "route": { "strategy": "room" },   // room | command | none  (see below)
  "sources": "all",                  // "all" or the list of source ids this display can show
  "defaultSourceId": "sports-1",     // optional: selected when powering on with no last source
  "power": "room",                   // room | device | none
  "feedback": "room",                // room | none
  "audioZoneId": "zone-bar",         // optional association (what "listen here" offers), never an automatic route
  "layout": { "x": 60, "y": 50, "w": 76, "h": 44, "rot": 0, "locked": false, "hidden": false } }
```

Route strategies:

| Strategy | What is sent | Feedback |
| --- | --- | --- |
| `room` | `SELECT_VIDEO_DEVICE {deviceid}` to `c4RoomId`. Control4's own AV bindings decide the path (HDMI matrix, AV-over-IP, direct). | Room variable `CURRENT_VIDEO_DEVICE` |
| `command` | One installer-defined command: `route.command = { deviceId, name, params }`. A param value `"${source}"` becomes the source's `c4DeviceId`, `"${sourceName}"` its name. | None assumed (outcome "commanded") |
| `none` | Nothing. The display cannot be routed. | |

Power strategies: `room` (off = `ROOM_OFF` to the room; on = select the
source the display last showed, else its default source), `device` (`ON` / `OFF` to `c4DeviceId`, no feedback
assumed), `none`.

Membership of a display group is stored on the group (`displayIds`), not on
the display.

`layout` is presentation only. Moving, hiding or resizing an icon never
changes `c4RoomId`, `c4DeviceId` or `route`.

Drawing conventions shared by the Layout Designer and the operator floor
plan: positions and sizes are in the floor's canvas units with the origin at
the top left; `x`, `y` is the top-left corner of the unrotated box; `rot` is
degrees clockwise about the centre of that box; a label's `x`, `y` is the
top-left of its text; a floor plan picture is drawn fitted inside the floor,
centred, under everything else. `locked` (not movable in the designer) may
be set on any placed object; `hidden` (not drawn for operators, still
controllable from the Command Center) on displays. A floor has no real-world
scale: the rulers show canvas units.

### AudioZone

```jsonc
{ "id": "zone-bar", "name": "Bar", "areaId": "bar", "floorId": "main-floor",
  "c4RoomId": 1201,                  // the Control4 room whose audio this zone is
  "sources": "all",                  // "all" or a list of source ids
  "minVolume": 0, "maxVolume": 85,   // every level is clamped to this range
  "defaultVolume": 60,
  "presets": [ { "id": "game", "name": "Game", "level": 70 } ],
  "can": { "volume": true, "mute": true, "source": true, "power": true },
  "feedback": "room",                // room | none
  "layout": { "x": 180, "y": 250, "w": 140, "h": 60 } }
```

Two audio zones may not share a `c4RoomId` (error `ZONE_ROOM_SHARED`). A
display and a zone sharing a `c4RoomId` is allowed and flagged
`AUDIO_COUPLED`: in that room Control4 moves the sound with the picture.

### DisplayGroup

```jsonc
{ "id": "main-bar", "name": "Main Bar", "color": "#2dd4bf", "displayIds": [ "tv-01", "tv-02" ] }
```

### LightingControl and Shade

```jsonc
{ "id": "house-lights", "name": "House Lights", "areaId": "bar",
  "presets": [ { "id": "game-day", "name": "Game Day",
                 "deviceId": 4001, "command": "ACTIVATE_SCENE", "params": { "SCENE_ID": 11 } } ] }

{ "id": "shades-a", "name": "Boardroom A Shades", "areaId": "boardroom-a",
  "deviceId": 7101, "openLevel": 100, "closedLevel": 0 }   // SET_LEVEL_TARGET { LEVEL_TARGET }
```

A lighting preset is exactly one device command. Documented choices:
`ACTIVATE_SCENE { SCENE_ID }` to the Advanced Lighting Scenes agent,
`RAMP_TO_LEVEL { LEVEL, TIME }` or `SET_BRIGHTNESS_TARGET
{ LIGHT_BRIGHTNESS_TARGET, RATE }` to a light.

### RoomPanel (Simplified Room Control)

```jsonc
{ "id": "panel-boardroom-a", "name": "Boardroom A", "areaId": "boardroom-a",
  "buttons": [ { "id": "present", "label": "Present Laptop", "icon": "laptop", "sceneId": "a-present" } ],
  "volumeZoneId": "audio-a",         // optional: shows volume and mute
  "lightingId": "lights-a",          // optional: shows the lighting presets
  "shadeIds": [ "shades-a" ],        // optional: shows open / close
  "displayIds": [ "a-main" ],        // optional: displays the source picker acts on
  "showSources": true }              // optional: shows a source picker
```

A panel has at most six buttons.

### Scene

```jsonc
{ "id": "game-day", "name": "Game Day", "icon": "football", "description": "...",
  "template": "game_day",            // optional: which template it started from
  "confirm": false,                  // true: operators must confirm, and are shown a preview
  "condition": Condition,            // optional
  "program": { "steps": [ Step ] } }
```

### Rule

```jsonc
{ "id": "open-weekdays", "name": "Open on weekdays", "enabled": true,
  "trigger": Trigger,
  "condition": Condition,            // optional
  "program": { "steps": [ Step ] } }
```

### Trigger

| `type` | Fields | Fires when |
| --- | --- | --- |
| `manual` | | only from Installer Studio (Execute Test) |
| `scene_activated` | `sceneId` | that scene runs (from a screen, a schedule, Composer, or another scene) |
| `schedule` | `days` (1 = Monday .. 7 = Sunday), `time` "HH:MM" | the controller's local clock reaches it |
| `c4_event` | `name` | Composer programming runs the driver command *Trigger VenueFlow Event* with that name |
| `external` | `name` | the same mechanism and the same names as `c4_event`; the type only records that the event comes from another system through a Control4 driver |
| `device_state` | `entity` display or zone, `id`, `field` (display: power, source; zone: power, source, muted), `equals`? | that state changes (to `equals`, when given) |
| `c4_variable` | `deviceId`, `variable` | that Control4 variable changes |
| `venue_status` | `status` open or closed | the venue is marked open or closed |

### Condition

A tree. `op` is one of:

| `op` | Fields |
| --- | --- |
| `and`, `or` | `items`: list of conditions |
| `not` | `item`: one condition |
| `bool` | `value` |
| `venue_status` | `is`: open or closed |
| `time_range` | `from`, `to` "HH:MM" (a range over midnight is allowed) |
| `day_of_week` | `days` |
| `display_state` | `displayId`, `field` power or source, `equals` |
| `zone_state` | `zoneId`, `field` power, muted or source, `equals` |
| `source_available` | `sourceId` |
| `variable` | `variableId`, `cmp` (eq ne gt lt ge le), `value` |
| `c4_variable` | `deviceId`, `variable`, `cmp`, `value` |
| `context_area` | `areaId` (the area the scene was pressed in) |

A fact that cannot be read makes a condition **false**.

### Step

| `type` | Fields |
| --- | --- |
| `display_power` | `target`, `power` on or off |
| `route_video` | `sourceId`, `target` |
| `route_audio` | `zoneId`, `sourceId` |
| `volume` | `zoneId`, `level` |
| `mute` | `zoneId`, `muted` |
| `zone_power` | `zoneId`, `power` = off |
| `lighting` | `lightingId`, `presetId` |
| `shade` | `shadeId`, `action` open or close |
| `wait` | `seconds` (1 to 600) |
| `run_scene` | `sceneId` |
| `set_variable` | `variableId`, `value` |
| `set_venue_status` | `status` |
| `notify` | `message`, `level` info or warning |
| `if` | `condition`, `then`: steps, `else`: steps |

`target` is `{ "all": true }` or any combination of
`{ "displayIds": [], "groupIds": [], "areaIds": [] }`.

Limits: 60 steps per program, IF nested 4 deep, scenes nested 4 deep, a scene
that ends up running itself is refused (`SCENE_CYCLE`).

### Variable

```jsonc
{ "id": "big-game-on", "name": "Big game on", "type": "bool", "initial": false }   // bool | number | string
```

### StaffProfile

```jsonc
{ "id": "bartender", "name": "Bartender",
  "role": "bartender",               // installer | owner | manager | bartender | host | conference_staff | restricted
  "interfaces": [ "command", "floorplan" ], "defaultInterface": "command",
  "permissions": {
    "floors": "all", "areas": [ "bar" ], "sources": "all", "zones": [ "zone-bar" ], "sceneIds": [ "game-day" ],
    "routeVideo": true, "power": true, "audio": true, "lighting": false, "shades": false,
    "scenes": true, "venueStatus": false, "allOff": false, "viewAlerts": false },
  "pinSalt": "...", "pinHash": "..." }   // never sent to a browser; the Studio sees "hasPin"
```

A display is available to a profile when its floor and its area are. Scope
lists are `"all"` or a list of ids. Configuration access is not a profile
permission: it needs an Installer Studio session.

### Station

```jsonc
{ "id": "host-stand", "name": "Host station", "address": "192.168.1.52", "profileId": "host" }
```

A tile opened from that LAN address acts as that profile instead of
`defaultProfileId`. An address is not a secret (it can be imitated on the
LAN, and changes unless reserved in DHCP), so a station may only name a
profile **without a PIN**: it chooses which open profile a screen gets, and
never grants what a PIN protects (`STATION_PROFILE_HAS_PIN` is an error).

### Label and SceneButton (floor plan extras)

```jsonc
{ "id": "lbl-bar", "floorId": "main-floor", "text": "BAR", "x": 230, "y": 200, "size": 22, "locked": false }
{ "id": "sb-game", "floorId": "main-floor", "sceneId": "game-day", "x": 300, "y": 400, "w": 130, "h": 44 }
```

## Runtime state

Held in memory (`src/venueflow/state.lua`), rebuilt from Control4 at start.
One **cell** per fact:

```jsonc
{ "value": "sports-1", "status": "confirmed", "at": 1794225600, "errorCode": null, "requested": null }
```

| `status` | Meaning |
| --- | --- |
| `confirmed` | Control4 reported this value. |
| `pending` | A command was sent; feedback is awaited. |
| `commanded` | A command was sent to something that gives no feedback. |
| `unknown` | Never read, or sent and nothing could be read back. |
| `failed` | Could not be sent, or Control4 reports another value. `requested` holds what was asked. |

Cells: display `power` (on, off), `source` (source id or null); zone `power`,
`source`, `volume` (0..100), `mute` (true, false); lighting `preset`; shade
`position` (open, closed).

## Command result

Every engine call returns:

```jsonc
{ "ok": true, "status": "partial",          // accepted | partial | failed | planned (dry run) | ok
  "operationId": "op12",
  "results": [ { "id": "tv-01", "name": "TV 01", "status": "pending" },
               { "id": "tv-20", "name": "Patio Menu Board", "status": "failed",
                 "errorCode": "VF_SOURCE_NOT_ALLOWED", "message": "That source cannot be shown here." } ],
  "summary": { "requested": 6, "accepted": 4, "rejected": 2 } }
```

`accepted` means sent, not done. The final outcome per device is in the
operation (`operations` in the state document, or `OPERATION_GET`):
`confirmed`, `commanded`, `failed`, `unknown`, `superseded`.

## Configuration version

```jsonc
{ "versionId": "v3", "publishedAt": 1794225600, "note": "added patio", "by": "installer", "config": { ... } }
```

The store keeps the **draft**, the **published** version and up to five
**previous** versions, through the controller's persistence API. Floor-plan
images are kept apart under content keys and shared between versions.

## Licence state

From the SmartBuildOS Agent (`src/sbos/license.lua`): one of
`AUTHORIZED_SUBSCRIPTION`, `AUTHORIZED_PERPETUAL`, `AUTHORIZED_GRACE`, `TRIAL`,
`LEGACY`, `NOT_ENTITLED`, `ENTITLEMENT_EXPIRED`, `ACCOUNT_SUSPENDED`,
`CONTROLLER_MISMATCH`, `AGENT_UNAUTHENTICATED`, `CLOUD_VALIDATION_REQUIRED`.
VenueFlow reads only `enforces()` (a definitive denial **and** server
enforcement) to decide `restricted`.
