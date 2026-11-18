# SmartBuildOS module contract v2 (driver-to-driver protocol)

Status: implemented on driver branch `feat/ai-core`. **Emulator-verified only;
bench validation on a physical controller is owed.** Nothing here has run on
Control4 hardware.

v2 is a strict superset of v1 (`docs/flight-recorder/PROTOCOL.md`): every v1
frame, field and rule is unchanged and v1 modules keep working against a v2
Agent. v2 adds module discovery, local pub/sub, module-to-module requests and
a closed-vocabulary cloud relay, all hub-and-spoke through the SmartBuildOS
Agent.

| Part | Code |
| --- | --- |
| Vocabulary, limits, policy tables | `src/sbos/modulepolicy.lua` |
| Registry (manifest, tokens, negotiation) | `src/sbos/modules.lua` |
| Agent bus engine | `src/sbos/modulebus.lua` |
| Agent wiring (EC handlers, cloud POST) | `drivers/smartbuildos/driver.lua` (module section) |
| Module-side engine | `src/sbos/modulerpc.lua` |
| Module client (registration + v2 calls) | `src/sbos/moduleclient.lua` |

## 1. Transport and trust

Every frame is `C4:SendToDevice(id, COMMAND, params)` → the receiver's
`ExecuteCommand` → `EC.COMMAND(tParams)`. Params are strings on-controller;
structured data is JSON in one param. DriverWorks gives no sender identity,
no broadcast and no delivery guarantee, so the Agent supplies them:

- **Module → Agent:** every v2 frame carries the v1 auth triple
  (`module_id`, `instance_id`, `token`). The Agent authenticates it against
  its registry before anything else; a frame that fails is **ignored without
  any answer** (counted as `ignored`).
- **Sender stamping:** every frame the Agent forwards is rebuilt field by
  field. `from_module_id` / `from_instance_id` are written by the Agent from
  the registry entry the token authenticated. Anything a module puts in its
  own frame about who it is (including `from_*` params) is never forwarded.
- **Agent → module:** every v2 frame carries the **recipient's** auth triple.
  The client ignores any frame whose `token` is not the one the Agent gave it
  at registration, so another driver cannot inject answers, events or
  directory changes.
- **Tokens:** minted from `C4:UUID("RANDOM")` (v4 UUID, 122 random bits;
  dashes removed, lowercased, 32 hex characters) when Director returns a
  UUID; otherwise the v1 generator (4 × `math.random`, seeded once). A new
  token is issued on every registration, so a re-registration ends the old
  session.
- **Debug log:** ExecuteCommand (vendor `handlers.lua`) prints every param
  when debug printing is on. The Agent sets `EC.suppressDebug` for
  `SBOS_MODULE_REQUEST`, `SBOS_MODULE_RESPONSE`, `SBOS_MODULE_CLOUD_REQUEST`
  and `SBOS_MODULE_CLOUD_RESPONSE` (the last is only ever sent by the Agent;
  it is listed so a future handler cannot start printing results), so
  request args, results and cloud bodies never reach its debug output.

## 2. Versions and negotiation

`PROTOCOL_MIN = 1`, `PROTOCOL_MAX = 2` on the Agent and on the client. The
module sends `protocol_min` / `protocol_max`; the Agent answers the highest
common version in `SBOS_MODULE_REGISTERED.protocol` and its own range in
`agent_protocol_min` / `agent_protocol_max`.

| Module | Agent | Result |
| --- | --- | --- |
| v1 (1..1) | v2 | registered at 1; v1 only; no manifest stored; v2 frames from it are answered `incompatible_protocol` |
| v2 (1..2) | v2 | registered at 2; everything in this document |
| v2 (1..2) | v1-only | registered at 1; v1 services work. With `require_protocol = 2` the module reports `agent_update_required` (display status and `onAgentState(agent, "agent_update_required")`); every v2 call completes at once with `incompatible_protocol`; nothing v2 is sent |
| v2-only (2..2) | v1-only | refused `incompatible_protocol` with `agent_protocol_max = 1` → `agent_update_required` |
| 3+ only | v2 | refused `incompatible_protocol` with the Agent's range |

