# SmartBuildOS Agent — shared module services, protocol v1

Status: implemented on driver branch `feat/flight-recorder` and web branch
`codex/flight-recorder`; simulator-verified; bench validation owed
(`VERIFICATION.md`). Versioned: `PROTOCOL_MIN = PROTOCOL_MAX = 1` on both
sides (`src/sbos/modules.lua`, `src/sbos/moduleclient.lua`).

## 1. Parties and trust

| Party | Identity | Credential |
| --- | --- | --- |
| Platform (web) | company / system / property | the Agent's pairing token (`sbc4_…`), resolved by `authenticateController`; tenant is NEVER read from a body |
| Agent (`smartbuildos.c4z`) | Director device id + `C4:GetBootID()` | the pairing token (unchanged) |
| Module (e.g. `smartbuildos-flight-recorder.c4z`) | `module_id` + `instance_id` (its Director device id) | a per-registration **token** the Agent sends TO the claimed device id |

`ExecuteCommand` carries no sender identity, so the token is the only proof a
frame came from the registered instance. A module that does not hold the
token cannot speak for another instance; the Agent ignores (does not even
acknowledge) unauthenticated frames. Local registration is not authorization:
the platform decides ownership from the Agent's credential and the Agent
forwards only the restricted operations the platform queued (§6).

## 2. Transport between drivers

`C4:SendToDevice(id, COMMAND, params)` → receiver's `EC.COMMAND(tParams)`.
Every param is a STRING on-controller; structured data is JSON in one param.
Frame limit 32 KB (`Envelope.LIMITS.frame_bytes`); event batches ≤ 100.

### Module → Agent

| Command | Params | Agent answer |
| --- | --- | --- |
| `SBOS_MODULE_REGISTER` | `module_id`, `instance_id`, `requester`, `driver_version`, `protocol_min`, `protocol_max`, `capabilities` (csv), `entitlements` (csv SKUs), `commands` (csv), `event_types` (csv prefixes), `config_version`, `singleton` ("true"), `status` | `SBOS_MODULE_REGISTERED` to the claimed id: `ok`, `token`, `protocol`, `reason` (`invalid_module_id`, `invalid_instance_id`, `incompatible_protocol` + `agent_protocol_min/max`, `duplicate_instance` + `other_instance_id`, `registry_full`), plus agent state (`paired`, `connected`, `installation_id`, `boot_id`, `agent_version`); then `SBOS_DRIVER_CONFIG` with the last forwarded settings for each entitlement SKU |
| `SBOS_MODULE_STATUS` | auth (`module_id`, `instance_id`, `token`), `status`, `detail`, `config_version`, `applied_config_version`, `config_error`, `counters` (JSON) | none; liveness for the registry (stale after 15 min) |
| `SBOS_MODULE_EVENTS` | auth, `batch_id`, `events` (JSON array of envelopes, ≤ 100) | `SBOS_MODULE_EVENTS_ACK`: `batch_id`, `accepted`, `rejected` (−1 = whole frame), `duplicates`, `reason`, `queue` (JSON brief) |
| `SBOS_MODULE_COMMAND_RESULT` | auth, `request_id`, `state` (Accepted/Executing/Completed/Failed/Expired/Unverified), `detail` | none; state recorded + `agent.command_state` event |
| `SBOS_MODULE_SNAPSHOT` | auth, `job_id`, `request_id`, `status`, `document` (JSON ≤ 256 KB) | `SBOS_MODULE_SNAPSHOT_ACK`: `job_id`, `ok`, `reason`, `snapshot_id` |
| `SBOS_MODULE_UNREGISTER` | auth | none |
| `SBOS_DRIVER_CONFIG_ACK` (existing) | `sku`, `applied`, `refused`, `settings_version`, `requester` | audited to Driver Cloud (unchanged) |

### Agent → Module

| Command | Params | When |
| --- | --- | --- |
| `SBOS_MODULE_REGISTERED` | above | answer to a registration |
| `SBOS_MODULE_AGENT_HELLO` | `agent_version` | the Agent's own LateInit: every known instance re-registers (new token) |
| `SBOS_MODULE_AGENT_STATE` | `paired`, `connected`, `installation_id`, `boot_id`, `agent_version`, `protocol` | pairing / connection transitions |
| `SBOS_MODULE_AGENT_EVENT` | `name`, `detail` (JSON) | Agent-classified events: `director_reloaded`, `unexpected_restart`, `os_update_started`, `project_changed`, `programming_changed`, `clock_drift`, `device_offline`, `device_online`, `cloud_connected`, `cloud_disconnected` |
| `SBOS_DRIVER_CONFIG` (existing) | `sku`, `settings` (JSON), `settings_version`, `requester` | heartbeat `driver_config` block (change-gated) and on registration (resend) |
| `SBOS_MODULE_COMMAND` | `module_id`, `instance_id`, `token`, `request_id`, `command`, `args` (JSON), `expires_at` (epoch s), `issued_at` | a platform `MODULE_COMMAND` the Agent validated |
| `SBOS_MODULE_EVENTS_ACK`, `SBOS_MODULE_SNAPSHOT_ACK` | above | answers |

