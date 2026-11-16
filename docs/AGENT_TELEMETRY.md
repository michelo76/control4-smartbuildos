# Agent telemetry — what Control4 exposes, what the Agent reads, what is new

Research date: 2026-10-21. Sources, in the order this repo ranks them:
hardware measurements recorded in `drivers/smartbuildos/driver.lua` and the
test suite; the 123 plaintext shipped drivers in `~/Documents/Control4/Drivers`
(first-party Control4, Chowmain, Bond, Lutron, Hue, our own); the vendored
`drivers-common-public` library (its `C4SystemEvents` table); and the official
DriverWorks docs as cited by `docs/control4-capabilities.md`. Nothing below is
invented: every call either runs in this repo today, runs in a shipped driver,
or is marked PROBE and reported rather than depended on.

Evidence classes: **MEASURED** (seen on our controllers), **VERIFIED_BY_EXAMPLE**
(a shipped driver does it), **VERIFIED_BY_DOCS**, **PROBE** (tried and reported).

## 1. The API surface a driver has (from 123 shipped drivers)

A census of every `C4:` call across the plaintext shipped drivers (count = drivers
using it) is what "Control4 exposes" means in practice. The ones that carry
telemetry, grouped:

| Group | Calls (drivers using) | What it tells us |
| --- | --- | --- |
| Controller identity | `GetSystemType` (3), `GetVersionInfo` (61), `GetUniqueMAC` (3), `GetHostname`, `GetUname`, `GetUptime`, `GetBootID` (2), `GetTimeZone`, `GetLocale`, `GetControllerNetworkAddress` (11), `GetMyNetworkAddress` (3) | model, OS, MAC, host name, kernel, uptime, boot identity, timezone, IP. **All already on the heartbeat** except timezone/locale. |
| Project | `GetDevices` (56), `GetProjectItems` (46), `GetProjectHierarchy` (3), `GetDeviceDisplayName` (45), `GetDevicesByC4iName` (52), `GetProxyDevices`/`ById` (27/8), `GetBoundConsumerDevices` (45), `GetBoundProviderDevice` (9) | every device with driver file, room, name; rooms; proxy/protocol pairs; binding topology. **Already shipped** on full sync (devices carry `driver_file`, `device_type`, `room`). |
| Device state | `GetDeviceVariables` (47), `GetDeviceVariable` (15), `RegisterVariableListener` (63) + `OnWatchedVariableChanged`, `GetCapability` (15), `GetDeviceData` (40) | every variable of every device, live changes. **Already shipped**: thermostats, sensors, lights, keypads, rooms (media). |
| Network | `GetNetworkBindingsByDevice` (3), `GetBindingsByDevice` (38), `GetNetworkConnections` (1), `CreatePingClient` (1), `GetDeviceMAC` (3) | online/offline per bound device, address, MAC (MEASURED: MAC rides the SSDP binding uuid). **Already shipped**: device monitoring, ICMP endpoints, subnet sweep. |
| Programming | `GetAllCodeItems` (1 — us) | every event attachment and its nested lines, `enabled` flag. MEASURED 2026-08. **New: periodic census** (§3). |
| System events | `RegisterSystemEvent` (14) + `OnSystemEvent`; `C4SystemEvents` has 90 named events (vendored table) | Director announcing project edits, programming edits, device online/offline, zigbee mesh, shutdown, OS update, IP/timezone change. **New: 31 registered, routed by name** (§3). |
| Director events of other drivers | `RegisterDeviceEvent` (42) / `OnDeviceEvent` | another driver's Composer events (e.g. a lock's "Locked"). Not used yet (§5). |
| History / notifications | `RecordHistory` (10), `FireEvent` (62), `SendUIRequest` (10) | write side: the Agent already files History and fires events for the Notification Agent. |
| Media | `MediaGetAllBroadcastAudio` (1), `MediaGetBroadcastAudioInfo` (1), room variables | what is playing, per room. **Already shipped** via room variable listeners. |
| Misc | `FeatureFlags` (first-party only), `StartDaemon` (first-party only), `GetGeoSettings` (1), `GetProjectProperty` (1), `GetSandboxDir` (1), `FileList` (1) | `FeatureFlags`/`StartDaemon` are Control4-internal. `GetGeoSettings`/`GetProjectProperty('countrycode')` used by our Apple TV driver (location). |