A v1-only Agent has no handler for any v2 command, so even a mis-sent v2
frame is a no-op there.

## 3. Registration and the capability manifest

`SBOS_MODULE_REGISTER` gains one optional param, `manifest` (JSON, ≤ 2 KB).
The v1 csv params are unchanged. The manifest is parsed and stored only when
the negotiated protocol is ≥ 2.

```json
{
  "driver": "sbos.flight_recorder",
  "version": "20261118.120000",
  "protocol": 2,
  "capabilities": [
    { "id": "events.query", "version": 1, "kind": "request" },
    { "id": "events.subscribe", "version": 1, "kind": "topic",
      "topics": ["capture.", "observation.", "trace."] }
  ]
}
```

| Field | Rule |
| --- | --- |
| `capabilities[]` | ≤ 24 entries |
| `id` | `^[a-z][a-z0-9_]*\.[a-z0-9_.]+$`, ≤ 64 |
| `kind` | `request` (default) or `topic` |
| `topics` | required for `topic`: 1–16 prefixes, `^[a-z][a-z0-9_]*\.[a-z0-9_.]*$`, ≤ 64 |
| `driver` ≤ 64, `version` ≤ 32 | informational |

**Registry cap:** the Agent holds at most **48** registrations; the 49th
live one is refused `registry_full` (stale entries are pruned first to make
room; re-registering an existing instance always works). Only root drivers
register; child drivers never do. Persist, heartbeat and directory sizes at
48 entries are unmeasured on hardware.

**Identity binding (reserved module ids).** The Agent table
(`modulepolicy.RESERVED_MODULES`) binds a module id to the `.c4z` file(s)
that may register it:

| Module id | Driver file |
| --- | --- |
| `ai_core` | `smartbuildos-ai-core.c4z` |
| `flight_recorder` | `smartbuildos-flight-recorder.c4z` |
| `usage_analytics` | `smartbuildos-usage-analytics.c4z` |
| `mqtt_broker` | `smartbuildos-mqtt-broker.c4z` |
| `venueflow` | `smartbuildos-venueflow.c4z` |
| `pin_lock` | `smartbuildos-pin-lock.c4z` |
| `atmosphere` | `smartbuildos-atmosphere.c4z` |
| `mode_composer` | `smartbuildos-mode-composer.c4z` |
| `bond_bridge` | `bond-bridge.c4z` |
| `commissioning` | `smartbuildos-commissioning.c4z` |
| `daypart` | `smartbuildos-daypart.c4z` |
| `dealer_panel` | `smartbuildos-dealer-panel.c4z` |
| `guest_mode` | `smartbuildos-guest-mode.c4z` |
| `load_shedding` | `smartbuildos-load-shedding.c4z` |
| `logic_pack` | `smartbuildos-logic-pack.c4z` |
| `notification_router` | `smartbuildos-notification-router.c4z` |
| `solar` | `smartbuildos-solar.c4z` |
| `system_link` | `smartbuildos-system-link.c4z` |
| `user_manual` | `smartbuildos-user-manual.c4z` |
| `variable_inspector` | `smartbuildos-variable-inspector.c4z` |
| `unifi_protect` | `unifi-protect.c4z` |

Every root driver's id is reserved (the 21 roots in `drivers/`; the Agent
itself never registers), so a root that joins the bus through
`sbos.aireport` is `verified`. `src/sbos/aireport.lua` `MODULE_IDS` is the
same table keyed by file; `test/test_sbos_aireport.lua` [1] fails if the two
drift or a file is not a directory in `drivers/`.

On a registration under a reserved id the Agent asks Director
(`C4:GetDevicesByC4iName(file)`, injected into the registry as a resolver)
which devices run that file, and compares the claimed `instance_id`:

| Director's answer | Result |
| --- | --- |
| the claimed device is listed | registered, `verified = true` |
| a table that does not list it | refused, `reason = not_permitted`; an earlier entry for that exact module + instance is removed (and its routes answered `target_unavailable`) |
| no table (nil, or the call errors) | registered, `verified = false` |

