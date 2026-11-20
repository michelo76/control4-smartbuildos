# SmartBuildOS Agent ⇄ platform — wire contract for Studio release G1

Owner-approved scope (2026-11-20): six additions, one agent release, shipped
after the server side is deployed. This file is the single contract both the
driver worker and the server worker implement. If the code makes any part of
it impossible, STOP and report the exact conflict — do not diverge silently;
the other side is being built against this text at the same time.

Evidence and constraints: `evidence-agent-gaps.md` §1–§7 (same folder).

## Rules that bind every item
- Every new field is OPTIONAL. Absence is never a claim. A platform that
  receives an old agent, and an agent that talks to an old platform, both keep
  today's behaviour forever.
- New telemetry is stored as jsonb under `technical_metadata.agent.<block>`
  unless a column is named below. A new column ships migration → deploy →
  driver release, in that order. Migrations are WRITTEN, never applied by a
  worker.
- Field names must not match the redaction regex
  (`password|passphrase|api key|token|secret|credential|authorization|cookie|session id|pairing code|activation code|private key`).
- Free text is truncated (200 chars unless stated) and passes
  `redactTelemetryText` on the server before storage.
- Household activity stays behind the monitoring switch. Nothing below is
  household activity.
- Driver: the main Lua chunk is at the 200-local limit — new code goes in
  modules under `src/sbos/` (pattern: `agenttelemetry.lua`, `agentpush.lua`)
  or globals. Minimum OS 3.3.1. Any Control4 API call that the released agent
  does not already use is a PROBE: wrap it in `pcall`, send the field only when
  the call answered, and list it in the block's `probed` array.
- The agent declares each item it implements as a capability string in
  `driverCapabilities`; the platform relies on the block being present, not on
  the capability, but the capability is shown in Studio.

## 1. `device_poll` — per-device freshness (capability `device_poll_v1`)
Heartbeat, top-level key `device_poll`, sent on the first heartbeat after each
completed device poll (the existing 5-minute poll):

```json
{ "completed_at": "2026-11-20T15:04:05Z", "interval_s": 300,
  "devices": 42, "offline": 3, "unknown": 5,
  "digest": "<64 lowercase hex chars>" }
```

`digest` = SHA-256 (hex, lowercase) of the UTF-8 string built from one line per
device the agent reports in its devices payload: `<key>:<state>` where `<key>`
is exactly the `key` field of that device row (e.g. `c4:123`) and `<state>` is
`1` online, `0` offline, `u` unknown/null; lines sorted ascending by `<key>` as
byte strings; joined with `\n`; no trailing newline. Zero devices → digest of
the empty string.

Platform: computes the same digest from its stored, non-retired device rows for
that system. Match → writes `technical_metadata.agent.device_poll` =
the block plus `confirmed_at` (= `completed_at`) and `matched: true`. Mismatch
→ stores the block with `matched: false` and queues the existing full-sync
command for that system, at most once per 15 minutes. Studio treats a device
observation as current when the controller is live AND
`now - max(device.last_seen_at, device_poll.confirmed_at) ≤ 2 × interval_s + heartbeat_seconds`.
No per-device row writes on a match.

## 2. Honest `online` (capability `device_online_null_v1`)
Devices payload rows: `online` may be `true`, `false` or JSON `null`.
- A device with a network binding whose address is empty/unset → `online: null`
  (today `false`).
- A project device with no network binding at all (IR, serial, relay, contact)
  is now included with `connection_type: null`, `online: null`.
Platform: the normaliser keeps explicit `null` (today an absent value defaults
to `true` — absent keeps defaulting to `true` for old agents); `null` is stored
as SQL NULL and Studio shows "Unknown / not monitored". The 2,000-row payload
ceiling stays; if the project exceeds it the agent sends network-bound devices
first and sets top-level `devices_truncated: true`.

## 3. Room identity (capability `room_identity_v1`)
- Each devices-payload row gains `room_id` (integer Control4 room id) beside
  the existing room name.
- Full-sync devices payload gains top-level
  `rooms: [{ "id": 12, "name": "Kitchen", "parent_id": 4, "floor": "Main", "building": "House" }]`
  — every room in the project including empty ones; `parent_id`, `floor`,
  `building` only when the project has them. Max 500 rooms, names ≤ 80 chars.
Platform: new nullable column `control4_devices.c4_room_id integer`; rooms list
stored whole as `technical_metadata.agent.rooms` = `{ reported_at, rooms: [...] }`
(replaced on each full sync; an empty or absent list retires nothing). Studio
room ids stay `c4-room-<id>`.

## 4. Driver census (capability `driver_census_v1`)
Full-sync devices payload, top-level
`drivers: [{ "file": "thermostat_xyz.c4z", "name": "XYZ Thermostat", "version": "112", "count": 3, "sbos": false }]`
— one entry per distinct driver file in the project; `version` only when
readable (PROBE); `sbos: true` for SmartBuildOS drivers; max 500 entries,
strings ≤ 120 chars. Platform: `technical_metadata.agent.driver_census` =
`{ reported_at, drivers: [...] }`. Separately the platform starts storing the
per-device `driver_file` the agent ALREADY sends: new nullable column
`control4_devices.driver_file text`.

## 5. Controller identity and locale (capability `controller_identity_v1`)
Heartbeat, top-level key `controller`, sent on the first heartbeat after start
and whenever a value changes:

```json
{ "timezone": "America/New_York", "locale": "en-US", "hostname": "core5-…",
  "project_id": "…", "boot_id": "…", "probed": ["timezone", "hostname"] }
```
Every field optional. `boot_id` is a value that changes on each controller
boot (e.g. derived from boot time) — never a serial number. Platform:
`technical_metadata.agent.controller`.

## 6. Failure reasons (capability `last_errors_v1`)
Heartbeat, top-level key `last_errors`:

```json
{ "devices":   { "at": "…Z", "status": 413, "message": "…" },
  "telemetry": { "at": "…Z", "status": 0,   "message": "timeout" },
  "events":    { "at": "…Z", "status": 500, "message": "…" } }
```
One entry per upload channel that has failed since start; an entry is removed
after that channel's next success. `status` is the HTTP status or 0 for a
transport failure; `message` ≤ 200 chars, with any header or credential value
already stripped by the agent. Platform: redacts again and stores
`technical_metadata.agent.last_errors`.

## Not in this release
`update_check_v1`, MAC coverage, firmware/operating state, service-mode
commands, battery sweep (G2); relationships, read-device-now, scenes/playback,
reboot (G3).

## Release mechanics (driver)
Versions are minted `YYYYMMDD.HHMMSS` UTC by `make update-xml-version`. The
release tag must be that exact stamp (bare, no `v` suffix games — a tag the
updater cannot parse is invisible to the fleet). One build = one version = one
release, published as a pre-release (store BETA) first. Field agents
auto-update within ~30 minutes and never downgrade. NO worker tags, releases,
publishes or pushes; the conductor brings the finished build to the owner.