Lifecycle rules: a module registers on every LateInit (`DIT_ADDING`,
`DIT_STARTUP`, `DIT_UPDATING`) and retries 30 s → 5 min while it has no Agent
or no answer; a definitive refusal (`incompatible_protocol`,
`duplicate_instance`) slows the retry to 5 min. Re-registration of the same
instance replaces the token and keeps the row (registrations count). A
singleton module refuses a second live instance until the first is stale.
`OnDriverDestroyed` sends `SBOS_MODULE_UNREGISTER` after flushing staged events.

## 3. Event envelope v1 (`src/sbos/envelope.lua` ↔ `src/lib/control4/flight-recorder/envelope.ts`)

```
event_id            "<module_id>:<instance_id>:<boot_id|nb>:<sequence>"  (≤128)
schema_version      1
event_type          "<prefix>.<name>" — the module must own the prefix (§3.1)
module_id           ^[a-z][a-z0-9_]{2,47}$
source_driver_instance_id   the module's Director device id (string)
installation_id     stamped by the AGENT (system id); a module's value is overwritten
device_id, room_id  integers when applicable
observed_at         controller wall clock, ISO-8601 UTC
boot_id             stamped by the Agent when absent (C4:GetBootID, may be absent on some OS)
sequence            module-persisted monotonic integer (stride 25: a reload may skip, never repeat)
correlation_id      ≤96 chars, when explicitly supplied (trace id, request id)
severity            debug|info|notice|warning|error|critical
evidence_source     observed|initial|requested|instrumented|derived|system
quality             confirmed|unreviewed_text|partial|unknown
label               ≤120
payload             object, ≤4 KB approx, depth ≤4, ≤40 keys, strings ≤512; redacted both sides
```

Server adds `received_at` and `clock_suspect` (observed_at > 5 min ahead or
> 30 days behind). Ordering: within one module instance, `(boot_id,
sequence)` is authoritative; across instances and modules, `received_at`.
Nothing claims a global order.

### 3.1 Prefix ownership (reserved extension contracts)

| module_id | prefixes | status |
| --- | --- | --- |
| `flight_recorder` | `observation.`, `trace.`, `recorder.`, `snapshot.` | implemented |
| `agent` | `agent.` (`agent.command_state`) | implemented |
| `guardian` | `health.` | reserved, not implemented |
| `commissioning_inspector` | `test.` | reserved |
| `home_state` | `mode.` | reserved |
| `property_bridge` | `bridge.` | reserved |

## 4. Queue, acknowledgment, loss (`src/sbos/eventqueue.lua`)

| Rule | Value |
| --- | --- |
| Module stage | ≤ 300 envelopes in memory; frames of ≤ 100; a frame unacked for 30 s is resent, after 3 tries dropped and counted (`events_dropped_local`) |
| Agent queue bounds | 2,000 events / 512 KB (approx JSON) / 100 per upload; platform budget may LOWER (floors 50 / 16 KB / 5) |
| Upload | one batch in flight; `POST /api/integrations/control4/events` `{kind:"events", events, pipeline}`; the Agent's existing `send()` (token, Date-header clock note, failure reporting) |
| Ack | `{accepted:[event_id], rejected:[{event_id, reason, permanent}], received_at}`. Removed from the queue ONLY when listed under accepted. Permanent rejections dropped and recorded as a range with `rejected:<reason>`. Unmentioned → retried. 2xx without a verdict → nack. |
| Nack | transport failure, 503, or 90 s silence: batch returns to the front; backoff 30 s × 2ⁿ, cap 15 min, ±25 % jitter; `resume(30)` staggers recovery after a reconnect |
| Eviction | lowest priority first (0 initial reads, 1 observations, 2 traces/commands/snapshots/recorder status), oldest within a class; every eviction counted and recorded as a contiguous `(module, instance, boot, from_seq..to_seq, reason)` range (≤ 64 ranges, then `ranges_truncated`) |
| Journal | one persist key `sbos_event_journal_v1`, checkpoint every 50 pushes or 30 s and on destroy; in-flight events included (resent, deduped by the server). Loss window on a hard power cut: ≤ 50 events / 30 s. Unreadable journal → empty queue + `journal_recovered`; partly unreadable → valid events kept, rest counted |
| Dedup | Agent: ring of 2,048 event ids (a module resend after a lost local ack is accepted, not queued twice). Server: unique `(system_id, event_id)` |
| Heartbeat | `event_pipeline` = `Queue:health()` (depth, bytes, oldest age, inflight, pushed, acked, dropped, ranges, rejected_permanent, upload_failures, consecutive_failures, backoff, last_ack_at, last_error, journal_recovered, limits, limit_status) |