Any other module id registers exactly as before with `verified = false`.
`verified` is the Agent's own finding, carried in directory rows (§4) and
heartbeat module rows (§14); a module's own claim is never copied into it.
Consumers decide what an unverified module may do (the platform refuses
declared actions from one; AI Core refuses PIN verification unless
`pin_lock` is verified). The bus itself does not consult `verified`: the
policy tables (§9) already confine what any module id can do, and a
reserved id can only be held by its own driver file unless Director gave no
answer. Adding a SmartBuildOS module id to the reserved table is an Agent
release.

A malformed manifest does not fail the registration: the entry is stored
without a manifest and the reply carries `manifest_error`
(`invalid_manifest`, `manifest_too_large`, `too_many_capabilities`,
`invalid_capability`). A capability a driver cannot serve locally must not
be advertised; consumers discover, they never assume.

## 4. Frames

All params are strings. "auth" = `module_id`, `instance_id`, `token`.

| Direction | Command | Params (beyond auth) | Answer |
| --- | --- | --- | --- |
| M→A | `SBOS_MODULE_DISCOVER` | `request_id`, `filter` (JSON `{module_id?, capability?}`, optional) | `SBOS_MODULE_DIRECTORY` |
| A→M | `SBOS_MODULE_DIRECTORY` | `request_id`, `error_code`, `directory_version`, `agent` (JSON `{version, protocol_min, protocol_max, paired, connected}`), `modules` (JSON array of `{module_id, instance_id, driver, driver_version, protocol, status, stale, verified, capabilities[]}`), `truncated` | — |
| A→M | `SBOS_MODULE_DIRECTORY_CHANGED` | `directory_version` | — |
| M→A | `SBOS_MODULE_SUBSCRIBE` | `subscription_id`, `topics` (JSON array, 1–16) | `SBOS_MODULE_SUBSCRIBED` |
| A→M | `SBOS_MODULE_SUBSCRIBED` | `subscription_id`, `ok`, `reason`, `granted` (JSON), `refused` (JSON) | — |
| M→A | `SBOS_MODULE_UNSUBSCRIBE` | `subscription_id` | none |
| A→M | `SBOS_MODULE_PUBLISH` | `subscription_id`, `events` (JSON array of envelopes, ≤ 25), `dropped` (count since the previous frame) | — |
| M→A | `SBOS_MODULE_REQUEST` | `request_id`, `idempotency_key`, `to`, `to_instance` (optional), `capability`, `args` (JSON object ≤ 16 KB), `deadline` (epoch s, now < d ≤ now + 60) | `SBOS_MODULE_REQUEST_ACK` |
| A→M | `SBOS_MODULE_REQUEST_ACK` | `request_id`, `state` (`Routed` / `Refused`), `error_code` | — |
| A→M | `SBOS_MODULE_REQUEST` | target's auth, `request_id`, `idempotency_key`, `from_module_id`, `from_instance_id`, `capability`, `args`, `deadline` | target answers `SBOS_MODULE_RESPONSE` before `deadline` |
| M→A | `SBOS_MODULE_RESPONSE` | `request_id`, `status` (`ok` / `error`), `error_code`, `result` (JSON ≤ 24 KB), `cursor` (≤ 256, optional) | relayed A→M |
| A→M | `SBOS_MODULE_RESPONSE` | `request_id`, `status`, `error_code`, `result`, `cursor`, `from_module_id`, `from_instance_id` (stamped), `replayed` (`"true"` when answered from the idempotency ring) | — |
| M→A | `SBOS_MODULE_CLOUD_REQUEST` | `request_id`, `idempotency_key`, `op`, `body` (JSON object ≤ 16 KB), `deadline` | `SBOS_MODULE_CLOUD_RESPONSE` |
| A→M | `SBOS_MODULE_CLOUD_RESPONSE` | `request_id`, `status`, `http_status` (empty when there was no HTTP answer), `error_code`, `result` (JSON) | — |

Ids (`request_id`, `idempotency_key`): `^[A-Za-z0-9][A-Za-z0-9_:.-]*$`,
≤ 128. `subscription_id`: same pattern, ≤ 64. Every A→M v2 frame also
carries the recipient's auth (§1).