What **no** documented call exposes (and the 2026-09 sweep confirmed): CPU and
memory, service tag, I/O firmware, ZAP state, the Composer project's edit
history, who is logged into Composer. §3 probes the first two through `/proc`.

### Director system events worth listening to (ids from the vendored `C4SystemEvents`)

| Id | Name | Who else registers it | Meaning for us |
| --- | --- | --- | --- |
| 6 | OnPIP | communication_agent_v2 (first-party), LuminaLogic | "bindings, device names or device media changed" (docs) |
| 7 / 8 / 11 / 12 | OnItemAdded / NameChanged / Removed / Moved | communication_agent_v2, nowplaying-hdmiout | Composer edited the project |
| 13 | OnDriverAdded | — (table) | a driver was added |
| 15 / 16 | OnBindingAdded / Removed | triad_ams16, Episode amps | wiring changed |
| 17 / 18 / 48 / 49 / 78 | network binding, device online/offline, SDDP | **the Agent, since 2026-08** | device reachability |
| 21 / 22 / 23 | OnCodeItemAdded / Removed / Moved | — (table) | programming edited |
| 46 / 47 / 69 | OnProjectLocked / LeaveLock / EnterLock | — (table) | a Composer session took/released the project |
| 56 | OnControllerDisabled | — (table) | — |
| 57 | OnDeviceFirmwareChanged | — (table) | a device took firmware |
| 58 / 64 / 90 | OnLocaleChanged / OnTimezoneChanged / OnDirectorIPAddressChanged | — (table) | identity changed |
| 59 / 61 / 76 / 77 | Zigbee nodes/mesh changed, node online/offline | — (table) | mesh health |
| 85 / 86 | OnSystemShutDown / OnSystemUpdateStarted | triad_ams16 | Director is going down, and why |

The payload: docs say "event specific … can be ignored"; bond and Integra read
`string.match(event, '.-name="(.-)"')`. The Agent does the same and treats an
unreadable payload exactly as before (one debounced poll). **Which of these a
given OS actually fires is unknown until measured**, so the heartbeat now
carries `system_events` (name → count since start): the fleet answers the
question.

## 2. What the Agent already collected (before this change)

Heartbeat: identity, OS/driver versions, Director IP/MAC/uptime/project name,
device counts, capabilities, queue depth, cadence, update channel, reload
count/kind, the Agent contract block. Devices: online/offline deltas with
address, MAC, driver file, SSDP type, room. Telemetry: room media state and
sessions, thermostats, sensors (lock/security/leak/opening/motion/contact/
relay/power, batteries), lights (level, watts), keypad presses (journaled),
album art. Catalogue: every room/device variable name sampled. Diagnostics and
the capability probe on demand. Startup observations (System Studio Agent v1).

## 3. New in this change (driver `feat/agent-telemetry`)

All additive: the platform may ignore every new heartbeat field; absence is an
older Agent. Each also lands in Composer (property, event, variable) so it is
useful before the platform reads it.

