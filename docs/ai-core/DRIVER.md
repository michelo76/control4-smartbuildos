# SmartBuildOS AI Core — driver reference

Status: built on branch `feat/ai-core`. **No physical controller has run this
driver.** Everything below is verified by unit tests under the C4 shim and by
a Director-emulator scenario (simulation); see [Verification](#13-verification)
and [Not verified on hardware](#14-not-verified-on-hardware).

This file is the authoritative reference: later documentation is generated
from it, so the names here are exact.

| Item | Value |
| --- | --- |
| Driver directory / file | `drivers/smartbuildos-ai-core` / `smartbuildos-ai-core.c4z` |
| Display name | SmartBuildOS AI Core |
| `module_id` | `ai_core` (singleton per controller) |
| Manifest driver | `sbos.ai_core` (serves no capability to other modules) |
| Protocol | module contract v2 required (`require_protocol = 2`); negotiates 1..2 |
| SKU | `SBOS_AI_CORE` |
| Feature entitlements | `BASE`, `AI_LEARNING`, `AI_ACTIONS`, `AI_CONCIERGE` |
| Event-type prefix | `ai_core.` |
| Minimum OS | 3.3.2 (`<minimum_os_version>`) |
| Variable ids | 4000–4009 |
| Pure logic | `src/aicore/{vocab,commands,config,operations,buffer,collector,state,diagnostic}.lua` |
| Driver wiring | `drivers/smartbuildos-ai-core/driver.lua` |
| Dealer manual | `drivers/smartbuildos-ai-core/www/documentation/index.md` |

What it is: the controller-side half of AI Core. The AI runs in the
SmartBuildOS cloud. The controller holds **no AI, no history beyond a small
buffer, and no API key** (ARCHITECTURE §1.5, D2). The driver turns Composer
programming into validated cloud requests, shows results and platform events
to programming, collects a minimal set of events, and reports its health.

## 1. Composer properties

All read-only except **Log Level** and **Log Mode**.

| Property | Shows | Source |
| --- | --- | --- |
| `Driver Status` | `Online` once started | driver |
| `Driver Version` | the built `<version>` | driver |
| `SmartBuildOS Connection Status` | one of the state texts in §6 | state machine |
| `Agent Pairing Status` | `Paired`, `Not paired`, `No SmartBuildOS Agent`, `Agent update required`, `Unknown (not registered with the Agent yet)` | Agent registration reply |
| `Property ID` | the id System Studio delivered, else `Not delivered yet (System Studio)` | configuration `property_id` |
| `Controller ID` | as above | configuration `controller_id` |
| `AI Provider` | display name, else `Not configured (System Studio)` | configuration `provider.name` |
| `AI Model` | display name, else `Not configured (System Studio)` | configuration `provider.model` |
| `AI API Credential` | the **status text** System Studio wrote (e.g. `Configured in System Studio · Anthropic ••••abcd`), else `Not configured`. Not an input; the driver never receives, stores or displays a key | configuration `credential_status` |
| `AI Status` | `Ready`, `Working: N request(s) waiting for a result`, `Degraded: <connection text>`, `Unavailable: <licence>`; `(learning paused)` and `— last request refused (<code>)` / `refused locally (<code>)` / `not delivered (<code>)` appended when they apply | state machine + last refusal |
| `Telemetry Status` | `Through the Agent: N sent, N acknowledged, N dropped; buffer N, buffer drops N`, or `No Agent answering: N critical event(s) buffered, N waiting in memory, N dropped`, or `Learning paused: …` | module client + buffer |
| `Learning Status` | `Active`, `Paused by <who>: <reason>`, `Stopped (not licensed)` | config / `set_learning` / licence |
| `Permission Mode` | `observe`, `recommend` or `execute_low_risk` + ` (set in System Studio)`, else `Not delivered yet (System Studio owns it)` | configuration `permission_mode` |
| `Flight Recorder Link` | `Installed: local history served; topics subscribed`, `Installed (no local history service; update the Flight Recorder)`, `Not installed: AI Core collects its minimal set itself`, `Unknown (needs Agent protocol 2)` | Agent directory |
| `License Status` | the licence SDK's one line (`sbos.license`) | Agent |
| `License Source`, `Subscription Tier`, `SmartBuildOS Company` | licence display set | Agent |
| `Last Synchronization` | last time the platform was heard (config applied, restricted operation, accepted cloud answer, Sync Now) | driver |
| `Last Test Result` | result line of Test Agent Link / Test AI Connection | actions |
| `Last Error` | last error or refusal, ≤ 240 characters, `none` when clear | driver |
| `Log Level` (editable) | `0 - Fatal` … `5 - Trace` | — |
| `Log Mode` (editable) | `Off`, `Print`, `Log`, `Print and Log` | — |

## 2. Actions

| Action | Command | Does |
| --- | --- | --- |
| `Test Agent Link` | `TEST_AGENT_LINK` | `SBOS_MODULE_DISCOVER` to the Agent; writes the Agent's version, protocol range, pairing, cloud state and module count to `Last Test Result` (or why it cannot: no Agent, protocol 1, failed with a code) |
| `Test AI Connection` | `TEST_AI_CONNECTION` | cloud op `test_provider`; `Last Test Result` says accepted (job id; the result arrives as AI Response Ready) or the refusal code |
| `Sync Now` | `SYNC_NOW` | re-registers if needed, drains the buffer, flushes staged events, re-reads the directory, sends a status frame, and (protocol 2) calls cloud op `status` with the applied config version |
| `Print Diagnostics` | `PRINT_DIAGNOSTICS` | prints state, Agent link, licence, configuration, learning, Flight Recorder link, collection plan, every counter, pending jobs and bus counters to the Lua output |

## 3. Composer commands

Parameters arrive as strings. Every value is validated; an over-long text is
**refused**, not cut. A refused command sends nothing, sets `Last Error` /
`AI_LAST_ERROR` and `AI Status` (`refused locally (<code>)`). At most 10
commands a minute (local token bucket; the 11th is refused `rate_limited`).
`ROOM` is a room **name or id** resolved against `C4:GetDevices` (rooms are
known through the devices in them). LIST labels normalise to codes
(`Last 7 Days` → `last_7_days`).

| Command | Parameters (type, bound) | Cloud op | Feature |
| --- | --- | --- | --- |
| `AI_ASK` | `QUESTION` STRING ≤ 500, required; `ROOM` STRING optional | `ask` | `BASE` |
| `AI_ANALYZE_ROOM` | `ROOM` STRING required | `analyze_room` | `BASE` |
| `AI_ANALYZE_SYSTEM` | — | `analyze_system` | `BASE` |
| `AI_RECORD_EVENT` | `NAME` STRING ≤ 120 required; `DETAIL` STRING ≤ 400; `ROOM` STRING; `CATEGORY` LIST (General, Lighting, Comfort, Media, Security, Access, Safety, Energy, Presence, System, Programming, Maintenance; default General) | none — recorded as `ai_core.record` | `BASE` |
| `AI_SET_CONTEXT` | `KEY` LIST (Occupancy, Guests Present, Vacation, Quiet Hours, Special Event, Cleaning, Maintenance Window) required; `VALUE` STRING ≤ 120 required | `set_context` (key sent as `context_key`) | `BASE` |
| `AI_LEARN_PREFERENCE` | `STATEMENT` STRING ≤ 300 required; `ROOM` STRING | `learn_preference` (refused while learning is paused) | `AI_LEARNING` |
| `AI_SUGGEST_SCENE` | `ROOM` STRING required; `OCCASION` STRING ≤ 120 required | `suggest_scene` | `BASE` |
| `AI_GENERATE_REPORT` | `TYPE` LIST (System Health, Usage, Energy, Security, Comfort, Device Reliability); `PERIOD` LIST (Today, Last 24 Hours, Last 7 Days, Last 30 Days) | `generate_report` | `BASE` |
| `AI_START_DIAGNOSTIC` | `DEVICE` DEVICE_SELECTOR **or** `ROOM` STRING (exactly one) | `start_diagnostic` (after the local diagnostic, §8) | `BASE` |
| `AI_SEND_NOTIFICATION` | `TITLE` STRING ≤ 80 required; `MESSAGE` STRING ≤ 400 required; `AUDIENCE` LIST (Homeowner, Integrator, All; default Homeowner) | `send_notification` (recipients decided by the platform) | `BASE` |

Room exclusions: a command whose room (or whose device's room) is excluded by
configuration is refused `not_permitted`, except `AI_ASK` and
`AI_SEND_NOTIFICATION` (the cloud decides those).

Flow of a cloud command: validate → new `request_id` (`aic-<uuid>`,
`AI_LAST_REQUEST_ID`) → `ai_core.command` envelope (evidence `requested`,
correlation id = request id) → `client.cloudRequest(op, body,
{idempotency_key = request_id})` → the Agent POSTs
`/api/integrations/control4/modules/rpc`. Body: `{command, request_id,
<normalised args>}` (+ `room_id`/`room_name`, `device_id`/`device_name`).

The quick answer (`aicore.commands.interpret`):

| Answer | Meaning | Shown |
| --- | --- | --- |
| `status=ok`, `result.accepted=true` | accepted; `job_id` kept as a pending job (≤ 20, 30 min) | `AI Status` Working; `AI_STATUS` `working` |
| `status=ok` without `accepted=true` | **not** success (`cloud_refused`) | Last Error `…answered without accepting…` |
| `not_permitted`, `invalid_args`, `unsupported`, `payload_too_large`, `agent_not_paired`, `cloud_refused`, other | refused, not retried | Last Error `refused by SmartBuildOS: <code>`; AI Status `— last request refused (<code>)` |
| `cloud_unreachable`, `deadline_exceeded`, `target_unavailable`, `rate_limited` (after the client's 2 retries, same key) | not delivered | Last Error `no answer from SmartBuildOS (<code>)`; `cloud_unreachable` also sets the connection state |
| `incompatible_protocol` | v1 Agent | refused locally before sending when the Agent is v1 |

## 4. Composer events

Ids are permanent. Registered from XML and again with `C4:AddEvent` at start.

| Id | Event | Fired when |
| --- | --- | --- |
| 1 | `AI Response Ready` | `deliver_result` (or `raise_event ai_response_ready`) |
| 2 | `Pattern Detected` | `raise_event pattern_detected` |
| 3 | `Recommendation Available` | `raise_event recommendation_available` |
| 4 | `Automation Conflict Detected` | `raise_event automation_conflict_detected` |
| 5 | `Device Failure Pattern Detected` | `raise_event device_failure_pattern_detected` |
| 6 | `Approval Required` | `raise_event approval_required` |
| 7 | `Action Completed` | `raise_event action_completed` |
| 8 | `Action Failed` | `raise_event action_failed` |
| 9 | `Agent Disconnected` | this driver only: `AGENT_CONNECTED` goes true → false (registration lost, Agent restarted, or the Agent stopped answering the liveness probe). Not raisable by the platform |
| 10 | `AI Provider Error` | `raise_event ai_provider_error`; also sets `AI_LAST_ERROR` / `Last Error` to `AI provider error: <detail>` (cleared by the next `deliver_result`) |

## 5. Variables and conditionals

Variables (ids fixed, order frozen):

| Id | Variable | Type | Value |
| --- | --- | --- | --- |
| 4000 | `AI_STATUS` | STRING | state code (§6) or `working` |
| 4001 | `AI_LAST_RESPONSE` | STRING | last delivered result, ≤ 1024 bytes (cut on a UTF-8 boundary, marked `...`) |
| 4002 | `AI_LAST_RESPONSE_ID` | STRING | its `response_id` |
| 4003 | `AI_LAST_REQUEST_ID` | STRING | the last command's `request_id` |
| 4004 | `AI_LAST_EVENT_DETAIL` | STRING | `raise_event` detail (≤ 512) or the Agent Disconnected reason |
| 4005 | `AI_PENDING_APPROVALS` | NUMBER | from `deliver_result` / `raise_event` `pending_approvals` |
| 4006 | `AI_RECOMMENDATION_COUNT` | NUMBER | from `recommendation_count` |
| 4007 | `AGENT_CONNECTED` | BOOL | registered and answering |
| 4008 | `LEARNING_ACTIVE` | BOOL | learning on |
| 4009 | `AI_LAST_ERROR` | STRING | as `Last Error` (empty when clear); includes the platform's AI provider error (`raise_event ai_provider_error`) |

All except `AI_STATUS`, `AGENT_CONNECTED` and `LEARNING_ACTIVE` (recomputed
at start) are persisted and repainted after a reload.

Conditionals (BOOL): `AI_READY` (state `ready`), `AGENT_CONNECTED`,
`LEARNING_ACTIVE` (learning on and licence not halted), `APPROVALS_PENDING`
(`AI_PENDING_APPROVALS` > 0), `RECOMMENDATIONS_AVAILABLE`
(`AI_RECOMMENDATION_COUNT` > 0).

## 6. State machine

`aicore.state.code(facts)`; first match wins:

| Code (`AI_STATUS`) | Condition | `SmartBuildOS Connection Status` |
| --- | --- | --- |
| `no_agent` | no `smartbuildos.c4z` found (licence SDK's 3-tier discovery) | `No SmartBuildOS Agent in this project` |
| `agent_update_required` | the Agent negotiated protocol 1 (or refused with max 1) | `SmartBuildOS Agent update required (module contract v2)` |
| `agent_lost` | registered, but the liveness probe got no directory by its deadline | `SmartBuildOS Agent not responding` |
| `registering` | Agent found, registration not accepted yet | `Registering with the SmartBuildOS Agent` |
| `agent_unpaired` | the Agent reports `paired=false` | `SmartBuildOS Agent not paired` |
| `cloud_unreachable` | the Agent reports `connected=false`, or the last cloud call ended `cloud_unreachable` | `SmartBuildOS cloud unreachable` |
| `unlicensed` | `license.enforces()` (definitive denial with enforcement on) | `Connected (not licensed)` |
| `ready` | none of the above (`AI_STATUS` = `working` while jobs are pending) | `Connected` |

Transitions: every change of code emits one `ai_core.status` envelope
(severity `warning` for any code other than `ready`/`unlicensed`, which makes
it critical for the buffer). `AGENT_CONNECTED` true → false fires
`Agent Disconnected`.

Lifecycle: LateInit registers (`SBOS_MODULE_REGISTER` with the v2 manifest),
the module client retries every 30 s doubling to 5 min; on
`SBOS_MODULE_AGENT_HELLO` it re-registers (new token) and re-subscribes; on
`SBOS_MODULE_DIRECTORY_CHANGED` it re-reads the directory 2 s later. A
liveness probe (`SBOS_MODULE_DISCOVER` filtered to `flight_recorder`) runs
every 5 min and every 30 s while the Agent is not answering; failure →
`agent_lost` + a re-registration attempt; the first answer → flush the buffer.
Persisted across Director reload, driver update and controller restart:
configuration + version + last refusal (`aicore_config_v1`), learning state
(`aicore_learning_v1`), the buffer (`aicore_buffer_v1`), last result/request/
detail/error/sync (`aicore_last_v1`), and the envelope sequence
(`sbos_module_seq`, `sbos.seqblock`: may skip, never repeats).

## 7. Restricted operations (from the platform)

Delivered by the Agent's `MODULE_COMMAND` runner as `SBOS_MODULE_COMMAND`
(`MODULE_COMMANDS.ai_core`, registered by this driver). States reported with
`SBOS_MODULE_COMMAND_RESULT`: `Accepted` (module client), `Executing`, then
`Completed` / `Failed`. Each operation accepts a **closed set of argument
keys**; any other key refuses the whole operation (`Failed`). None controls
equipment, runs code, or takes a command name to forward.

| Operation | Arguments | Effect |
| --- | --- | --- |
| `apply_config` | `config` (object), `version` (integer) | as §9; `Completed` / `Failed` with the refusals; status frame with `applied_config_version` / `config_error` |
| `refresh_status` | — | repaint, `ai_core.status` envelope, status frame |
| `deliver_result` | `response_id` (id, required), `text` (≤ 4000, required), `request_id`, `job_id`, `kind` (`answer`, `analysis`, `report`, `scene_suggestion`, `diagnostic`), `pending_approvals`, `recommendation_count` (0–9999) | sets `AI_LAST_RESPONSE` (bounded), `AI_LAST_RESPONSE_ID`, counts; clears the pending job; fires `AI Response Ready` |
| `raise_event` | `event` (one of `ai_response_ready`, `pattern_detected`, `recommendation_available`, `automation_conflict_detected`, `device_failure_pattern_detected`, `approval_required`, `action_completed`, `action_failed`, `ai_provider_error`), `detail` (≤ 512, control characters removed), `pending_approvals`, `recommendation_count` | sets `AI_LAST_EVENT_DETAIL`, counts; fires the event; `ai_provider_error` also sets `AI_LAST_ERROR` (`AI provider error: <detail>`, or `… (no detail from SmartBuildOS)`), which the next `deliver_result` clears. Anything else → `Failed`, nothing fired |
| `set_learning` | `active` (boolean), `reason` (≤ 120) | learning on/off (on needs `AI_LEARNING` when enforced); re-plans collection |
| `run_diagnostic` | exactly one of `device_id`, `room_id`; `note` | the local diagnostic (§8); `Executing` then `Completed` with the envelope id and how many local events |

Proof that no path reaches equipment: `test/test_aicore_driver.lua` [19] and
`test/emulator/ai_core.lua` [14] record every `C4:SendToDevice` the driver
makes over the whole run — all go to the Agent — and that
`SetDeviceVariable`, `SendToProxy`, `SendUIRequest`, `RegisterDeviceEvent`
and `Bind` are never called, including with equipment-shaped arguments.

## 8. Local diagnostics

`AI_START_DIAGNOSTIC` / `run_diagnostic`: when the Flight Recorder is present
and advertises the capability, ask it over contract v2
(`events.device_history {device_id, limit: 25}` or `events.room_activity
{room_id, limit: 25}`, timeout 10 s, 1 retry). Then record **one**
`ai_core.diagnostic` envelope:

```
payload = { request_id, source, target,
  flight_recorder = { available = true, capability, truncated, held, capacity,
                      oldest_available, events = [{event_id | no_event_id, at, kind, line}], omitted },
  note = "local Flight Recorder history only; causes are not inferred on the controller" }
```

Summaries are cut from the oldest end to fit the 4 KB envelope payload; the
cut is counted in `omitted`. When there is nothing to attach the envelope
says why: `flight_recorder_not_installed`, `flight_recorder_has_no_local_history_service`,
`flight_recorder_unknown_agent_cannot_discover`, or `request_failed` with
`error_code`. For `AI_START_DIAGNOSTIC` the cloud op `start_diagnostic`
follows with `diagnostic_event_id`, `local_event_ids` and
`flight_recorder_available`.

### Flight Recorder local history (served by the Flight Recorder, Part A)

The Flight Recorder (manifest `sbos.flight_recorder`) advertises
`events.query`, `events.timeline`, `events.device_history`,
`events.room_activity` (requests) and `events.subscribe` (topic over
`capture.`, `observation.`, `trace.`). Not advertised: correlation, incident
analysis, period comparison (cloud-side). Code: `src/flightrecorder/localquery.lua`.

| Capability | Arguments (closed) | Default order |
| --- | --- | --- |
| `events.query` | `limit` 1–200 (50), `cursor`, `order` `asc`/`desc`, `from`, `to` (epoch s), `since_seq`, `kinds` (`event`, `change`, `trace`, `mark`, `system`, `note`), `device_id`, `room_id`, `text` (≤ 64) | desc |
| `events.timeline` | `limit`, `cursor`, `from`, `to` (default the last 15 min; window ≤ 31 days), `kinds` | asc |
| `events.device_history` | `device_id` (required), `limit`, `cursor`, `order`, `from`, `to` | desc |
| `events.room_activity` | `room_id` (required), `limit`, `cursor`, `order`, `from`, `to` | desc |

Answer: `{capability, events, count, has_more, order, truncated, retention,
window?}` plus the contract `cursor` when more remain (`h<generation>.<a|d>.<seq>`;
refused after Clear Local History). Each event: `seq`, `event_id` (the
envelope id the platform stores) **or** `no_event_id` (`over_upload_budget`
— held locally but never uploaded; `not_recorded` — recorded before ids were
kept), `at`, `t`, `kind`, `event_type`, device/room ids and labels, and the
kind's fields (a device event's Composer event number is `device_event_id`).
`retention = {source, policy, capacity, held, newest_seq, evicted_total,
history_generation, recording_status, oldest_available{seq, at}}`.
`truncated = true` when older matching entries may have existed but are no
longer held. Pages stay under ~20 KB (hard cap 24 KB, measured by encoding).
Answered whatever the recording state; never synthesised. Against a v1-only
Agent nothing changes (no `require_protocol`).

## 9. Configuration (`SBOS_DRIVER_CONFIG`, SKU `SBOS_AI_CORE`)

Forwarded by the Agent (`SKU_FILENAMES.SBOS_AI_CORE`); acknowledged with
`SBOS_DRIVER_CONFIG_ACK` (`applied`, `refused` count, `settings_version`) and
a status frame with `applied_config_version` / `config_error`. The same
document can arrive by `apply_config`.

```json
{
  "schema": 1,
  "learning": { "active": true },
  "exclusions": { "rooms": [12, 40], "categories": ["security"] },
  "permission_mode": "observe | recommend | execute_low_risk",
  "provider": { "name": "Anthropic", "model": "…" },
  "credential_status": "Configured in System Studio · Anthropic ••••abcd",
  "collection": {
    "system_events": true,
    "flight_recorder_topics": true,
    "agent_events": true,
    "variables": [ { "device_id": 12, "variable": "LIGHT_STATE" } ],
    "max_events_per_minute": 60
  },
  "property_id": "…",
  "controller_id": "…"
}
```

Rules (`aicore.config`): every key optional (defaults: learning on,
nothing excluded, system events on, topics on, Agent events on, no
variables, 60/min); **unknown keys refuse the document**; any key anywhere
whose name is credential-shaped (`api_key`, `token`, `secret`, … —
`sbos.envelope.isSensitiveKey`) refuses it; display strings are bounded
(`provider.name` 40, `provider.model` 80, `credential_status` 96), have no
control characters, and are refused if they look like a key (`sk-…`,
`Bearer …`, long opaque blobs); `exclusions.rooms` ≤ 256 ids;
`exclusions.categories` from the closed list (`general`, `lighting`,
`comfort`, `media`, `security`, `access`, `safety`, `energy`, `presence`,
`system`, `programming`, `maintenance`, `unknown`); `variables` ≤ 32, never a
code- or credential-named variable; `max_events_per_minute` 1–300. One bad
field refuses the whole document; the last valid one stays in force and
`Last Error` says `Configuration vN refused: <path>: <reason> (vM kept)`.
`learning.active` is the platform's latest word on learning (a later
`set_learning` overrides it until the next document).

## 10. Event collection (D7: no double capture)

What the Flight Recorder captures, read from its source
(`drivers/smartbuildos-flight-recorder/driver.lua`, `src/tracer/tracer.lua`,
`src/flightrecorder/{recorder,config,traces}.lua`), and what AI Core does:

| Class | Flight Recorder | AI Core when FR present (v2) | AI Core when FR absent |
| --- | --- | --- | --- |
| Composer device events, every catalogued device (`C4:RegisterDeviceEvent`) | `capture.event` (within its upload budget) | consumes topic `capture.` | **not collected** (needs the recorder's catalogue; documented gap) |
| Device/room variables selected in Studio (`C4:RegisterVariableListener`) | `observation.change` / `observation.initial` | consumes topic `observation.` | own listeners for `collection.variables` only (default none) → `ai_core.observation.variable` |
| Programming markers and traces (`RECORD_EVENT`, `START_TRACE`, …) | `observation.programmed`, `trace.*` | consumes `observation.` / `trace.`; `AI_RECORD_EVENT` is AI Core's own marker (`ai_core.record`) | `AI_RECORD_EVENT` only |
| Agent-classified events (`SBOS_MODULE_AGENT_EVENT`) | `observation.system`, only when selected as a source | left to the recorder | recorded → `ai_core.observation.agent` |
| Director system events (`C4:RegisterSystemEvent`) | **not captured** | own collector, always | own collector, always |

Own system events (documented ids only, registered system-wide with device
0): 17 `OnNetworkBindingAdded`, 18 `OnNetworkBindingRemoved`, 19
`OnNetworkBindingRegistered`, 20 `OnNetworkBindingUnregistered`, 48
`OnDeviceOnline`, 49 `OnDeviceOffline` (severity warning → critical), 90
`OnDirectorIPAddressChanged` → `ai_core.observation.system` with the
undocumented payload kept as bounded unreviewed text.

An old (v1) recorder or an unknown one (v1 Agent, cannot discover) is
treated as present for collection: AI Core does not duplicate its classes.

Consumed events are **not re-uploaded** (they already reach the cloud
through the recorder's own upload); AI Core uses them locally (counters,
dedup) only.

Before anything is recorded or consumed, `aicore.collector` applies, in
order: learning paused or licence halted → nothing (and the subscription,
system-event registrations and variable listeners are released); excluded
room; excluded category; event-id dedup (ring of 512); per-minute budget
(own observations only). Events never claim who caused a change, the
previous value, or that a programming item executed — DriverWorks does not
provide those; unknown stays unknown (category `unknown`).

## 11. Outbound envelopes (`ai_core.` prefix, envelope v1)

| Event type | Evidence | When |
| --- | --- | --- |
| `ai_core.command` | `requested` | each cloud command (payload `command`, `op`, `request_id`, `args`) |
| `ai_core.record` | `instrumented` | `AI_RECORD_EVENT` (severity warning for security/safety) |
| `ai_core.status` | `derived` | each state change and `refresh_status` (payload `state`, `previous_state`, counts) |
| `ai_core.observation.system` | `system` | own system events |
| `ai_core.observation.agent` | `system` | Agent events, recorder absent |
| `ai_core.observation.variable` | `initial` / `observed` | own variable listeners, recorder absent |
| `ai_core.diagnostic` | `derived` | §8 |

Payload keys never use names the envelope redacts (`code`, `key`, …).

## 12. Buffering, health, limits

* Normal path: module client stage (≤ 300, frames of ≤ 100, 30 s ack, 3
  tries) → the Agent's durable acknowledged queue → `/events`.
* No Agent answering (not installed, registering, not responding): critical
  envelopes (severity ≥ warning) go to the persisted buffer (50, dedup by
  `event_id`, evict least severe then oldest, every drop counted); the rest
  wait in the module client's memory stage (lost on restart, counted when
  dropped). The buffer drains oldest first on registration, on the first
  answered probe, and on every tick while answered. Envelopes carry
  `sequence`; the platform orders by it.
* `SBOS_MODULE_STATUS` counters: `events_recorded`, `events_buffered`,
  `events_staged`, `events_sent`, `events_dropped`, `events_unrecordable`,
  `buffer_depth`, `buffer_dropped`, `buffer_flushed`, `requests`, `refusals`,
  `cloud_accepted`, `cloud_refused`, `cloud_unreachable`,
  `last_cloud_result`, `results_delivered`, `events_raised`, `operations`,
  `operations_refused`, `liveness_failures`, `jobs_expired`, `jobs_dropped`,
  `system_events`, `variable_events`, `agent_events`, `collector_*`,
  `applied_config_version`, `config_error`, `learning_active`,
  `flight_recorder`, `flight_recorder_subscribed`, and `bus` (module client).
* Licence (`sbos.license`, SKU `SBOS_AI_CORE`): commands, `run_diagnostic`
  and collection stop only when `license.enforces()` (a definitive denial
  with enforcement on). A missing feature refuses only when enforcement is
  on **and** the status is authorised (the feature list is then definitive).
  Grace, trial, legacy, cloud-validation-required and no-answer states fail
  open. Updates: the Agent's updater (`DRIVER_FILENAMES`; store `sku_for`).
* Limits: question 500, statement 300, name 120, detail 400, value 120,
  occasion 120, title 80, message 400, room 64, result text 4000,
  `AI_LAST_RESPONSE` 1024 bytes, event detail 512, error 240; 10 commands a
  minute; 20 pending jobs for 30 min; cloud body 16 KB, request args 16 KB,
  result 24 KB (contract v2).

## 13. Verification

| What | Where |
| --- | --- |
| Driver under the shim with a scripted Agent (19 sections) | `test/test_aicore_driver.lua` (+ `test/aicore_harness.lua`) |
| Names agree across XML, code, Agent tables, policy, docs | `test/test_aicore_surface.lua` |
| Per module | `test/test_aicore_{commands,config,operations,buffer,collector,state,diagnostic}.lua` |
| Packaging (squish closure; built `.c4z` when present) | `test/test_aicore_package.lua` |
| Flight Recorder local history | `test/test_flightrecorder_localquery.lua`, `test/test_flightrecorder_v2.lua` |
| Real Agent + real Flight Recorder + AI Core (EMULATOR ONLY) | `test/emulator/run-ai-core.sh` → `test/emulator/ai_core.lua` |

## 14. Not verified on hardware

No physical controller has run this driver, the Flight Recorder's v2
service, or module contract v2. Owed on a bench:

* the whole driver on OS 3.3.2 and 4.x (LuaJIT load, `<script>` tag, squished modules);
* `C4:UUID("RANDOM")` output; BOOL variable values `"true"`/`"false"` as Composer conditions read them;
* `OnSystemEvent` payload format for ids 17–20, 48, 49, 90 (only the `name="…"` attribute is read);
* `RegisterVariableListener` first-callback behaviour (treated as `initial`);
* SendToDevice ordering, frame sizes near 24–32 KB, timer behaviour under Director load;
* the platform route `/api/integrations/control4/modules/rpc` (until deployed, the Agent gets 404 → `cloud_refused`);
* persistence across a real power cut (Director's flush timing).

## 15. Deviations from the brief / architecture

| Deviation | Reason |
| --- | --- |
| `AI_RECORD_EVENT` makes no cloud call; it is recorded as `ai_core.record` through the durable event path | `MODULE_CLOUD_OPS.ai_core` has no op for it; the event path is durable and deduplicated |
| No separate `ai_core.context` envelope | the context is already in the `ai_core.command` envelope of `AI_SET_CONTEXT`; a second envelope would duplicate it |
| Context key travels as `context_key` | `key` is redacted by the envelope's credential rules |
| `ROOM` is a STRING (name or id), not a room selector | the documented command parameter types have no room selector; DYNAMIC_LIST needs a 3.3 `GetCommandParamList` path that is unverified here |
| Device events are not collected when the Flight Recorder is absent | `RegisterDeviceEvent` needs per-driver event ids (the recorder's catalogue); duplicating that catalogue would be the double capture D7 forbids |
| Variables are collected by AI Core only when listed in `collection.variables` | no documented API identifies a device's proxy type reliably; System Studio selects |
| Agent-classified events are left to the recorder when it is present, even if it is not configured to record them | AI Core cannot read the recorder's configuration; recording them too would double-capture when it is |
| `Last Test Result` and `Flight Recorder Link` properties added | the four actions need a place to report; the recorder link is a state the brief requires to be clear |
| Agent liveness is a periodic directory request | DriverWorks gives no delivery acknowledgement; the directory request is the cheapest authenticated round trip the Agent answers |