## 5. Discovery

`SBOS_MODULE_DISCOVER` returns every registered module (v1 ones included,
with `protocol = 1` and no capabilities), with `stale` set for entries not
heard from in 15 minutes. Tokens are never included. `filter.module_id`
matches exactly; `filter.capability` keeps modules whose manifest lists it.
If the encoded list exceeds 28 KB, entries are dropped from the end and
`truncated = "true"`. A v1-negotiated module gets `incompatible_protocol`.
Discovery counts against the module's request rate bucket.

`SBOS_MODULE_DIRECTORY_CHANGED` is pushed to every live v2 module when a
module registers, unregisters, or goes stale or live again. It is debounced:
the push goes out 5 s after the **first** change of a burst (a stream of
changes cannot postpone it), carrying the current `directory_version`.
Stale transitions are noticed by the bus tick (every 5 s).

## 6. Pub/sub

- **Policy:** a topic is granted when it starts with a prefix listed for the
  subscriber in `MODULE_TOPIC_POLICY` (equal or narrower). Who may **emit**
  under a prefix is v1's prefix ownership (`Envelope.PREFIXES`).
- **Answer:** all granted → `ok = true`, `reason = ok`; some refused →
  `ok = true`, `reason = not_permitted`, `refused` lists them; none granted →
  `ok = false`, `reason = not_permitted`. Bad id → `invalid_frame`; empty,
  more than 16, or malformed topics → `invalid_args`; v1 module →
  `incompatible_protocol`. At most 8 subscriptions per instance (the 9th →
  `invalid_args`); re-subscribing an existing id replaces it.
- **Fan-out source:** only envelopes the Agent **accepted** from a module's
  `SBOS_MODULE_EVENTS` frame (schema-valid, owned prefix, matching instance,
  not a duplicate), after the Agent stamped `installation_id` / `boot_id`.
  Rejected and duplicate envelopes are never published. An envelope is never
  echoed to the instance that emitted it.
- **Delivery:** best-effort, at-most-once. One buffer per subscription,
  bounded at 200 envelopes, drop-oldest; every drop is counted and the count
  travels in the next frame's `dropped`. Frames go out 1 s after the first
  buffered envelope, ≤ 25 envelopes and ≤ ~24 KB of envelopes each. The
  durable path remains the Agent's cloud queue.
- Subscriptions are Agent memory only. They die with the Agent and with the
  module's own re-registration (new token = new session); the client
  re-sends them (§10).

## 7. Request / response

The Agent checks, in this order, and refuses with `REQUEST_ACK state =
Refused`:

| Check | Code |
| --- | --- |
| `request_id` malformed | `invalid_frame` |
| requester negotiated v1 | `incompatible_protocol` |
| requester's request bucket empty | `rate_limited` |
| `to` / `capability` / `idempotency_key` malformed | `invalid_frame` |
| `args` > 16 KB | `payload_too_large` |
| `args` not a JSON object | `invalid_args` |
| `deadline` missing | `invalid_frame` |
| `deadline` ≤ now | `deadline_exceeded` |
| `deadline` > now + 60 | `invalid_args` |
| `request_id` already routed | `duplicate_request` |
| capability not in `MODULE_REQUEST_POLICY`, or requester not listed (and the row is not the `ANY` wildcard) | `not_permitted` |
| same `(requester module, idempotency_key)` answered before | **replayed** (below) |
| same key still in flight and before its deadline | `duplicate_request` |
| no registered module `to` (or no such `to_instance`) | `unknown_target` |
| `to` is not the policy's provider for the capability | `capability_not_found` |
| no live (non-stale) v2 instance of `to` | `target_unavailable` |
| target manifest lacks the capability as `kind: request` | `capability_not_found` |
| 128 routes already in flight in the Agent | `rate_limited` |

Otherwise: `REQUEST_ACK state = Routed, error_code = ok` to the requester,
then the forwarded `SBOS_MODULE_REQUEST` to the target with the target's
token and the stamped sender.

