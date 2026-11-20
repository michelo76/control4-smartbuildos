# System Studio × SmartBuildOS Agent — contract, gaps and agent backlog

Read-only survey, 2026-11-20. Nothing was edited, checked out, pushed, run or queried.

**Sources and how they are cited**

- **Web** = clean checkout of `origin/main` at `c2f91e8c5`, at `.../scratchpad/ss-main`. Paths are relative to it.
- **Drv** = driver repo `control4-smartbuildos` at `origin/main` = `f9326b7` (2026-11-20 08:05, "Merge pull request #52"). I exported it with `git archive` to `.../scratchpad/drv-main` and read it there. Paths are relative to the repo root.
  - ⚠ The primary checkout `/Users/michelogermain/Documents/Codex/control4-smartbuildos` is **not** the released line. It sits on `wip/uncommitted-rescue-20260831`, 340 commits behind `origin/main`. It has 9 modified files, including `drivers/smartbuildos/driver.lua`, `Makefile` and `VERSION`. Do not plan from that working tree.
- The Agent is `drivers/smartbuildos/driver.lua`: 9,756 lines, plus `src/sbos/*.lua`, `src/telemetry/*.lua` and `src/lib/*.lua`.
- Every claim below comes from reading code unless it is marked **UNVERIFIED**.
- I folded in four other reports from the same folder: `code-data-model.md`, `browser-core.md` (its Data gaps section), `browser-tooling-ai.md` (its §E) and `notes.md`. I only skimmed `code-visual-system.md`.

---

## 0. Headline facts

1. **Every device reads "Stale" by construction. The cause is the Agent's cadence, not an outage.**
   - The Agent sends a full snapshot once every **24 h** by default (`Full Sync Interval`, Drv `driver.xml:770-772`, `driver.lua:4639`).
   - Between snapshots it sends **only changed devices**, and sends nothing at all when nothing changed (`driver.lua:2405-2414`).
   - `control4_devices.last_seen_at` is written only for devices in a payload (Web `src/lib/control4/ingest.ts:394`).
   - Studio calls any observation older than **15 min** "stale" (Web `src/lib/system-studio/workspace-model.ts:232,255`).
   - Result: Overview shows "0 online / 0 offline / 13 stale · 7 h ago" while the controller checked in "1 min ago" (`browser-core.md` contradictions). The inspector then disables controls with "Unavailable while Control4 is not reporting" (`DeviceInspector.tsx:82-85`).
2. **The Agent already sends a lot that Studio never shows.** Studio's bootstrap selects none of the following (Web `bootstrap/route.ts:72`):
   - controller vitals: load, memory, CPU temperature, /proc uptime;
   - Lua heap and timer lag;
   - Director uptime, IP, MAC, Composer project name;
   - clock offset; programming census; Zigbee mesh counters; Director system-event counts;
   - reload count, kind and cause;
   - telemetry queue depth and drops; consecutive failures; update-channel state.

   They render only in the Clients-module page `src/components/clients/PropertySystemWorkspace.tsx`.
3. **The whole `agent_contract` heartbeat block is ignored by the server.** Drv `driver.lua:3184-3209` sends it; nothing in Web `src` reads `agent_contract`. It carries:
   - applied settings version and monitoring state;
   - startups and reboots today and lifetime;
   - last startup classification;
   - service-mode expiry;
   - pairing and cloud state;
   - pending observations.

   Agent settings therefore says "Applied version · Not reported by agent" (`SystemStudioAgentSettingsWorkspace.tsx:162`), even though the Agent reports it on every beat. It also posts `agent_config_applied` events (`driver.lua:1409-1413`).
4. **The released Agent cannot do an update check at all.**
   - It does not declare `update_check_v1` (`driver.lua:2460-2491`).
   - It has no `REQUEST_UPDATE_CHECK` runner (`driver.lua:3312-3654`).
   - It never calls `/api/driver-cloud/update-observations`.
   - No local or remote branch contains either string (I grepped every branch).
   - So every Drivers row reads "Check unavailable" and "Update checks · Not declared by this Agent" (Web `SystemStudioLicensingWorkspace.tsx:172`).
5. **The device payload is thinner than the schema allows.** For project devices the Agent never sends `firmware`, `device_status`, `wake_status` or `port`. It sends `driver_file` (`driver.lua:1845`), but the server drops it (`ingest.ts:192-237` has no `driver_file`).
   - So "Firmware", "Operating state" and "Driver file / version" are always empty (`DeviceInspector.tsx:149,170-171`).
   - Devices without a network binding (IR, serial, relay) are never sent (`driver.lua:1814-1822`).
6. **Room identity is a name.** The Agent sends `room = device.roomName` (`driver.lua:1844`). It has the integer `roomId` from `C4:GetDevices` and uses it for the observables catalogue (`driver.lua:4602,4934`), but it does not send it with device rows. The server's `room_id` accepts only a uuid (`ingest.ts:219`).
7. **MAC coverage is partial.** MAC comes only from the tail of an SSDP binding `uuid` (`macFromUuid`, `driver.lua:1743-1758`). IP devices bound any other way have no MAC, so they cannot be joined to UniFi or `installed_devices`. Two candidate sources are not wired: Zigbee EUIDs, which sit in the same `uuid`, and `C4:GetDeviceMAC` (listed in Drv `docs/AGENT_TELEMETRY.md` §1 as used by 3 shipped drivers).
8. **Room, media, light, thermostat and sensor state flow only when a dealer has switched monitoring on.**
   - Drv `driver.lua:5956-5958`: `if not gMonitor.enabled ... return`.
   - Server default is `enabled = false` (Web `src/lib/control4/telemetry.ts:711-724`).
   - Studio's empty Media page blames "Control4 has not reported room media state" and never says monitoring is off.
   - Sensors with `battery_level`, `low_battery` and `link_quality` are already stored and returned by `GET /api/monitoring/control4` (`route.ts:203-204`). Studio's `ControlRoomPayload` type has no `sensors` field (`workspace-model.ts:37-47`), so batteries and link quality are never shown.
9. **Studio is missing technician actions the Agent already supports.** Full sync, diagnostics, network scan, catalogue resend, test notification and camera snapshot are all allowlisted and implemented (`driver.lua:3312-3654`). Studio offers none of them; only the Clients page does (`PropertySystemWorkspace.tsx`). Studio's "Reboot" button (`DeviceInspector.tsx:103`) has **no verb behind it**: there is no reboot in `COMMAND_ALLOWLIST` (`src/lib/control4/commands.ts:20-60`).
10. **All agent-related worktrees are merged.**
    - `agent-push`, `agent-vnext`, `agent-pairing`, `agent-as-agent`, `flight-recorder`, `event-tracer`, `dealer-tools`, `daily-reboots` and `system-link` all have HEAD as an ancestor of `origin/main`.
    - `agent-telemetry`: 767 of its 769 added lines are present in `origin/main`.
    - `agent-no-touchpanel`: a pure deletion; the touchpanel is gone from `origin/main`'s `driver.xml`.
    - Uncommitted leftovers sit in the worktrees (§7.7). Nothing agent-related is waiting on a branch.

---

## 1. The Agent's contract today

The Agent has no inbound channel. Every message is a push from the controller.

- **Ingest routes** live under `{API URL}/api/integrations/control4/<path>` (`driver.lua:693-700`).
- **Driver Cloud routes** live under `/api/driver-cloud/<path>` (`driver.lua:705-712`).
- **Common envelope.** Every ingest post goes through `send()` (`driver.lua:1076-1120`). It adds:
  - `system` = `systemIdentity()` (`driver.lua:877-893`): `property_id`, `system_id`, `controller_type`, `os_version`, `driver_version`, `device_id`, `driver_name`, `driver_device_id`, `director_device_id`, `director_name`;
  - `technical_metadata` = `composer_project_ref`, `director_ip`, `director_mac`, `uptime_seconds` (`driver.lua:1095-1117`);
  - `sent_at`.