| Feature | Evidence | Heartbeat field | Composer |
| --- | --- | --- | --- |
| **System events by name**: 31 registered, routed (device → poll; project → flush; programming → census; zigbee → counters; shutdown/os-update → markers; identity → heartbeat) | ids VERIFIED_BY_DOCS (vendored table), names 6/7/8/11/12/15/85/86 VERIFIED_BY_EXAMPLE, payload parse VERIFIED_BY_EXAMPLE (bond, Integra) | `system_events` {name: count} | — |
| **Project change** (Composer add/remove/rename/rebind), debounced 30 s, then re-discovery 60 s later so a device added today is monitored today | as above | `project_changes_today`, `last_project_change_at`; journal SYSTEM/`project_changed` | property Last Project Change, event Project Changed, variable LAST_PROJECT_CHANGE |
| **Programming census**: attachments, nested lines, disabled lines; daily and on OnCodeItem* | `GetAllCodeItems` MEASURED 2026-08 | `programming` {groups, attachments, lines, with_text, disabled} | property Programming, event Programming Changed, variable PROGRAMMING_DISABLED_LINES |
| **Restart cause**: a reload is `clean` (OnSystemShutDown marker ≤ 6 h before), `os-update` (OnSystemUpdateStarted marker), or `unexpected` (no marker: power loss, crash, hard reset) | 85/86 VERIFIED_BY_EXAMPLE (triad_ams16); marker persistence is ours | `last_reload_restart`; the director-reload event carries `restart` | Last Reload shows the cause; event Unexpected Restart; event OS Update Started |
| **Clock offset**: platform `Date` header vs `os.time()` on every delivered answer; drift ≥ 120 s announced once (hysteresis 60 s) | `C4:url` responseHeaders VERIFIED_BY_DOCS (lib.http exposes them); RFC 7231 Date | `clock_offset_seconds` | property Clock Offset, event Clock Drift Detected, variable CLOCK_OFFSET_SECONDS; journal SYSTEM/`clock_drift` |
| **Zigbee counters**: node offline/online, mesh/nodes changed since start | 59/61/76/77 VERIFIED_BY_DOCS (table only) | `zigbee` {node_offline, node_online, mesh_changes} | property Zigbee Events |
| **Agent health**: Lua heap (`collectgarbage("count")`), heartbeat timer lag (`C4:GetTickCount`), driver uptime | standard Lua; GetTickCount MEASURED | `agent_health` | — |
| **Controller vitals (PROBE)**: `/proc/loadavg`, `/proc/meminfo`, `/proc/uptime`, thermal zone, through `io.open` | `io.open` VERIFIED_BY_EXAMPLE (bond-bridge reads its own XML); whether `/proc` is readable from a driver is UNMEASURED | `controller_vitals` only when something was readable (`readable` lists what) | Generate Diagnostics prints each file's readability |
| **Shutdown / OS-update notice**: a last `event` post before Director goes down | 85/86 as above | event route: `controller_shutting_down`, `os_update_started` | — |

Pure rules live in `src/sbos/agenttelemetry.lua` (tested in
`test/test_agent_telemetry.lua`); the wiring in `drivers/smartbuildos/driver.lua`
(tested in `test/test_smartbuildos_connector.lua` §52–54). The main chunk of
the Agent is at Lua's 200-local ceiling: the new module handle, the restart
keys and `NoteClock` are globals for that reason.

## 4. What the platform must add to use it (web repo, not done here)

- `heartbeat` route: read `clock_offset_seconds`, `agent_health`,
  `controller_vitals`, `programming`, `zigbee`, `system_events`,
  `project_changes_today`, `last_reload_restart` into controller columns or a
  JSON column (the normaliser drops unknown keys today).
- `event` route: `controller_shutting_down`, `os_update_started`, and the
  `restart` field on `director_reloaded` → the startup classifier
  (`unexpected` is the alert; `os-update` explains a reboot).
- Telemetry rows: SYSTEM/`project_changed`, SYSTEM/`clock_drift`,
  SYSTEM/`controller_disabled` are already accepted by the CHECK (SYSTEM is a
  listed category) and need a reader.
- Fleet views: clock offset distribution; `system_events` per OS version (which
  events fire where); programming disabled-lines in the maintenance report;
  `unexpected` restarts per site.

## 5. Not done, and why

- **Event origin (human vs programming)** for the override-rate metric: no API
  found; `OnWatchedVariableChanged` carries no origin. Still open since T-0.6.
- **Other drivers' Composer events** (`RegisterDeviceEvent`): would give lock/
  alarm transitions at the instant rather than at the 5-minute sample. Needs
  the event ids per driver (varies by vendor); a probe that dumps a lock's
  event list is the next step, not a guess.
- **Zigbee node identity** on 76/77: the payload shape is unmeasured; counts
  only until a controller shows what the event carries.
- **CPU/memory** beyond the `/proc` probe: no documented call.
- **Who is in Composer**: `OnProjectEnterLock`/`LeaveLock` are counted; whether
  they correspond to a Composer session is unmeasured.