**Answer.** Only the exact instance the request was routed to may answer;
any other `RESPONSE` (other module, other instance of the same module, late
after cleanup, second answer) is ignored. The Agent normalises `error_code`
to the closed vocabulary (`internal_error` for anything else), replaces a
`result` > 24 KB with `payload_too_large`, an undecodable `result` or a
`cursor` > 256 with `invalid_frame`, and relays to the requester with the
responder stamped.

**Idempotency.** The Agent keeps a ring of 256 `(requester module,
idempotency_key)` → terminal answer. A repeat gets `REQUEST_ACK state =
Routed, error_code = duplicate_request` followed by the stored `RESPONSE`
under the new `request_id` with `replayed = "true"`; it is not routed again.
A target's answer with a retryable code is not stored (so the retry is
routed). A key whose previous attempt is past its deadline is routed again
(the old attempt is abandoned and counted as a timeout). Targets dedup on
`request_id`: a duplicated frame gets the stored answer again and the handler
does not run twice (ring of 256).

**Deadlines.** The requester arms its own timer at `deadline`; no answer →
local `deadline_exceeded`. The Agent drops routing state at `deadline + 5 s`
(bus tick, 5 s granularity). When a target unregisters, its in-flight
requests are answered `target_unavailable` at once.

**Paging.** A result larger than 24 KB is not fragmented: the target returns
one page plus a `cursor`, and the requester asks again with the cursor in its
`args`. The cursor's meaning belongs to the capability.

## 8. Cloud relay

`SBOS_MODULE_CLOUD_REQUEST` is not a proxy: one fixed route, one closed op
list per module.

Checks (answered as `CLOUD_RESPONSE status = error`): `invalid_frame` (id),
`incompatible_protocol`, `rate_limited` (cloud bucket), `invalid_frame` (op /
key malformed), `not_permitted` (op not in `MODULE_CLOUD_OPS[module_id]`),
`payload_too_large` (body > 16 KB), `invalid_args` (body not a JSON object),
deadline rules as §7, `duplicate_request`, `agent_not_paired`, then the
idempotency ring (key `cloud|module|key`; stored answers replayed, in-flight
duplicates refused) and the 128-route cap.

The Agent then POSTs through its own `send()` (pairing token as
`Authorization: Bearer`, advisory property/system headers, `system`
identity, `technical_metadata`, `sent_at` added by `send()`):

```
POST {API URL}/api/integrations/control4/modules/rpc
{ "module_id", "instance_id", "op", "request_id", "idempotency_key", "body" }
```

`module_id` / `instance_id` are the authenticated sender, never a module's
claim. The platform derives tenant and property from the token only, and the
route is unique on `(system_id, module_id, idempotency_key)`.

**Platform answer contract** (what the route must return):

| Platform answer | Relayed as |
| --- | --- |
| 2xx `{ "ok": true, "result": … }` (or any 2xx body without `ok: false`) | `status = ok`, `result` = `body.result` if present else the body, ≤ 24 KB (else `payload_too_large`) |
| 2xx `{ "ok": false, "error_code": c }` | `c` when it is one of `not_permitted`, `invalid_args`, `unsupported`, `payload_too_large`, `rate_limited`, `agent_not_paired`; otherwise `cloud_refused` |
| HTTP 429 | `rate_limited` |
| other HTTP 4xx | `cloud_refused` |
| HTTP 5xx, transport failure, timeout | `cloud_unreachable` |

The platform should answer **business refusals as HTTP 200 with
`ok: false`**: a non-2xx answer goes through `send()`'s existing failure path,
which repaints the Agent's Connection Status, fires the Composer event *Sync
Failed* and reports a sync failure on the `event` path, exactly as for every
other Agent route. AI Core ops are expected to return quickly with
`{accepted, job_id}`; results come back later by other paths.

## 9. Policy tables (Agent data; mirrored in the web repo)

`MODULE_REQUEST_POLICY[capability] = { provider, requesters }`. `provider`
nil means any module whose manifest advertises the capability may serve it.
`requesters = ANY` (`modulepolicy.ANY`, mirrored as `"*"`) means every
authenticated, registered v2 module may call it; frames without a valid
registration token never reach policy (§1). `ANY` is a unique empty
read-only table, so an engine that does not know it refuses.