- **Auth.** Bearer token plus advisory `X-SmartBuildOS-Property` / `-System` headers (`driver.lua:716-725`). Tenant identity comes only from the token (`control4-auth`).
- **Commands** return in the response of `heartbeat` and of `devices`, through `claimCommands` (Web `heartbeat/route.ts:335-340`, `devices/route.ts:135-140`).

| # | Message | Transport / cadence | Payload fields (type) | Lua builder | Server route | Lands in | Studio screens that show it |
|---|---|---|---|---|---|---|---|
| 1 | **heartbeat** | Push on timer `Heartbeat Interval`, default `1m` (`driver.xml:754-756`; `driver.lua:4627`; the server can override with `monitor.heartbeat_seconds`) | `kind`, `consecutive_failures` int, `devices_total` / `devices_offline` int, `capabilities` string[], `queued_telemetry` / `telemetry_dropped` int, `heartbeat_seconds` int, `update_channel` obj, `director_reloads` / `_today` int, `last_reload_at` iso, `last_reload_kind` enum, `last_reload_restart` enum, `clock_offset_seconds` int, `system_events` {name:int}, `project_changes_today` int, `last_project_change_at` iso, `programming` {groups, attachments, lines, with_text, disabled}, `zigbee` {node_offline, node_online, mesh_changes}, `controller_vitals` {load1/5/15, tasks, mem_total_kb, mem_available_kb, mem_used_pct, proc_uptime_seconds, cpu_temp_c, readable[]}, `agent_health` {lua_memory_kb, heartbeat_lag_ms, driver_uptime_seconds}, `modules` [], `event_pipeline` obj, `module_bus` obj, `module_protocol` {min,max}, `agent_contract` {18 fields}, plus the common envelope | `sendHeartbeat` `driver.lua:3121-3210` | `heartbeat/route.ts:41-375` | `control4_controllers`: `last_heartbeat_at`, `last_seen_at`, `controller_type`, `os_version`, `driver_version`, `director_name`, `director_device_id`, `capabilities`, `technical_metadata` (merged; `.agent` sub-object per `src/lib/control4/agent-telemetry.ts`), `director_reloads`, `last_reload_at`, `last_reload_kind`, `devices_reported`, `devices_reported_offline`, `devices_reported_at`, `heartbeat_seconds`. Also `control4_agent_modules` (`:219-271`) and `ai_core_driver_modules` (`:260`). **Dropped:** `consecutive_failures`, `queued_telemetry`, `telemetry_dropped`, `update_channel`, `module_bus`, `module_protocol`, `agent_contract`, `director_reloads_today` (the last is read only by the event route) | Top-bar chip, Overview "Last report" and "Controller / OS" (`StudioOverview.tsx:113-114`), Connections Status / Capabilities / Diagnostics, Licensing controller card (`licensing/route.ts:189`), Commissioning freshness. `technical_metadata`: **not in Studio**; only `PropertySystemWorkspace.tsx` and the `system-intelligence` route |
| 2 | **devices `snapshot`** | Push on timer `Full Sync Interval`, default `24h` (min 6h) (`driver.xml:770-777`; `driver.lua:4639,4659`), plus on pairing and on `REQUEST_FULL_SYNC` | `kind:"snapshot"`, `devices[]` (shape in row 3) | `sendFullSync` `driver.lua:2319-2336`; rows from `readAllState` `:2268-2282` = `readDeviceState` `:1814-1870` + `pingEndpoints` `:1914-` + discovered `:4694-4716` | `devices/route.ts:24-150`; `normalizePayload` / `planDeviceWrites` `ingest.ts:247-451` | `control4_devices` upsert on `(system_id,key)`; `control4_device_events` (appeared / online / offline / removed); `control4_controllers.devices_total` / `devices_offline` / `last_seen_at` | Overview, Rooms, Devices, Media, inspector (via bootstrap) |
| 3 | **devices `delta`** | Push on timer `Device Poll Interval`, default `5m` (`driver.xml:559-561`; `driver.lua:4638,4658`). Only appeared, flipped or removed devices; **nothing is sent when nothing changed** (`:2405-2408`) | each device: `key` "c4:<id>" / "ping:<host>" / "discovered:<ip>", `source` director/ping/discovered, `device_id` int, `name`, `online` bool, `connection_type` (from `addresstype`), `address`, `binding_id` int, `network_status`, `room` (name), `driver_file`, `mac` (SSDP uuid only), `device_type` (`ssdptype`); ping rows add `connection_type:"icmp"`; discovered rows add `port`, `device_status`=manufacturer+model; removed rows `{key, source, device_id, name, removed:true}` | `pollDeviceState` `driver.lua:2343-2415` | same as row 2 | same; **`driver_file` is dropped** (`ingest.ts:192-237`) | same |
| 4 | **event** | Push on occurrence | `kind:"event"`, `name`, `detail`. Names: `sync failed`, `full sync failed`, `director_reloaded` (+reload counts), `agent_config_applied` / `_refused`, `network scan`, `network scan failed`, `diagnostics NN`, `survey NN`, `probe NNN`, `service note`, programmed names | `send("event", …)` `driver.lua:1198,1218,1409,2194,2246,7216,7569,8180,8235,8291,8490,8505` | `event/route.ts` | `control4_device_events` with `device_key = "event:<name>"` (`:53`); reloads into `control4_controllers` (`:71-90`) and `control4_alert_log`; `.agent` telemetry stamps | Activity → System (`activity/route.ts`, ledger "Provider observation"); inspector Activity only for device keys. Config-applied events are **not** read by Agent settings |
| 5 | **startup-observation** | Push after the stabilization delay on each startup; retried after a successful heartbeat | `source_event_id`, `observed_at`, `local_date`, `event_type`, `classification`, `confidence`, `clock_status`, `notification_decision`, startup / reboot counters, `execution_controller_identity`, `primary_controller_identity` (always null by design), `primary_controller_reboot_observed`, `boot_id_supported` (Web `startup-observation.ts:17-33`) | `driver.lua:1497`; boot id `C4:GetBootID` `:1468` | `startup-observation/route.ts` | `control4_startup_observations`, `control4_notification_intent_events` | Reports (report artifact), Commissioning gate "primary-controller-verified" (always pending) |
| 6 | **telemetry `kind:"state"`** | Push every 5 min plus debounced 10 s on change; **only if `gMonitor.enabled`** (`driver.lua:5956-5958`) | `rooms[]` {room_id int, room_name, powered, source_device_id, source_name, media_title / artist / album / type, media_image_url / data, volume, muted, in_navigation, temperature} (`src/telemetry/rooms.lua:405-425`), `thermostats[]`, `sensors[]` {category, state, battery_level, battery_status, low_battery, link_quality} (`driver.lua:5506-5514`), `lights[]` | `sendTelemetry` `driver.lua:5956-5981` | `telemetry/route.ts:134-205` | `control4_room_state`, `control4_thermostat_state`, `control4_device_sensors`, `control4_light_state` | Media, Overview "House now", Rooms, inspector light / thermostat controls. **Sensors are not shown** |
| 7 | **telemetry `kind:"sessions"`** | Push when a room session ends (gated as row 6) | completed sessions {room, source, title, started_at, ended_at, duration} | `driver.lua:5984-5988` | `telemetry/route.ts:209-212` | `control4_room_sessions` | Activity → House; Usage |
| 8 | **telemetry `kind:"telemetry"`** | Journaled queue, flushed every 45 s (`driver.lua:4660`); keypad presses flush after 5 s | events by category: `DEVICE` (transitions), `KEYPAD` (`:5205`), `CLIMATE`, `MEASUREMENT`, `SYSTEM` (clock_drift, project_changed, controller_disabled), `CUSTOM`. **No `SCENE` category exists** | queue `src/telemetry/queue.lua`; flush `driver.lua:3740` | `telemetry/route.ts:74-94` | `control4_telemetry_events` (partitioned) | Activity → House; Usage analytics ("scenes: not collected", `house-activity.ts:111-112`) |
| 9 | **telemetry `kind:"catalogue"`** | Once, plus on `REQUEST_CATALOGUE` or `DISCOVER_VARIABLES` | `observables[]` {kind, source_id, source_name, room_id int, room_name, variable_id, variable_name, sample_value, readonly} | `driver.lua:4590-4615,5067` | `telemetry/route.ts:96-130` | `control4_observables` | Flight Recorder settings (source picker) |
| 10 | **commands (acks)** | Push right after running commands claimed from a heartbeat or devices response | `acks[]` {id, ok, result \| error ≤400} | `collectCommands` `driver.lua:3661-3690` | `commands/route.ts` | `control4_commands` status / result; AI Core outcomes | Inspector command status (`StudioContext.tsx:87-103`), Connections, Licensing, FR, VenueFlow |
| 11 | **camera-snapshot** | Push in reply to `CAMERA_SNAPSHOT` | `device_key`, `request_id`, `content_type`, `image_base64` | `driver.lua:2743-2750` | `camera-snapshot/route.ts` | **not stored**; relayed on the realtime camera channel | Not in Studio (`CameraLiveView.tsx` in Clients only) |
| 12 | **events (Flight Recorder envelopes)** | Push every 30 s (`driver.lua:4661`) | `kind:"events"`, `events[]` (envelope: ≤100 per batch, 4 KB payload, 32 KB frame, `envelope.ts:15-27`), `pipeline` health | `FlushEvents` `driver.lua:4310-4313` | `events/route.ts` | RPC `flight_recorder_ingest` → `flight_recorder_events` / traces; `flight_recorder_ingest_gaps`; `.agent.event_pipeline` | Flight Recorder (all tabs), Dealer tools, VenueFlow, AI |
| 13 | **snapshots** | Push in reply to `MODULE_COMMAND` | `module_id`, `instance_id`, `job_id`, `document`, `status` | `driver.lua:4552` | `snapshots/route.ts` | `flight_recorder_snapshots` + storage bucket | FR Snapshots; VenueFlow |
| 14 | **push** (programmed push notification) | Push on Composer action | `source_event_id`, `observed_at`, `title` ≤120, `body` ≤500, `severity`, `source` (Web `agent-push.ts:30-117`) | `driver.lua:8589-8591`; `src/sbos/agentpush.lua` | `push/route.ts` | `notifications` (dispatch) + `control4_device_events` audit row, key `agent_push` | Activity → System (as a driver event) |
| 15 | **modules/rpc** | Push on a module request | closed AI Core vocabulary | `driver.lua:3897`; `src/sbos/modulepolicy.lua:187-217` | `modules/rpc/route.ts` | `ai_core_jobs`, `ai_core_context` | Intelligence |
| 16 | **pair / request-code / verify-code / unpair / heartbeat test** | Push on dealer action | code, system identity (+ `director_mac`) | `driver.lua:6188,6256,6288,8302,7070` | `pair*/route.ts`, `unpair/route.ts` | `control4_controllers`, `control4_pairing_codes`, `control4_email_pairing_codes` | Connections |
| 17 | **Driver Cloud: entitlements/refresh** | Push hourly tick (`driver.lua:4657`) plus on registration | installed SmartBuildOS drivers (SKU, version, device id) | `refreshEntitlements` `driver.lua:9189-` | `/api/driver-cloud/entitlements/refresh` | `driver_installations`, `driver_entitlements`, site licences | Drivers & Licenses, Overview drivers tile, Dealer tools, Commissioning |
| 18 | **Driver Cloud: events** | Push on licence or driver events | severity, category, code, message, sku | `driver.lua:2758,8795,9178` | `/api/driver-cloud/events` | `driver_events` | Not in Studio (**UNVERIFIED**: none found) |
| 19 | **Driver Cloud: devices** | Push when a SmartBuildOS driver (e.g. UniFi Protect) hands its roster over | {kind, id, name, mac, state, model, firmware} per device | `forwardDeviceRoster` `driver.lua:9611-` | `/api/driver-cloud/devices` | `driver_devices`, `driver_device_name_history` | Alerts evidence text only (`code-data-model.md` §1.2) |
| 20 | **Driver Cloud: state, state/provision, system-link/provision** | Push on module request | driver state mirror | `driver.lua:3078,9479,9557` | same-named routes | **UNVERIFIED** | System Link, Atmosphere |
| 21 | **Driver Cloud: updates** (GET) | Pull every 30 min (README "Automatic Updates") | — | `driver.lua:7019`; `src/lib/sbos-updater.lua` | `/api/driver-cloud/updates` | reads `driver_packages` / `_manifests` | — (installs silently; the result is not reported back, §3) |
| — | **update-observations** | **never called** | — | — | `/api/driver-cloud/update-observations` | `driver_update_observations` stays empty | Drivers & Licenses "Last checked · Never" |