No promise of unlimited or lossless recording is made anywhere; gaps are
surfaced in Studio with their sequence ranges.

## 5. Configuration delivery

Desired configuration lives in `driver_config` (SKU `SBOS_FLIGHT_RECORDER`);
`settings_version` is DB-assigned. The heartbeat's `driver_config` block →
`forwardDriverConfigs` → `SBOS_DRIVER_CONFIG` to every installed instance
(change-gated per SKU); on registration the Agent re-sends the last forwarded
document. The module validates the WHOLE document (`flightrecorder/config.lua`),
applies or keeps its last valid one, answers `SBOS_DRIVER_CONFIG_ACK`
(applied/refused, audited), and reports `applied_config_version` /
`config_error` / `config_source` on its status frame → heartbeat `modules`
block → `control4_agent_modules`.

Ownership and conflicts: **System Studio owns the document.** A Composer
template revision applies locally at version `applied+1` with
`config_source=composer` and is reported; the next Studio save (DB version
N+1 ≥ it) replaces it. Studio refuses a save whose `expected_version` is not
the stored one (409) so two technicians cannot overwrite each other blind.

## 6. Restricted commands (no second gateway)

Platform verb `MODULE_COMMAND` (allowlist + DB CHECK, capability `modules_v1`,
`monitoring:manage`) with payload `{module_id, command, request_id (server-
minted UUID), args (≤ 16 KB), expires_at (now + 10 min), instance_id?}`.
Agent runner `ModuleCommandDispatch`: vocabulary `MODULE_COMMANDS` =
`flight_recorder: apply_config | pause | resume | capture_snapshot |
refresh_status`; duplicate `request_id` refused (ring of 256); expired
refused (state Expired); target = a live registered instance that lists the
command; forwarded with the instance's token. States: Accepted (the platform
ack) → Executing → Completed / Failed, or Expired / Unverified (no terminal
result before expiry + 5 s). Every transition is an `agent.command_state`
event (correlation_id = request_id). No arbitrary Lua, no equipment control.

`DISCOVER_VARIABLES` `{device_ids: 1..25}` → `telemetry` kind `catalogue`
with `partial: true` (the server merges, never prunes).

## 7. Snapshots

Module → Agent `SBOS_MODULE_SNAPSHOT` (≤ 256 KB) → Agent re-redacts → `POST
/api/integrations/control4/snapshots` → bucket `flight-recorder-snapshots`
at `<company>/<system>/<job>.json` + row `flight_recorder_snapshots` →
`SBOS_MODULE_SNAPSHOT_ACK`. Idempotent on `(system, job_id)`. Studio signs a
5-minute URL on `monitoring:export`, audited.

## 8. Extension points (documented, not implemented)

- **Health observations (Guardian):** `module_id = guardian`, prefix
  `health.`, same registration and queue; `capabilities` may list
  `health_v1`. The Agent reserves `MODULE_COMMANDS.guardian = {}` (nothing
  allowed until defined).
- **Test results (Commissioning Inspector):** prefix `test.`; snapshot path
  reusable for reports (`SBOS_MODULE_SNAPSHOT` with `status`).
- **Mode states (Home State):** prefix `mode.`; `SBOS_MODULE_AGENT_EVENT`
  can carry a `mode_changed` name once defined.
- **Cross-property messages (Property Bridge):** prefix `bridge.`; the
  System Link relay stays the transport; the Agent's registry is the local
  directory.
- **Overflow tier:** the file sandbox (`C4:GetSandboxDir` + `File*`) for a
  larger journal, behind the same `saveJournal` injection.
- Heartbeat `modules[].counters` is an open object per module for future
  health fields; `capabilities` strings are free-form per module.