| Capability | Provider | Requesters |
| --- | --- | --- |
| `events.query` | `flight_recorder` | `ai_core` |
| `events.timeline` | `flight_recorder` | `ai_core` |
| `events.device_history` | `flight_recorder` | `ai_core` |
| `events.room_activity` | `flight_recorder` | `ai_core` |
| `ai_core.report` | `ai_core` | `ANY` |
| `pinlock.availability` | `pin_lock` | `ai_core` |
| `pinlock.challenge` | `pin_lock` | `ai_core` |
| `pinlock.redeem` | `pin_lock` | `ai_core` |
| `ai.query` | any (nil) | `ai_core` |
| `ai.action` | any (nil) | `ai_core` |

These rows are routing policy only. The capabilities' argument and result
contracts, and the drivers that serve them, are specified with the features
that use them (no PIN ever travels in a `pinlock.*` frame).

`MODULE_TOPIC_POLICY[prefix] = { subscribers }`: `capture.`, `observation.`,
`trace.` → `ai_core`.

`MODULE_CLOUD_OPS.ai_core`: `ask`, `analyze_room`, `analyze_system`,
`learn_preference`, `suggest_scene`, `generate_report`, `start_diagnostic`,
`send_notification`, `set_context`, `status`, `test_provider`,
`analyze_household`, `approvals_pending`, `approval_detail`,
`approval_decide`, `driver_reports`, `driver_query_result`,
`driver_action_result`.

Related v1 tables updated for AI Core: `MODULE_COMMANDS.ai_core` (Agent,
`drivers/smartbuildos/driver.lua`) = `apply_config`, `refresh_status`,
`deliver_result`, `raise_event`, `set_learning`, `run_diagnostic`,
`run_driver_query`, `invoke_driver_action`;
`Envelope.PREFIXES.ai_core = { "ai_core." }`.

**Remote Control tier.** A `MODULE_COMMANDS` entry that is a number instead
of `true` is the minimum rank of the Agent's Composer *Remote Control*
property (Off 0, Identify only 1, Comfort 2, Full control 3) the verb needs.
`invoke_driver_action = 2`: `ModuleCommandDispatch` refuses it below Comfort
(the command is acked failed with the tier message and nothing is
forwarded), and the heartbeat advertises capability `driver_actions_v1`
only at rank ≥ 2. `run_driver_query` is read-only and needs no tier. As for
every module verb, the target instance must also register the command.

Anything not listed is `not_permitted`. These tables are code: changing them
is a driver release.

## 10. Limits and rates

| Limit | Value |
| --- | --- |
| SendToDevice frame | 32 KB (v1) |
| request `args`, cloud `body` | 16 KB |
| response `result`, relayed cloud `result` | 24 KB |
| manifest | 2 KB, ≤ 24 capabilities, ≤ 16 topics each |
| directory `modules` | 28 KB (then `truncated`) |
| topics per SUBSCRIBE / subscriptions per instance | 16 / 8 |
| subscriber buffer | 200, drop-oldest, counted |
| PUBLISH frame | ≤ 25 envelopes and ≤ ~24 KB of envelopes |
| deadline | ≤ now + 60 s; routing state kept to deadline + 5 s |
| idempotency ring (Agent) / target dedup ring (client) | 256 / 256 |
| routes in flight (Agent, requests + cloud) | 128 |
| registrations (Agent registry) | 48 (49th → `registry_full`) |
| `cursor` | 256 characters |
| request bucket per module (REQUEST + DISCOVER) | 30/min, burst 10 |
| cloud bucket per module | 20/min, burst 10 |

Buckets refill continuously and are keyed by `module_id`.

## 11. Error codes (closed vocabulary)