---

## 2. Fields sent (or stored) but unused by Studio — free wins, no driver release

| Field (where it lands) | Sent by | What Studio could show | Where the hole is now | Needed |
|---|---|---|---|---|
| `technical_metadata.agent.controller_vitals` (load, memory %, CPU °C, /proc uptime) | hb `driver.lua:3171` | Controller health card: CPU load, memory, temperature, OS uptime | `browser-tooling-ai.md` §E "controller CPU / memory / storage / uptime: not shown anywhere" | Add the column to the bootstrap select; UI. ⚠ The vitals are a **PROBE**: `io.open` on /proc may be refused on real hardware (`docs/AGENT_TELEMETRY.md`; the `readable[]` field says which files answered) |
| `technical_metadata.uptime_seconds` + `uptime_reported_at`, `director_ip`, `director_mac`, `composer_project_ref` | send() envelope `driver.lua:1095-1117` | Controller card: project name, LAN IP, MAC, uptime | Overview "Controller / OS" shows only type and OS (`StudioOverview.tsx:114`) | bootstrap select + UI |
| `.agent.clock_offset_seconds` (drift ≥120 s flagged, `agent-telemetry.ts:127`) | hb `:3150` | "Clock drifting" attention row | absent | UI |
| `.agent.programming` census, `project_changes_today`, `last_project_change_at` | hb `:3156-3163` | "Programming: N groups, M disabled lines"; "Project last edited …" | absent; `browser-tooling-ai.md` "Composer programming summary not shown" | UI |
| `.agent.zigbee` {node_offline, node_online, mesh_changes} | hb `:3165` | Zigbee mesh churn indicator | absent | UI |
| `.agent.system_events`, `.agent.last_reload_restart`, `director_reloads`, `last_reload_at` / `_kind` (columns) | hb `:3145-3152` | Overview "Startups / reboots" value instead of the link-only "See diagnostic reports" (`StudioOverview.tsx:116`) | link only | bootstrap select + UI |
| `.agent.agent_health` (Lua heap, timer lag, driver uptime) | hb `:3173-3177` | Agent health on Connections → Diagnostics | absent | UI |
| `.agent.event_pipeline` | hb `:3180` | already shown on FR Driver tab (`FlightRecorderDriver.tsx:41-43`); "1947 failed" has no reason | no failure reason | Driver change for the reason (backlog #12) |
| `agent_contract.*`: `settings_version`, `monitoring_state`, startup / reboot counters, `last_startup_classification` / `_confidence`, `service_mode_expires_at`, `pairing_state`, `cloud_connection_state`, `agent_version`, `license_state`, `pending_startup_observations` | hb `driver.lua:3184-3209` | Agent settings "Applied version" / "Delivery state"; Overview "Service mode" active-until; startups today | `SystemStudioAgentSettingsWorkspace.tsx:162` "Not reported by agent"; Overview `:117` link only | **Server**: parse and store (e.g. under `technical_metadata.agent_contract`, which needs no migration and follows the same merge rule), then UI |
| `event:agent_config_applied` / `_refused` rows (`control4_device_events`) | `driver.lua:1409-1413` | "Configuration v12 applied 3 min ago" or "refused: field X" | same as above | Server read + UI |
| `consecutive_failures`, `queued_telemetry`, `telemetry_dropped`, `update_channel`, `module_bus` | hb `:3127-3143,3182` | Connections → Diagnostics "Last source error"; updater health; dropped telemetry | Connections "Last source error · Not reported by the current Control4 source" (`browser-core.md`) | Server: store (same jsonb approach) + UI |
| `devices_reported` / `_offline` / `_reported_at` (columns) | hb `:3129-3130` | The Agent's own count next to stored rows. Also the basis of the interim liveness rule in §5 | not selected | bootstrap select |
| `driver_file` per device | devices `driver.lua:1845` | Inspector "Driver file / version" | `DeviceInspector.tsx:170` "Not reported by the Connector" | **Server**: normalise + new `control4_devices.driver_file` column (migration) + UI |
| `binding_id` per device (stored) | devices `:1842` | Diagnostics fact | not selected by bootstrap (`bootstrap/route.ts:80`) | select + UI |
| `control4_device_sensors.battery_level`, `low_battery`, `battery_status`, `link_quality` | state `driver.lua:5506-5514` | Battery and link-quality columns or tiles; "low battery" attention | returned by `GET /api/monitoring/control4` (`route.ts:203-204`) but dropped by the `ControlRoomPayload` type (`workspace-model.ts:37-47`). `browser-core.md`: "no … signal, battery … columns exist" | UI + type (requires monitoring enabled) |
| `control4_room_state.source_device_id` | state `rooms.lua:414` | Exact room → source device join | Studio joins by **name** (`StudioOverview.tsx:98`, `StudioMedia.tsx:120`) | UI |
| `control4_monitor_config.enabled` | server | "Room and media monitoring is off. Enable it" instead of "Control4 has not reported room media state" | `StudioMedia.tsx:131` | Server read + UI |
| Allowlisted verbs implemented by the Agent but absent from Studio: `REQUEST_FULL_SYNC`, `REQUEST_DIAGNOSTICS`, `RUN_NETWORK_SCAN`, `REQUEST_CATALOGUE`, `SEND_NOTIFICATION`, `CAMERA_SNAPSHOT`, `PROBE_CAPABILITIES` | `driver.lua:3313-3654` | "Refresh inventory now", "Run diagnostics", "Scan subnet", "Send test notification" (also clears the Commissioning gate), "Take snapshot" | in `PropertySystemWorkspace.tsx` / `CameraLiveView.tsx` only | UI |
| `network scan` event detail (subnet sweep results) | `driver.lua:2194,2246` | Network → "Answering IPs not in the project" when UniFi is absent | Network page is UniFi-only | UI (text parse; structured data needs a driver change) |
| FR `device_id` int = `c4:<id>` key space | FR envelopes | FR → Devices link | broken: Devices selects by uuid (`code-data-model.md` §2.3) | UI (resolve the key to a uuid). Not an Agent gap |

---

## 3. Fields Studio wants but does not get (Agent gaps)

Sizes: **S** < 1 day of driver work, **M** a few days, **L** a week or more or hardware research.

Evidence for a C4 API: **USED** = the released Agent already calls it (file:line). **EXAMPLE** = a shipped third-party driver uses it, per `docs/AGENT_TELEMETRY.md` §1. **UNVERIFIED** = not seen in this repo.

| # | Field Studio wants | Where the UI shows the hole (file:line + wording) | Source / C4 API | Size | Server change | UI change |
|---|---|---|---|---|---|---|
| G1 | **Per-device "confirmed at" / poll freshness** | Every device "Stale · 7 h ago"; controls disabled with "Unavailable while Control4 is not reporting" (`DeviceInspector.tsx:85`; `workspace-model.ts:255`) | No new API. Report a poll digest each poll: heartbeat `device_poll = {completed_at, devices, offline, digest}` from `gDeviceState` (`driver.lua:2343-2405`) | S | Yes: store `devices_confirmed_at` (controller jsonb or column). `studioDeviceObservations` uses max(last_seen_at, confirmed_at) | small |
| G2 | **Firmware per device** | Inspector "Firmware · Not reported" (`DeviceInspector.tsx:171`); Devices Firmware column | Device variables (`C4:GetDeviceVariables`, USED `driver.lua:4590`), e.g. a FIRMWARE / VERSION variable: **UNVERIFIED** names. System event 57 `OnDeviceFirmwareChanged` (EXAMPLE table) | M | no (column `firmware` exists) | none |
| G3 | **Driver file + driver version per device** | `DeviceInspector.tsx:170` "Driver file / version · Not reported by the Connector" | `driverFileName` from `C4:GetDevices` (USED `:1845`, already sent). Version: `C4:GetDeviceData(id, "version")` **UNVERIFIED** (only "name" is used, `:888`) | S (file: server only); M (version) | Yes: `driver_file`, `driver_version` columns | none |
| G4 | **Integer Control4 room id** with each device | Rooms keyed by lowercased name (`workspace-model.ts:375`); FR → Room link broken | `roomId` from `C4:GetDevices` (USED `:4602,4934`) | S | Yes: `c4_room_id int` (the existing `room_id` is a uuid) | Rooms keyed by id |
| G5 | **Room list incl. empty rooms, floors** | Rooms derived only from devices and room state; empty rooms invisible (spec principle "keep empty rooms", `code-data-model.md` §8.6) | `C4:GetProjectItems("LOCATIONS", …)` (USED `:741-760`), which yields site / building / floor / room | S | Yes: a `control4_rooms` table, or a jsonb on the system | Rooms |
| G6 | **MAC for every IP device; Zigbee EUID** | Inspector MAC "Not reported", "No MAC reported by Control4 to match" (`DeviceInspector.tsx:128,160`) | `C4:GetDeviceMAC` (EXAMPLE, 3 drivers); Zigbee 16-hex from binding `uuid` (USED shape `:1735-1738`); `/proc/net/arp` (PROBE, **UNVERIFIED**) | S (EUID) / M (MAC) | Yes: `zigbee_eui` column | small |
| G7 | **Operating state** (power, standby) | `StudioDevices.tsx:18`, `DeviceInspector.tsx:149` "Not reported" | `POWER_STATE` and similar variables via `GetDeviceVariables` (**UNVERIFIED** per device class) | M | none (`device_status` / `wake_status` exist) | none. ⚠ discovered rows misuse `device_status` = manufacturer+model (`driver.lua:4713`), which then renders as "Operating state" |
| G8 | **Devices with no network binding** (IR / serial / relay) as "unmonitored" | Studio has the "unmonitored" state (`workspace-model.ts:178`) but never receives such rows (`driver.lua:1822-1823` skips them) | `C4:GetDevices` (USED) | S | none | none |
| G9 | **Bindings between devices** (powered-by, source → receiver, IR emitter port) | Inspector "Powered by · Not collected by any connected source" (`DeviceInspector.tsx:162`) | `C4:GetBindingsByDevice` (USED `:1716`) with all bindings, not just network; `C4:GetBoundConsumerDevices` (USED `src/lib/bindings.lua:17`); `GetBoundProviderDevice` (EXAMPLE) | M–L | Yes: `control4_device_bindings` table | Connections tab |
| G10 | **Signal quality per device** (Zigbee LQI/RSSI, Wi-Fi) | `browser-core.md` "no … signal … columns exist" | Already collected for sensor-class devices only (`driver.lua:5506`). Zigbee per-node quality: **UNVERIFIED** (no doc'd call; ZAP state is "not exposed", `AGENT_TELEMETRY.md` §1) | L / maybe impossible | Yes | Yes |
| G11 | **Battery for all battery devices** without monitoring enabled | same | stored only when `gMonitor.enabled` (`driver.lua:5957`) | S (decouple a low-rate battery sweep from room monitoring) | none | §2 |
| G12 | **Controller timezone + locale** | "This property has no time zone set" (`browser-tooling-ai.md` §E); Commissioning timezone gate needs an attestation | `C4:GetTimeZone`, `C4:GetLocale` (EXAMPLE; System Link driver shows "America/New_York"); not called by the Agent | S | jsonb only | Commissioning, FR time display |
| G13 | **Backup status** | Overview "Backup status · Not verified · No backup attempt or restore evidence is collected" (`StudioOverview.tsx:115`); Replacement "Control4 project/backup Not verified" | **No documented API** (`backup_ref` exists in `ingest.ts:43` but is never sent). Proxy evidence only: `C4:GetProjectId` (probe `driver.lua:7367`), `last_project_change_at`. **UNVERIFIED** that any backup fact is readable | L / likely not feasible | — | relabel |
| G14 | **Storage / flash usage** | `browser-tooling-ai.md` §E "storage" | `/proc` `statfs`: not available to Lua; `df` via `io.popen` **UNVERIFIED** (sandbox) | L | jsonb | UI |
| G15 | **Last error / failure reason** for uploads | Connections "Last source error · Not reported"; FR "Uploads 314 accepted · 1947 failed", no reason; "bus [object Object]" (UI bug) | Agent-internal (it keeps HTTP errors, `driver.lua:930-960`) | S | jsonb | UI |
| G16 | **Update-check result + installed versions observed** | Drivers "Check unavailable", "Last checked Never", "Update checks · Not declared by this Agent" (`SystemStudioLicensingWorkspace.tsx:106,172`) | Agent-internal (`src/lib/sbos-updater.lua`); POST `/api/driver-cloud/update-observations` (route exists, 107 lines) | M | none (route and table exist) | none |
| G17 | **Third-party driver inventory** (file, version, count by type) | Drivers banner "Installed third-party Control4 drivers are not collected yet…" (`SystemStudioPropertyShell.tsx:310`) | `C4:GetDevices` `driverFileName` (USED) + `C4:GetProjectItems("DEVICES")`; version **UNVERIFIED** (G3) | M | Yes: new table or jsonb | Drivers |
| G18 | **Primary controller identity** (multi-controller projects) | Reports "Primary controller verified · PENDING" (`commissioning.ts:115-121`) | Director device in `C4:GetDevices` + `GetUniqueMAC` is the executing controller only; primary identity is deliberately left null (`docs/system-studio-agent-v1.md` "Deliberate open boundaries") | L / research | — | — |
| G19 | **Effective service profile id / version** | Agent settings and Service profiles "Not reported by agent" | Agent sends `effective_service_profile_id = nil` (`driver.lua:3200-3201`); profile delivery to the Agent is **UNVERIFIED** | M | yes (parse) | — |
| G20 | **Scene activations** | Usage "Most activated scenes · Not collected … (no scene listener)" (`house-activity/route.ts:86`) | Variable listeners on scene / experience devices; observability "unknown" per the Agent's own probe notes (`driver.lua:7830,8141`) | M (+hardware) | none (`control4_telemetry_events` SCENE category) | none |
| G21 | **Media playback state** (playing / paused) | Media "Playback · Not reported by Control4" (`StudioMedia.tsx:31`) | Room variables only give power / source / title (`rooms.lua:27-37`); playback state is a per-source proxy variable, **UNVERIFIED** | M | column on room_state | small |
| G22 | **Camera class / proxy type** | "0 Control4 camera entries" (Overview) vs "Cameras 1" (Devices) (`browser-core.md`) | Server rule `/camera/i` on `device_type` (`monitoring/control4/route.ts:175`) vs Studio `/camera\|nvr\|doorbell/`. Agent could send the proxy class (`GetProxyDevices`, EXAMPLE) | S | small | — |
| G23 | **Device count by type / proxy** | Devices chips "Type not reported" for Zigbee devices (`browser-core.md`) | `ssdptype` is empty for Zigbee bindings; proxy / class name via `GetProxyDevices` or driver file (USED) | S | none (`device_type`) | none |
| G24 | **Reboot history** (list, not a count) | Overview link-only "See diagnostic reports" | Already in `control4_startup_observations` + `director_reloaded` events. **Not an Agent gap** | — | — | UI |
| G25 | **Licence state per SmartBuildOS driver** | Shown already (Driver Cloud) | — | — | — | — |
| G26 | **Third-party licence state** | "Third-party licensing is not exposed" (`DeviceInspector.tsx:172`) | No API (**UNVERIFIED**; spec forbids claiming it without evidence) | — | — | keep wording |
| G27 | **Device "why offline"** | AI Service "the platform records that it went offline, not why" | Binding `status` is the only per-device fact (`driver.lua:1829-1832`). Network-binding / system events 17/18/48/49 counted, not attributed | M | jsonb on device event | small |

---

## 4. Identity gaps — what the Agent must report so Studio joins without names

Today's id spaces (from `code-data-model.md` §0.3), and which of them the Agent controls:

| Id space | Who mints it | Agent sends today | Problem | Agent addition |
|---|---|---|---|---|
| `control4_devices.id` (uuid) | server | — | inspector key; FR / AI / alerts do not use it | none. Server should resolve `c4:<id>` → uuid everywhere (UI fix) |
| `key` = `c4:<Director device id>` | Agent (`driver.lua:1834`) | yes | unique only per **system**; survives renames. Whether the ids survive a project re-import or restore onto a new controller is **UNVERIFIED** | send `project_id` (`C4:GetProjectId`, probed only at `:7367`) plus `boot_id`, so the server can detect a project rebuild and avoid silently re-keying |
| FR / AI `device_id int`, `room_id int` | Director | yes (events) | joins already; Studio's UI drops it | none (UI) |
| Room | Director `roomId` int | **name only** (`:1844`) | name joins break on rename and on duplicate room names across floors | **G4/G5**: `c4_room_id` on every device row + a rooms list with floor / building |
| Controller | Director MAC, Director device id | `director_mac` (`:1112`), `director_device_id` (`:891`) | stored in jsonb only, not a column; replacement / multi-controller identity unresolved (G18) | promote to columns server-side; send the controller's `C4:GetHostname` (USED `:2614`) and serial (**UNVERIFIED** API) |
| System / project | server `system_id`; Composer project name | `composer_project_ref` | the name is not stable (memory: "Miami-Beta" vs host "Beta-Miami") | `project_id` as above |
| MAC (UniFi client, `installed_devices.mac_normalized`) | hardware | SSDP-bound devices only (`:1743-1758,1859`) | most IP devices have no MAC, so inspector "MAC not seen by UniFi" or "No MAC reported" | **G6**: `GetDeviceMAC`; ARP probe; send `mac_source` (ssdp / api / arp) so Studio can weigh it (spec: never IP alone) |
| Zigbee | hardware EUID | dropped (`macFromUuid` rejects 16-hex) | Zigbee devices have no hardware identity | **G6**: `zigbee_eui` |
| Driver Cloud `driver_devices.external_id` | SmartBuildOS drivers (UniFi Protect …) | roster `{id, mac}` (`driver.lua:9604-9611`) | never joined to `control4_devices` | include the `c4:<id>` of the Control4 proxy device that owns each roster entry |
| Alerts | `control4_incidents.probable_cause_key` (c4 key) | — | fine for Control4; UniFi / Driver Cloud alerts use other spaces | MAC (above) makes the UniFi join deterministic |

**Minimum identity set per device row**, all additive:
- already sent: `key`, `device_id`, `mac`;
- new: `c4_room_id`, `zigbee_eui`, `mac_source`, `driver_file` (sent, needs a column), `proxy` / class.

**Per system:** `project_id` and `boot_id` (the boot id is already read for startup observations, `driver.lua:1468`).

With those, joins are mechanical: Studio ↔ FR / AI by `c4:<id>`, Studio ↔ UniFi / installed equipment by MAC or EUID, Rooms by integer id. Name matching is gone.

---

## 5. Freshness and liveness

**What the Agent says about itself**

- Heartbeat every `heartbeat_seconds` (default 60 s; the server can set it; it is stated in the payload, `driver.lua:3140`).
- `agent_health` {lua_memory_kb, heartbeat_lag_ms, driver_uptime_seconds}; `consecutive_failures`; queue depth and drops.
- `event_pipeline`; `update_channel`.
- The driver keeps `Connection Status` / `Last Sync` as Composer properties, not sent.

**How Studio derives state today**

- **Controller:** `livenessOf` returns online if the last heartbeat is within max(15 min, 3 × heartbeat_seconds) (Web `src/lib/control4/systems.ts:44-58`). Bootstrap, portfolio and commissioning use it. AI and the tech report use different windows (`code-data-model.md` §4).
- **Device:** online / offline from the stored `online` flag. "stale" when the system is not live **or** `last_seen_at` is older than 15 min (`workspace-model.ts:232-259`). Because `last_seen_at` moves only on a snapshot (24 h) or a change, stale is the normal resting state. This is a broken rule, not a broken controller.
- Device `online` is Director's binding `status` (`driver.lua:1829-1835`), polled every 5 min. That is real per-device reachability; it is just never re-confirmed to the server.
- ⚠ An unaddressed binding is sent as `online=false` (`driver.lua:1835`), although the comment says the platform should read it as unknown. The server stores false, so Studio may show **offline** for a device with an empty address that is not a `NOT_SET` placeholder (`workspace-model.ts:152-160`). **UNVERIFIED** in data; the "14 total · 7 unavailable" on Connections is consistent with this.

**Server-only interim** (no driver release)
- Treat devices as confirmed at `devices_reported_at` when the heartbeat's `devices_reported` / `_offline` equal the stored `devices_total` / `devices_offline`.
- The Agent computes those from `gDeviceState`, which every 5-min poll refreshes (`driver.lua:3129-3130,2410`). It is approximate: the counts can match while membership differs.

**Agent addition for true per-device reachability** (backlog #1)
- Each poll, put a `device_poll` block on the next heartbeat: `{completed_at, interval_s, devices, offline, digest}`, where `digest` is a hash of sorted `key:online` pairs.
- When the digest matches the server's stored rows, the server stamps them confirmed. When it does not, it replies `request_full_sync` (the verb exists).
- Optionally add `seen_online_at` per device on deltas.

**One controller-liveness rule** Studio can adopt everywhere: online if `now - last_heartbeat_at ≤ max(15 min, 3 × heartbeat_seconds)`. Device observations are current only while the controller is online **and** the last confirmed poll is within `2 × device_poll.interval_s + heartbeat_seconds`. Older Agents (no `device_poll`) fall back to the interim count rule, then to today's 15-min rule.

---

## 6. Commands

**Flow.** Studio POSTs `/api/monitoring/control4/commands`, which writes `control4_commands`.
1. The Agent picks up commands on its next heartbeat or devices response (capability-gated; `heartbeat/route.ts:335-340`).
2. It runs them through `COMMAND_RUNNERS` (`driver.lua:3312-3654`).
3. It POSTs `acks` (`:3661-3690`).
4. Studio polls the command row (`StudioContext.tsx:87-103`).

The latency is up to one heartbeat (60 s by default). The realtime "doorbell" can shorten it (`heartbeat/route.ts:368-373`).

| Studio action today | Verb | Agent support |
|---|---|---|
| Inspector light on / off / level | `SET_LIGHT` | yes (comfort_v1, Remote Control ≥ Comfort) |
| Inspector thermostat setpoints | `SET_THERMOSTAT` | yes |
| Inspector Identify (keypad LEDs) | `IDENTIFY_DEVICE` | yes (identify_v1) |
| Connections "Test connection" | `REQUEST_HEARTBEAT` | yes |
| Drivers "Check for update" | `REQUEST_UPDATE_CHECK` | **no**. Never claimable (capability not declared) |
| FR / VenueFlow / tracer / AI ops | `MODULE_COMMAND`, `DISCOVER_VARIABLES` | yes |
| AI approved actions | `ACTIVATE_SCENE`, `LOCK_DEVICE`, … | yes (homeowner approval for W3) |

**Supported by the Agent, no Studio button:** `REQUEST_FULL_SYNC`, `REQUEST_DIAGNOSTICS`, `RUN_NETWORK_SCAN`, `PROBE_CAPABILITIES`, `REQUEST_CATALOGUE`, `SEND_NOTIFICATION`, `CAMERA_SNAPSHOT`. These are UI-only work.

**Missing technician actions (no verb anywhere)**

- **Reboot controller / restart Director.** Studio already renders a disabled "Reboot" (`DeviceInspector.tsx:103`). The C4 API for this is **UNVERIFIED**, and this is a high-risk write: it needs the Full-control tier plus homeowner approval.
- **Reboot / power-cycle a device.** Only via an OvrC / WattBox outlet (blocked provider) or a device's own proxy command. **UNVERIFIED**, high risk.
- **Enter / exit service mode.** The contract lists `enter-service-mode` / `exit-service-mode` (Web `src/lib/system-studio/commands.ts:1-12`). That vocabulary is **not** the live `COMMAND_ALLOWLIST`, and the Agent has the state (`AgentContract.serviceModeActive`, `driver.lua:3202`). Size S.
- **Read one device's variables now** (live inspector "refresh this device"). `DISCOVER_VARIABLES` returns names only. Needs a `READ_DEVICE_STATE` verb. Size S–M.
- **Refresh rooms / project structure** (G5). Size S, can ride `REQUEST_FULL_SYNC`.
- **Pull a camera snapshot into Studio.** The verb exists; it needs Studio UI and the realtime channel.
- **Record a service note.** It exists as a Composer action (`driver.lua:8490`), not as a command.
- **Generate / send a system report from the controller.** The contract has it (`commands.ts:2-3`). The Agent records the request only (`docs/system-studio-agent-v1.md` "open boundaries").

⚠ **Two command vocabularies coexist.** `SYSTEM_STUDIO_COMMANDS` (kebab-case, `src/lib/system-studio/commands.ts`, imported by `control4-agent-contract.ts:110`) is a paper contract. The wire allowlist is `COMMAND_ALLOWLIST` (SCREAMING_CASE, `src/lib/control4/commands.ts:20`, mirrored by a DB CHECK constraint). A new verb must go into the second **plus a migration**.

---

## 7. Constraints for the plan

### 7.1 Versions, tags and releases

- **Build stamp.** `make update-xml-version` stamps `YYYYMMDD.HHMMSS` UTC (Drv `Makefile:184-191`). CI builds restamp, so a CI `.c4z` differs from a local build (`docs/ai-core/RELEASE.md` §1).
- ⚠ **Conflict.** `src/lib/driver-version.lua:1-14` (origin/main) calls `YYYYMMDD.N` the current scheme and `.HHMMSS` "legacy". The comparator accepts both: 1–3-digit suffix = build number, 4 or 6 digits = legacy. Which scheme is canonical for the next release is **UNVERIFIED**. The primary checkout has an uncommitted "release-version scheme changes" WIP (`8615724`/`3984d49` on the local wip branch). Owner memory says "we MINT YYYYMMDD.HHMMSS; `vYYYYMMDD.N` is invisible to the fleet".
- **Tags.** `release.yml` runs only on `v*` tags. The November releases used bare tags (`20261116.035552`) created by hand with `gh release create`.
- **What updaters compare.** The GitHub updater compares the **tag**, so a tag must parse and should equal the in-`.c4z` stamp. The SmartBuildOS updater compares each package's inner `<version>` and never downgrades (`RELEASE.md` §2, "The two updaters").
- **Updater module style.** `lib.github-updater` uses colon calls; `lib.sbos-updater` uses dot calls (`RELEASE.md` §2 table; owner memory trap).
- **Store publication.** `publish-to-store.yml` fires on a published release and maps files with `sku_for()`. The Agent's own filename is in `DRIVER_FILENAMES` (`driver.lua:4-52`).
- **Package allowlist.** Update filenames are an explicit allowlist (`docs/system-studio-agent-v1.md` "Preserved compatibility").
- **Release cadence.** Recommended: one build = one version = one release, first as a pre-release (store BETA), then promote (`RELEASE.md` §3).

### 7.2 Compatibility rules written in the code

- **Absence is not a claim.** The server merges only the keys present (`heartbeat/route.ts:71-103,142-163`; `agent-telemetry.ts:13-26`).
  - New heartbeat fields must be optional, and older Agents must degrade to today's behaviour.
  - Uptime and `controller_vitals` are the only "drop when absent" exceptions.
- **No per-field migrations racing deploys.** New Agent telemetry goes under `technical_metadata.agent` jsonb so a deploy cannot 503 heartbeats (`agent-telemetry.ts:6-11`).
  - A new **column** (e.g. `driver_file`, `c4_room_id`) needs migration first, then deploy, then driver release.
  - Repo comment: "a field that nothing can store is a feature that only looks supported. Add them with the migration, not before it." (`ingest.ts:571-574`)
- **Capability negotiation.** Every new command verb needs a capability string the Agent declares (`driverCapabilities`, `driver.lua:2460`), plus a `COMMAND_REQUIRES` entry and the DB CHECK on `control4_commands` (`commands.ts:16-18,85-110`). An undeclared verb stays queued until it expires (it is never failed).
- **Write tiers.** The Composer `Remote Control` property gates write verbs on the controller: Off / Identify only / Comfort / Full control (`driver.lua:2425-2491`). W3 verbs need homeowner approval (`commands.ts:62-74`).
- **Snapshots.** An empty snapshot retires nothing (`ingest.ts:410-425`). The `source` column is NOT NULL on tombstones (`:431-440`).
- **Device payload ceilings.** 2,000 devices per payload; text fields 200 chars (room 80, firmware 60, `device_type` 120, MAC 32 before normalisation) (`ingest.ts:28,47,196-235`).
- **Rate limit.** `control4Ingest` is 60 requests per minute per IP per route (`src/lib/server/rate-limit.ts:86`). A per-poll extra POST is affordable; the heartbeat-block approach costs nothing.
- **Other ceilings.**
  - FR envelope: 100 events per batch, 4 KB payload, 32 KB frame, depth 4, 40 keys (`envelope.ts:15-27`).
  - Command payload ≤ 16 KB and lifetime ≤ 10 min for the contract envelope (`system-studio/commands.ts:36-39`).
  - Push: title 120, body 500, 60 per system per hour on the server, 30 on the driver (`agent-push.ts:30-38`).
  - Vercel function body cap 4.5 MB (owner memory). Album art rides `media_image_data`, so keep state payloads small.
- **Minimum OS.** 3.3.1; the Agent disables itself below it (Drv `README.md:12,607-608`).
- **Lua constraint.** The main chunk is at Lua's 200-local ceiling ("Global on purpose", `driver.lua:107`). New helpers must be globals or modules under `src/sbos/`, following `AgentTelemetry` / `AgentPush`.
- **Evidence classes.** The repo ranks MEASURED > VERIFIED_BY_EXAMPLE > VERIFIED_BY_DOCS > PROBE (`docs/AGENT_TELEMETRY.md` header). A PROBE is reported, never depended on. Studio must label PROBE-sourced facts (e.g. vitals `readable[]`).

### 7.3 Privacy and redaction

- **Text redaction.** `redactTelemetryText` / `redactTelemetryValue` (Web `src/lib/system-studio/telemetry-redaction.ts:1-32`) blank any key matching `password|passphrase|api key|token|secret|credential|authorization|cookie|session id|pairing code|activation code|private key`. They also redact `Bearer` / `Basic` values, JWTs and PEM blocks inside text.
  - New free-text fields (last error, device names, variable samples) must pass through it before display or export.
  - New field **names** must not match the sensitive-key regex, or they will be blanked (e.g. do not call a field `token_state`).
- **Household data.** Room, media and keypad telemetry is household data. It starts only when the dealer enables monitoring (default false, `heartbeat/route.ts:294-296`). Keypad presses are tagged `privacy_class = "INTEGRATOR_ONLY"` (`driver.lua:5213`). Any new per-room activity (scenes, playback) must sit behind the same switch.
- **Command paths.** Commands never return household history. Camera snapshots are relayed, never stored (`commands.ts:51`).
- **Push.** The controller chooses the words, never the recipients (`agent-push.ts:11-17`).

### 7.4 Field fleet

Agents in the field update themselves every 30 min (`Automatic Updates` On by default; README `:521`). They never downgrade. A rollback needs a manual Composer install (`RELEASE.md` §3 step 3). Plan every server change to accept a missing block **forever**.

### 7.5 Driver Cloud

- Entitlements are checked hourly; enforcement is still off (`docs/KNOWN_LIMITATIONS.md` "Licensing").
- Rotating the master HMAC key forces fleet-wide re-pairing.

### 7.6 Hardware validation debt

The README "What is not claimed" (`README.md:613-630`) lists features never seen on a controller: Director notices, the reload path, and push. Any backlog item that depends on system events (firmware changed, Zigbee) inherits that debt.

### 7.7 Worktree status (for not re-doing work)

| Worktree | Branch @ HEAD | What it added | Merged? |
|---|---|---|---|
| agent-push | feat/agent-push @ e31dbe0 | `SEND_PUSH_NOTIFICATION`, `src/sbos/agentpush.lua` | yes (ancestor of origin/main) |
| agent-telemetry | feat/agent-telemetry @ f1e1647 | vitals, clock offset, programming census, Zigbee counters, system events (`src/sbos/agenttelemetry.lua`) | yes in content (767 of 769 added lines present) |
| agent-vnext | codex/system-studio-agent-vnext @ eaa0468 | Agent contract v1, startup observations; **9 uncommitted files** (`agent_contract.lua` etc.) | HEAD merged; the uncommitted files' content is present on origin/main as `src/sbos/agent_contract.lua`. Equality is **UNVERIFIED** |
| agent-pairing | feat/agent-property-code-pairing @ 0a7ae29 | property-code pairing | yes |
| agent-as-agent | feat/agent-as-agent @ 9562aa1 | Composer Agents-panel conversion | yes |
| agent-no-touchpanel | feat/agent-remove-touchpanel @ afe5e8a | removes the touchpanel display (−147 lines) | yes (no "touch" left in origin/main `driver.xml`) |
| flight-recorder | feat/flight-recorder @ 87ed740 | FR driver; 1 dirty `driver.xml` | yes |
| event-tracer | detached @ 7db22e7 (#48) | tracer, folded into FR | yes |
| dealer-tools | feat/dealer-tools @ 7b4506d | dealer tools / Daypart; 1 untracked html | yes |
| daily-reboots | detached @ a05d8b6 (#42) | reboot tracking | yes |
| system-link | feat/system-link @ 1da674b | System Link; **11 uncommitted files** (new `configuration.lua`, `templates.lua`) | HEAD yes; uncommitted work not on main (not agent) |

---

## 8. Ranked backlog — top 15 Agent additions

Ordering: Studio impact per unit of effort, then risk. "Old Agents" says what Studio shows when a controller has not updated.

| # | Addition | Why Studio needs it (what it unblocks) | Size | Depends on | Old Agents |
|---|---|---|---|---|---|
| 1 | **`device_poll` block on heartbeat** {completed_at, interval_s, devices, offline, digest}. The server confirms rows or asks for a full sync | Fixes "every device stale"; makes Online / Offline counts, Needs-attention and inspector controls true; gives one liveness rule (§5) | S driver + S server | none (jsonb) | fall back to the count heuristic, then today's 15-min rule |
| 2 | **Implement `update_check_v1`**: a `REQUEST_UPDATE_CHECK` runner + POST `/api/driver-cloud/update-observations` after every scheduled or requested check (installed version per file, available, outcome) | Drivers & Licenses: Available / Update / Last checked / Check now. Today every row reads "Check unavailable" | M | the route already exists; check its contract | capability absent, so "Not declared by this Agent" (as today) |
| 3 | **Room identity**: `c4_room_id` on every device row + a rooms list (id, name, floor / building) from `GetProjectItems("LOCATIONS")` on full sync | Rooms keyed by id (empty rooms kept, renames safe); FR → Room link; AI room ids resolve | S | migration (`c4_room_id`, rooms store) | rooms by name (as today) |
| 4 | **Driver file + version per device**, and a **third-party driver census** (file → count, version when readable) | Inspector "Driver file / version"; Drivers banner "third-party drivers not collected" | S (file) / M (version) | migration (`driver_file`, `driver_version`); version API **UNVERIFIED** | file: server-only once the column exists (already sent); version "Not reported" |
| 5 | **MAC coverage**: `C4:GetDeviceMAC`, Zigbee `zigbee_eui` from the binding uuid, optional `/proc/net/arp` probe; send `mac_source` | Deterministic Control4 ↔ UniFi ↔ installed-equipment joins; inspector network association; dedupe (spec principle 3) | S–M | migration (`zigbee_eui`, `mac_source`); hardware measurement of GetDeviceMAC | SSDP MACs only (as today) |
| 6 | **Firmware + operating state per device** from device variables (power / standby, firmware), refreshed on full sync and on `OnDeviceFirmwareChanged` | Devices Firmware and Operating-state columns; inspector Summary / Driver tabs | M | variable-name survey on hardware (use the existing `survey` / `probe` events) | "Not reported" (as today) |
| 7 | **Report devices without a network binding** as `connection_type:null, online:null` (and stop sending `online=false` for unaddressed bindings) | Honest "Not monitored" bucket; removes possible false "offline"; counts reconcile with Composer | S | server: `online` must accept null (`ingest.ts:211` defaults absent to true, so the driver must send explicit null and the normaliser must keep it) | unchanged |
| 8 | **Controller identity and locale facts**: `GetTimeZone`, `GetLocale`, `GetHostname`, `GetProjectId`, `boot_id`, serial (if an API exists), sent in `technical_metadata` | Commissioning timezone gate; FR / AI times in property time; project-rebuild detection; Replacement preflight | S | none (jsonb) | property timezone (as today) |
| 9 | **`last_error` / failure reasons** for device sync, telemetry, events upload (last HTTP status + redacted body), plus a structured network-scan result | Connections "Last source error"; FR "1947 failed" with a reason; Network page for non-UniFi sites | S | none (jsonb) | "Not reported" |
| 10 | **Service-mode commands** `ENTER_SERVICE_MODE` / `EXIT_SERVICE_MODE` (capability `service_mode_v1`) + `effective_service_profile_*` filled | Overview "Service mode" becomes an action and a state; alerts suppressed during work; Service profiles "Agent applied" | S–M | allowlist + CHECK migration; server parses `agent_contract` (§2) | button hidden (capability) |
| 11 | **Battery / link-quality sweep independent of room monitoring** (low-rate, e.g. 6 h; no household activity) | Battery and signal columns and "low battery" attention on every property, not only monitored ones | S | none (`control4_device_sensors`) | only when monitoring is on (as today) |
| 12 | **Device relationships**: non-network bindings per device (provider / consumer device, binding class), sent on full sync | Inspector "Powered by / Connected to"; source → display chains in Media | M–L | new table | "Not collected" |
| 13 | **`READ_DEVICE_STATE` command** (one device's variables now, bounded) | Inspector "Refresh this device" for a technician on the phone, without waiting for the poll | S–M | allowlist + CHECK migration | button hidden |
| 14 | **Scene activations + media playback state** (behind the monitoring switch) | Usage "Most activated scenes"; Media "Playback" | M (+hardware) | none (telemetry category / room-state column) | "Not collected" (as today) |
| 15 | **Controller reboot / Director restart command** (Full-control tier + homeowner approval; verify before and after; idempotency key) | The disabled "Reboot" button in the inspector (`DeviceInspector.tsx:103`) | L + research (API **UNVERIFIED**; high risk) | approval flow (exists for W3), allowlist migration | button hidden |

**Not ranked (deliberately)**

- **Backup status** (G13): no known API. Relabel the Overview row rather than promise it.
- **Primary-controller identity** (G18): research first.
- **Zigbee per-node signal** (G10): no documented call.

**Do first, before any driver release: the server and UI items in §2.** They cost no field update and remove most "Not reported" text:
- read `agent_contract` and `agent_config_applied`;
- show controller vitals, uptime and project name;
- show sensors (battery, link quality);
- store `driver_file`;
- surface monitoring-off;
- add Studio buttons for full sync, diagnostics, scan, test notification and snapshot;
- add the interim liveness rule.

---

## Could not determine

- Whether `C4:GetDeviceMAC`, `C4:GetDeviceData(id,"version")`, `C4:GetTimeZone`, `C4:GetProjectId`, per-device firmware variables and any reboot API work on our controllers. They are not called (or only probed) by the released Agent.
- Whether `/proc` reads (vitals, ARP) succeed on real hardware; the field `readable[]` will say.
- The canonical version scheme for the next release (`YYYYMMDD.N` per `driver-version.lua` vs `YYYYMMDD.HHMMSS` per the `Makefile` and `RELEASE.md`).
- Whether Control4 device ids (`c4:<id>`) survive a project re-import or controller replacement.
- How service profiles reach the Agent, if they do at all.
- What the Driver Cloud `state` / `state/provision` / `system-link/provision` routes store.
- Runtime behaviour: nothing was run. The "stale" diagnosis is from code and matches the browser reports' observation ("Stale · 7 h ago" with a check-in "1 min ago").