| Code | Meaning | Retry |
| --- | --- | --- |
| `ok` | success | — |
| `invalid_frame` | a required param is missing or malformed | no |
| `incompatible_protocol` | one side negotiated v1 | no |
| `unknown_target` | no module (or instance) by that id is registered | no |
| `target_unavailable` | registered, but not live at v2; or it went away; or the Agent restarted | **yes** |
| `capability_not_found` | target does not serve it (manifest / provider / no handler) | no |
| `not_permitted` | policy refuses it | no |
| `invalid_args` | args/body/topics/deadline range wrong | no |
| `payload_too_large` | over a size limit | no |
| `deadline_exceeded` | no answer by the deadline, or deadline already past | **yes** |
| `duplicate_request` | same request id, or same key still in flight; informational on a replay ACK | no |
| `rate_limited` | a token bucket or the route cap | **yes** |
| `agent_not_paired` | cloud relay without a pairing | no |
| `cloud_unreachable` | no usable answer from the platform | **yes** |
| `cloud_refused` | the platform refused | no |
| `unsupported` | reserved for a platform answer | no |
| `internal_error` | a handler failed, or an out-of-vocabulary code was normalised | no |

## 12. Retry (client library)

Only `deadline_exceeded`, `target_unavailable`, `rate_limited` and
`cloud_unreachable` are retried: at most 2 retries, after 2 s then 5 s, with
the **same** `idempotency_key` and a fresh `request_id` per attempt. Every
other code is final. Calls made while the module is not registered fail
`target_unavailable` (so they are retried while registration recovers);
calls made against a v1 Agent fail `incompatible_protocol`. Size limits are
checked before anything is sent.

## 13. Lifecycle

- **Register** on every LateInit (v1 rule). On success at protocol 2 the
  client re-sends every subscription it holds.
- **Agent restart / update:** tokens, routes, subscriptions and buckets are
  Agent memory and are lost (the registry itself is persisted, so the Agent
  knows whom to greet). The Agent's LateInit sends `SBOS_MODULE_AGENT_HELLO`
  to every known instance; each re-registers (new token) and re-subscribes.
  A request in flight across the restart fails `target_unavailable` at its
  deadline (retryable). Frames carrying a pre-restart token are ignored once
  the module has re-registered.
- **Unregister** (`SBOS_MODULE_UNREGISTER`, v1): subscriptions dropped,
  in-flight requests to it answered `target_unavailable`, directory change
  pushed.
- **Stale** (no frame for 15 min): excluded from routing
  (`target_unavailable`), shown `stale` in the directory, change pushed.

## 14. Health

- Heartbeat `module_protocol = {min: 1, max: 2}`; capabilities add
  `modules_v2`.
- Heartbeat `module_bus` (Agent totals): `requests`, `routed`, `refused`,
  `responses`, `timeouts`, `replayed`, `published`, `dropped`, `discovers`,
  `subscribes`, `cloud_requests`, `cloud_ok`, `cloud_failed`, `rate_limited`,
  `ignored`, `inflight`, `subscriptions`, `buffered`, `directory_version`.
- Heartbeat `modules[]` rows add `bus` (what the Agent measured for that
  instance: `requests`, `refused`, `served`, `published`, `dropped`,
  `cloud_requests`, `rate_limited`), `manifest` / `manifest_error` and
  `verified` (identity binding, §3). Tokens never leave the controller.
- Heartbeat capabilities add `driver_actions_v1` at Remote Control Comfort
  or above (§9).
- The module's `SBOS_MODULE_STATUS.counters` gains `bus` (what the client
  measured: `requests`, `responses_ok`, `errors`, `timeouts`, `retries`,
  `served`, `served_duplicates`, `published_received`, `dropped_reported`,
  `cloud_requests`, `ignored_frames`).

## 15. Client library

```lua
local client = require("sbos.moduleclient")
client.setup({
  module_id = "ai_core", driver_version = v, entitlements = { "SBOS_AI_CORE" },
  event_types = { "ai_core." }, singleton = true,
  manifest = { driver = "sbos.ai_core", capabilities = { ... } },
  require_protocol = 2,                       -- needs v2 → agent_update_required on a v1 Agent
  onDirectoryChanged = function(version) end,
  onAgentState = function(agent, why) end,    -- "hello", "update", "agent_update_required", …
  claim_driver_config = false,                -- optional: leave EC.SBOS_DRIVER_CONFIG
                                              -- to the driver (default true: the client
                                              -- takes it, as before)
  -- v1 options unchanged (status, onRegistered, onCommand, onConfig, …)
})
client.register()

client.discover({ capability = "events.query" }, function(directory, code) end)
client.subscribe("fr", { "capture." }, function(events, dropped, id) end,
                 function(ok, reason, granted, refused) end)
client.unsubscribe("fr")
client.request("flight_recorder", "events.query", { since = t, cursor = c },
               { timeout = 10, idempotency_key = k, retries = 2, to_instance = id },
               function(answer) end)   -- answer = { status, error_code, result, cursor,
                                       --   from_module_id, from_instance_id, attempts,
                                       --   idempotency_key, replayed }
client.onRequest("events.query", function(req, respond)
  respond("ok", { events = page }, nil, nextCursor)   -- exactly once, now or later
end)
client.cloudRequest("ask", { question = q }, { idempotency_key = k },
                    function(answer) end)              -- answer adds http_status
client.protocol(); client.agentUpdateRequired(); client.busCounters()
```

Callbacks may run synchronously when a call is refused locally.

## 16. Known limits (not papered over)

- **Emulator-verified only.** Unit tests and a Director-emulator scenario
  exercise the real Agent and module code; no physical controller has run
  v2. Frame sizes near 32 KB, `C4:UUID("RANDOM")`'s exact output format on
  each OS, timer behaviour under Director load and SendToDevice ordering are
  unmeasured on hardware.
- No global ordering; frames between drivers are asynchronous and Director
  documents no ordering or delivery guarantee.
- Local pub/sub is lossy by design (bounded buffers, at-most-once, nothing
  persisted); the Agent's durable cloud queue is the record.
- Agent restarts lose subscriptions, routes, buckets and idempotency
  answers; recovery depends on modules handling `SBOS_MODULE_AGENT_HELLO`
  (the shared client does).
- Module identity: a **reserved** module id is bound to its `.c4z` filename
  (§3); every other id is still self-claimed and shown unverified. The
  binding proves "the device at this id runs a file of that name", not that
  the file is genuine SmartBuildOS code. When Director gives no answer the
  module registers unverified. `C4:GetDevicesByC4iName`'s answer format on
  each OS is assumed from the emulator and the Agent's existing SKU use, not
  measured for this purpose. A registration can still name ANOTHER device's
  id: the token is sent to that device, so the claimant never holds it, but
  the claimed entry's metadata is replaced (as in v1).
- Legacy unauthenticated Agent commands used from Composer programming
  (`SEND_EVENT`, `REPORT_*`, `SEND_PUSH_NOTIFICATION`) remain
  sender-unverified because programming has no token.
- The platform route `/api/integrations/control4/modules/rpc` is specified
  here but lives in the web repo; until it is deployed the Agent's POST gets
  a 404 → `cloud_refused` (and `send()`'s failure reporting, §8).

## 17. Verification

| What | Where |
| --- | --- |
| Agent bus (all frames, policy, limits, rates, cloud mapping) | `test/test_sbos_modulebus.lua` |
| Client engine against the real bus (retries, deadlines, dedup, restart) | `test/test_sbos_modulerpc.lua` |
| `moduleclient` wiring (manifest, v1-Agent degradation, hello) | `test/test_sbos_moduleclient_v2.lua` |
| Agent driver wiring (auth, stamping, fan-out, cloud POST, heartbeat, restart) | `test/test_agent_modules_v2.lua` |
| Registry negotiation, cap, identity binding | `test/test_sbos_modules.lua`, `test/test_agent_modules.lua` |
| Agent tier gate, `driver_actions_v1`, debug suppression, identity binding through the Agent | `test/test_agent_modules_v2.lua` [10]–[12] |
| End to end under the Director emulator (EMULATOR ONLY) | `test/emulator/run-module-contract-v2.sh` → `test/emulator/module_contract_v2.lua` |

Each guard was proven by breaking it once and watching a test fail.
